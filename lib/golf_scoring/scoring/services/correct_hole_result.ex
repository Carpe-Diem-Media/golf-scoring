defmodule GolfScoring.Scoring.Services.CorrectHoleResult do
  @moduledoc """
  Staff-only, atomic gross-score correction for an already holed-out result.

  `run/4` requires a trusted session StaffUser and owns the outer transaction.
  Nested calls are rejected so notifications cannot precede the caller's commit.
  The review coordinator owns authority and canonical locks. Its callback grants
  a single-use write capability bound to this process, transaction and exact data.
  The HoleResult action wraps all remaining writes; it cannot succeed alone.

  Only in-progress/complete scorecards and provisional sides are supported.
  Pending old verification remains historical; certified evidence is superseded.
  Notification delivery status is returned separately from committed DB success.
  """

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition.Services.RequireReviewForCorrectedScore, as: Review
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.ScoreRevision
  alias GolfScoring.Scoring.ScoreVerification
  alias GolfScoring.Scoring.ScoreVerificationWriteGuard
  alias GolfScoring.Scoring.Services.CorrectionNotifier

  @gate_key {__MODULE__, :write}
  @verification_gate_key {__MODULE__, :verification_write}

  @doc "Corrects a gross score using expected_revision, new_gross_strokes and reason."
  def run(actor, event_id, round_id, command) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_required}
    else
      with {:ok, command} <- command(command),
           %StaffUser{} <- actor do
        execute(actor, event_id, round_id, command)
      else
        {:error, _} = error -> error
        _ -> {:error, :forbidden}
      end
    end
  end

  defp command(%{
         hole_result_id: id,
         expected_revision: revision,
         new_gross_strokes: gross,
         reason: reason
       })
       when is_integer(revision) and revision > 0 and is_integer(gross) and gross > 0 and
              gross <= 2_147_483_647 and is_binary(reason) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         reason when reason != "" <- String.trim(reason) do
      {:ok,
       %{
         hole_result_id: id,
         expected_revision: revision,
         new_gross_strokes: gross,
         reason: reason
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp command(_), do: {:error, :invalid_input}

  defp execute(actor, event_id, round_id, command) do
    result =
      Repo.transaction(fn ->
        Review.with_locked_scope(actor, event_id, round_id, command.hole_result_id, fn review ->
          correct_locked!(actor, event_id, round_id, command, review)
        end)
      end)

    case result do
      {:ok, {:ok, correction}} ->
        {:ok, Map.put(correction, :notification, CorrectionNotifier.publish(correction))}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def correct_locked_for_query_resolution!(actor, event_id, round_id, command, review, query_id) do
    original = Ash.get!(HoleResult, command.hole_result_id, authorize?: false)
    scope = load_scope!(original)
    validate_target!(original, scope, command, query_resolution: query_id)
    evidence = evidence(original, actor.id, command, query_id)

    run_correction!(actor, event_id, round_id, command, review, original, scope, evidence)
    |> unwrap_correction!()
  end

  defp unwrap_correction!({:ok, correction}), do: correction
  defp unwrap_correction!(_), do: Repo.rollback(:incomplete_correction)

  defp correct_locked!(actor, event_id, round_id, command, review) do
    original = Ash.get!(HoleResult, command.hole_result_id, authorize?: false)
    scope = load_scope!(original)
    validate_target!(original, scope, command, [])
    evidence = evidence(original, actor.id, command, nil)
    run_correction!(actor, event_id, round_id, command, review, original, scope, evidence)
  end

  defp run_correction!(actor, event_id, round_id, command, review, original, scope, evidence) do
    gate = %{
      token: make_ref(),
      transaction_id: transaction_id(),
      phase: :update,
      original: original,
      command: command,
      evidence: evidence,
      review: review,
      actor_id: actor.id,
      event_id: event_id,
      round_id: round_id,
      scope: scope
    }

    Process.put(@gate_key, gate)

    try do
      original
      |> Changeset.for_update(:correct_gross_internal, %{
        gross_strokes: command.new_gross_strokes,
        expected_revision: command.expected_revision
      })
      |> Changeset.set_context(%{score_correction: gate.token})
      |> Ash.update(authorize?: false)
      |> unwrap!()

      case Process.get(@gate_key) do
        %{phase: :complete, result: result} -> {:ok, result}
        _ -> Repo.rollback(:incomplete_correction)
      end
    after
      Process.delete(@gate_key)
    end
  end

  defp load_scope!(original) do
    case Repo.query!(
           """
           SELECT sc.round_entry_id::text, re.playing_group_id::text, sc.state
           FROM scorecards sc JOIN round_entries re ON re.id = sc.round_entry_id AND re.round_id = sc.round_id
           WHERE sc.id = $1::uuid AND sc.round_id = $2::uuid
           """,
           [uuid(original.scorecard_id), uuid(original.round_id)]
         ).rows do
      [[entry, group, state]] -> %{entry_id: entry, group_id: group, card_state: state}
      _ -> Repo.rollback(:invalid_scope)
    end
  end

  defp validate_target!(original, scope, command, opts) do
    validate_correction_values!(original, command)

    case Keyword.get(opts, :query_resolution) do
      nil -> validate_ordinary_correction_target!(original, scope)
      query_id -> validate_query_resolution_target!(original, scope, query_id)
    end

    :ok
  end

  defp validate_correction_values!(original, command) do
    cond do
      original.revision != command.expected_revision ->
        Repo.rollback(:stale_revision)

      original.outcome != :holed_out ->
        Repo.rollback(:unsupported_outcome)

      original.gross_strokes == command.new_gross_strokes ->
        Repo.rollback(:unchanged_score)

      true ->
        :ok
    end
  end

  defp validate_ordinary_correction_target!(original, scope) do
    cond do
      scope.card_state not in ["in_progress", "complete"] ->
        Repo.rollback(:unsupported_scorecard_state)

      unresolved_query?(original.id) ->
        Repo.rollback(:unresolved_score_query)

      true ->
        :ok
    end
  end

  defp validate_query_resolution_target!(original, scope, query_id) do
    cond do
      scope.card_state != "review_required" ->
        Repo.rollback(:unsupported_scorecard_state)

      !matching_open_query?(original.id, query_id) ->
        Repo.rollback(:invalid_query_scope)

      true ->
        :ok
    end
  end

  defp matching_open_query?(hole_id, query_id) do
    Repo.query!(
      "SELECT 1 FROM score_queries WHERE id = $1::uuid AND hole_result_id = $2::uuid AND status IN ('open', 'escalated') LIMIT 1",
      [uuid(query_id), uuid(hole_id)]
    ).rows != []
  end

  defp unresolved_query?(id) do
    Repo.query!(
      "SELECT 1 FROM score_queries WHERE hole_result_id = $1::uuid AND status IN ('open', 'escalated') LIMIT 1",
      [uuid(id)]
    ).rows != []
  end

  defp evidence(original, actor_id, command, source_query_id) do
    %{
      hole_result_id: original.id,
      scorecard_id: original.scorecard_id,
      round_id: original.round_id,
      original_revision: original.revision,
      resulting_revision: original.revision + 1,
      original_outcome: original.outcome,
      new_outcome: :holed_out,
      original_gross_strokes: original.gross_strokes,
      new_gross_strokes: command.new_gross_strokes,
      actor_staff_user_id: actor_id,
      source_query_id: source_query_id,
      reason: command.reason
    }
  end

  @doc false
  def around_update(changeset, callback) do
    gate = valid_gate!(changeset, :update)
    validate_update!(changeset, gate)
    Process.put(@gate_key, %{gate | phase: :updating})

    case callback.(changeset) do
      {:ok, updated, changeset, instructions} ->
        unless updated.revision == gate.evidence.resulting_revision and
                 updated.gross_strokes == gate.evidence.new_gross_strokes and
                 updated.outcome == :holed_out,
               do: Repo.rollback(:invalid_revision)

        complete!(gate, updated)
        {:ok, updated, changeset, instructions}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp validate_update!(changeset, gate) do
    allowed = [:gross_strokes, :revision, :updated_at]

    valid? =
      changeset.data == gate.original and
        Changeset.get_argument(changeset, :expected_revision) == gate.original.revision and
        Changeset.get_attribute(changeset, :gross_strokes) == gate.evidence.new_gross_strokes and
        Changeset.get_attribute(changeset, :revision) == gate.original.revision and
        Enum.all?(Map.keys(changeset.attributes), &(&1 in allowed))

    unless valid?, do: Repo.rollback(:invalid_correction_write)
  end

  @doc false
  def validate_revision_create(changeset) do
    gate = valid_gate!(changeset, :evidence)

    actual =
      Map.new(gate.evidence, fn {key, _} -> {key, Changeset.get_attribute(changeset, key)} end)

    current = Ash.get!(HoleResult, gate.original.id, authorize?: false)

    source_ok =
      case gate.evidence[:source_query_id] do
        nil -> is_nil(Changeset.get_attribute(changeset, :source_query_id))
        id -> Changeset.get_attribute(changeset, :source_query_id) == id
      end

    unless actual == gate.evidence and
             source_ok and
             is_nil(Changeset.get_attribute(changeset, :actor_round_entry_id)) and
             current.revision == gate.evidence.resulting_revision and
             current.gross_strokes == gate.evidence.new_gross_strokes and
             current.outcome == :holed_out,
           do: Repo.rollback(:invalid_revision_evidence)

    Process.put(@gate_key, %{gate | phase: :certification})
    changeset
  end

  defp valid_gate!(changeset, phase) do
    gate = Process.get(@gate_key)

    unless Repo.in_transaction?() and is_map(gate) and gate.phase == phase and
             changeset.context[:score_correction] == gate.token and
             gate.transaction_id == transaction_id() and
             Review.correction_scope?(scope_evidence(gate)),
           do: Repo.rollback(:invalid_correction_capability)

    gate
  end

  defp scope_evidence(gate) do
    %{
      actor_id: gate.actor_id,
      event_id: gate.event_id,
      round_id: gate.round_id,
      hole_id: gate.original.id,
      card_id: gate.original.scorecard_id,
      entry_id: gate.scope.entry_id,
      group_id: gate.scope.group_id
    }
  end

  defp complete!(gate, updated) do
    Process.put(@gate_key, %{gate | phase: :evidence})

    revision =
      ScoreRevision
      |> Changeset.for_create(:record_correction_internal, gate.evidence)
      |> Changeset.set_context(%{score_correction: gate.token})
      |> Ash.create(authorize?: false)
      |> unwrap!()

    verification = refresh_verification!(gate, updated)
    audit = audit!(gate, revision)
    {:ok, sides} = gate.review.(revision.id, updated.revision)

    result = %{
      hole_result: updated,
      score_revision: revision,
      verification: verification,
      audit: audit,
      side_results: sides,
      event_id: gate.event_id,
      playing_group_id: gate.scope.group_id
    }

    Process.put(@gate_key, Map.merge(gate, %{phase: :complete, result: result}))
  end

  defp refresh_verification!(gate, updated) do
    old =
      ScoreVerification
      |> Ash.Query.filter(
        hole_result_id == ^updated.id and hole_result_revision == ^gate.original.revision
      )
      |> Ash.read_one!(authorize?: false)

    validate_old_verification!(old, gate)
    supersede!(old, gate)

    ScoreVerification
    |> Changeset.for_create(:create_pending_internal, %{
      hole_result_id: updated.id,
      hole_result_revision: updated.revision,
      scorecard_id: updated.scorecard_id,
      round_id: updated.round_id,
      playing_group_id: gate.scope.group_id,
      subject_round_entry_id: gate.scope.entry_id
    })
    |> write_verification(gate)
    |> unwrap!()
  end

  defp validate_old_verification!(nil, _), do: :ok

  defp validate_old_verification!(old, gate) do
    unless old.scorecard_id == gate.original.scorecard_id and old.round_id == gate.round_id and
             old.playing_group_id == gate.scope.group_id and
             old.subject_round_entry_id == gate.scope.entry_id and
             old.status in [:pending, :verified, :overridden],
           do: Repo.rollback(:conflicting_verification)
  end

  defp supersede!(%{status: status} = old, gate) when status in [:verified, :overridden] do
    old
    |> Changeset.for_update(:supersede_internal, %{})
    |> write_verification(gate)
    |> unwrap!()
  end

  defp supersede!(_, _), do: :ok

  # Only reached inside the validated correction's certification phase.
  defp write_verification(changeset, correction) do
    proof = %{
      owner: __MODULE__,
      operation: :correct,
      authority: correction.evidence,
      event_id: correction.event_id,
      action: changeset.action.name,
      scope: ScoreVerificationWriteGuard.scope(changeset),
      record: changeset.data,
      pid: self(),
      token: make_ref(),
      transaction_id: transaction_id(),
      used?: false
    }

    if Process.get(@verification_gate_key), do: Repo.rollback(:nested_verification_write)
    Process.put(@verification_gate_key, proof)

    try do
      changeset =
        Changeset.set_context(changeset, %{
          score_verification_write: %{owner: __MODULE__, token: proof.token}
        })

      case changeset.action_type do
        :create -> Ash.create(changeset, authorize?: false)
        :update -> Ash.update(changeset, authorize?: false)
      end
    after
      Process.delete(@verification_gate_key)
    end
  end

  @doc false
  def consume_verification_write(changeset) do
    proof = Process.get(@verification_gate_key)

    if ScoreVerificationWriteGuard.matches?(changeset, proof, __MODULE__) and
         Repo.in_transaction?() and proof.transaction_id == transaction_id() do
      Process.put(@verification_gate_key, %{proof | used?: true})
      :ok
    else
      {:error, :unauthorized_verification_write}
    end
  end

  defp audit!(gate, revision) do
    Audit.record_staff_event(
      %{
        actor_staff_user_id: gate.actor_id,
        action: "correct_hole_result",
        target_type: "HoleResult",
        target_id: gate.original.id,
        reason: gate.command.reason,
        context: %{
          round_id: gate.round_id,
          scorecard_id: gate.original.scorecard_id,
          hole_result_id: gate.original.id,
          score_revision_id: revision.id
        },
        changes:
          Map.take(gate.evidence, [
            :original_revision,
            :resulting_revision,
            :original_outcome,
            :new_outcome,
            :original_gross_strokes,
            :new_gross_strokes
          ])
      },
      authorize?: false
    )
    |> unwrap!()
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
