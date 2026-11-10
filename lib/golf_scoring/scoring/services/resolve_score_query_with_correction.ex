defmodule GolfScoring.Scoring.Services.ResolveScoreQueryWithCorrection do
  @moduledoc """
  Resolves an open or escalated dispute by correcting the current holed-out gross score.

  Owns the outer transaction. Correction evidence, certification renewal, competitive
  review and query terminal resolution commit together or roll back together.
  """

  alias Ash
  alias Ash.Changeset
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition.Services.RequireReviewForCorrectedScore, as: Review
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.ScoreQuery
  alias GolfScoring.Scoring.Services.CorrectHoleResult

  @scope_key {__MODULE__, :scope}
  @query_gate_key {__MODULE__, :query}

  @evidence_fields [
    :id,
    :hole_result_id,
    :scorecard_id,
    :round_id,
    :hole_result_revision,
    :reason,
    :requested_by_staff_user_id,
    :requested_by_round_entry_id,
    :inserted_at
  ]

  @doc """
  Requires `score_query_id`, `expected_revision`, `new_gross_strokes`, and `reason`.
  """
  def run(actor, event_id, round_id, command) when is_map(command) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_required}
    else
      with %StaffUser{} <- actor,
           {:ok, event_id} <- Ecto.UUID.cast(event_id),
           {:ok, round_id} <- Ecto.UUID.cast(round_id),
           {:ok, command} <- command(command),
           {:ok, query} <- load_query(command.query_id, round_id) do
        execute(actor, event_id, round_id, command, query)
      else
        {:error, _} = error -> error
        _ -> {:error, :invalid_input}
      end
    end
  end

  def run(_actor, _event_id, _round_id, _command), do: {:error, :invalid_input}

  @doc false
  def active_scope? do
    case Process.get(@scope_key) do
      %{transaction_id: id} when is_binary(id) -> id == transaction_id()
      _ -> false
    end
  end

  defp command(%{
         score_query_id: id,
         expected_revision: revision,
         new_gross_strokes: gross,
         reason: reason
       })
       when is_integer(revision) and revision > 0 and is_integer(gross) and gross > 0 and
              gross <= 2_147_483_647 and is_binary(reason) and byte_size(reason) <= 4096 do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- String.valid?(reason),
         trimmed when trimmed != "" <- String.trim(reason) do
      {:ok, %{query_id: id, revision: revision, new_gross_strokes: gross, reason: trimmed}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp command(_), do: {:error, :invalid_input}

  defp load_query(id, round_id) do
    case Ash.get(ScoreQuery, id, authorize?: false) do
      {:ok, query} ->
        if to_string(query.round_id) == to_string(round_id) do
          {:ok, query}
        else
          {:error, :not_found_or_forbidden}
        end

      {:error, _} ->
        {:error, :not_found_or_forbidden}
    end
  end

  defp execute(actor, event_id, round_id, command, query) do
    case Repo.transaction(fn ->
           transaction_resolve(actor, event_id, round_id, command, query)
         end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:error, _} = error -> error
    end
  end

  defp transaction_resolve(actor, event_id, round_id, command, query) do
    Review.with_locked_scope(actor, event_id, round_id, query.hole_result_id, fn review ->
      resolve_locked!(actor, event_id, round_id, command, query, review)
    end)
  end

  defp resolve_locked!(actor, event_id, round_id, command, query, review) do
    subject = subject!(command.query_id, round_id)
    validate_query!(query, command, subject)
    validate_dispute_scope!(subject, round_id)

    correction_command = %{
      hole_result_id: query.hole_result_id,
      expected_revision: command.revision,
      new_gross_strokes: command.new_gross_strokes,
      reason: command.reason
    }

    Process.put(@scope_key, %{
      query_id: query.id,
      query_revision: command.revision,
      transaction_id: transaction_id()
    })

    try do
      correction =
        CorrectHoleResult.correct_locked_for_query_resolution!(
          actor,
          event_id,
          round_id,
          correction_command,
          review,
          query.id
        )

      query_gate = %{
        query_id: query.id,
        actor_id: actor.id,
        event_id: event_id,
        round_id: round_id,
        hole_id: query.hole_result_id,
        card_id: query.scorecard_id,
        query_revision: command.revision,
        reason: command.reason,
        original: Map.take(query, @evidence_fields),
        original_status: query.status,
        resulting_revision: correction.hole_result.revision,
        token: make_ref(),
        transaction_id: transaction_id(),
        phase: :ready
      }

      Process.put(@query_gate_key, query_gate)

      try do
        resolved =
          query
          |> Changeset.for_update(:resolve_with_correction_internal, %{})
          |> Changeset.set_context(%{score_query_resolution: query_gate.token})
          |> Ash.update(authorize?: false)
          |> unwrap!()

        case Process.get(@query_gate_key) do
          %{phase: :complete, query_audit: audit} ->
            {:ok,
             Map.merge(correction, %{
               score_query: resolved,
               query_audit: audit,
               event_id: event_id
             })}

          _ ->
            Repo.rollback(:incomplete_query_resolution)
        end
      after
        Process.delete(@query_gate_key)
      end
    after
      Process.delete(@scope_key)
    end
  end

  defp subject!(query_id, round_id) do
    case Repo.query!(
           """
           SELECT q.hole_result_id::text, sc.id::text, re.id::text,
                  re.playing_group_id::text, sc.state, hr.revision, q.hole_result_revision, q.status
           FROM score_queries q
           JOIN hole_results hr ON hr.id = q.hole_result_id AND hr.scorecard_id = q.scorecard_id AND hr.round_id = q.round_id
           JOIN scorecards sc ON sc.id = q.scorecard_id AND sc.round_id = q.round_id
           JOIN round_entries re ON re.id = sc.round_entry_id AND re.round_id = sc.round_id
           WHERE q.id = $1::uuid AND q.round_id = $2::uuid
           """,
           [uuid(query_id), uuid(round_id)]
         ).rows do
      [[hole, card, entry, group, state, revision, query_revision, status]]
      when not is_nil(group) ->
        %{
          hole_id: hole,
          card_id: card,
          entry_id: entry,
          group_id: group,
          card_state: state,
          current_revision: revision,
          query_revision: query_revision,
          status: status
        }

      _ ->
        Repo.rollback(:not_found_or_forbidden)
    end
  end

  defp validate_query!(query, command, subject) do
    cond do
      to_string(query.id) != command.query_id -> Repo.rollback(:not_found_or_forbidden)
      query.hole_result_revision != command.revision -> Repo.rollback(:stale_revision)
      subject.current_revision != command.revision -> Repo.rollback(:stale_revision)
      to_string(query.hole_result_id) != subject.hole_id -> Repo.rollback(:scope_changed)
      query.status not in [:open, :escalated] -> Repo.rollback(:terminal_query)
      subject.status != Atom.to_string(query.status) -> Repo.rollback(:invalid_query_state)
      true -> :ok
    end
  end

  defp validate_dispute_scope!(subject, round_id) do
    unless subject.card_state == "review_required",
      do: Repo.rollback(:unsupported_scorecard_state)

    sides = side_rows(subject, round_id)

    unless Enum.all?(sides, &(&1.state == "review_required")),
      do: Repo.rollback(:unsupported_side_result_state)
  end

  defp side_rows(subject, round_id) do
    Repo.query!(
      """
      SELECT csr.state
      FROM competition_side_memberships m
      JOIN competition_side_results csr ON csr.competition_side_id = m.competition_side_id
      WHERE m.round_entry_id = $1::uuid AND m.round_id = $2::uuid
      ORDER BY m.competition_side_id
      """,
      [uuid(subject.entry_id), uuid(round_id)]
    ).rows
    |> Enum.map(fn [state] -> %{state: state} end)
  end

  @doc false
  def around_resolve_with_correction(changeset, callback) do
    gate = query_gate!(changeset)
    original_status = gate.original_status

    unless Map.take(changeset.data, @evidence_fields) == gate.original and
             changeset.data.status == original_status and
             original_status in [:open, :escalated] and
             Enum.all?(Map.keys(changeset.attributes), &(&1 == :updated_at)),
           do: Repo.rollback(:invalid_query_resolution)

    revalidate_after_correction!(gate)

    Process.put(@query_gate_key, %{gate | phase: :writing})

    resolved_at = DateTime.utc_now(:microsecond)

    changeset =
      changeset
      |> Changeset.filter(
        id: gate.query_id,
        status: original_status,
        hole_result_revision: gate.query_revision
      )
      |> Changeset.force_change_attribute(:status, :resolved)
      |> Changeset.force_change_attribute(:resolved_by_staff_user_id, gate.actor_id)
      |> Changeset.force_change_attribute(:resolution_reason, gate.reason)
      |> Changeset.force_change_attribute(:resolved_at, resolved_at)
      |> Changeset.force_change_attribute(:resolved_by_round_entry_id, nil)

    case callback.(changeset) do
      {:ok, query, changeset, instructions} ->
        complete_query!(gate, query)
        {:ok, query, changeset, instructions}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp revalidate_after_correction!(gate) do
    [[revision]] =
      Repo.query!("SELECT revision FROM hole_results WHERE id = $1::uuid", [uuid(gate.hole_id)]).rows

    unless revision == gate.resulting_revision, do: Repo.rollback(:invalid_query_resolution)

    unless Repo.query!(
             "SELECT status FROM score_queries WHERE id = $1::uuid",
             [uuid(gate.query_id)]
           ).rows == [[to_string(gate.original_status)]],
           do: Repo.rollback(:invalid_query_resolution)
  end

  defp query_gate!(changeset) do
    gate = Process.get(@query_gate_key)

    unless Repo.in_transaction?() and is_map(gate) and gate.phase == :ready and
             changeset.context[:score_query_resolution] == gate.token and
             gate.transaction_id == transaction_id(),
           do: Repo.rollback(:invalid_query_resolution_capability)

    gate
  end

  defp complete_query!(gate, query) do
    persisted = Ash.get!(ScoreQuery, gate.query_id, authorize?: false)

    unless query.status == :resolved and persisted.status == :resolved and
             Map.take(query, @evidence_fields) == gate.original and
             Map.take(persisted, @evidence_fields) == gate.original and
             query.resolution_reason == gate.reason and
             query.resolved_by_staff_user_id == gate.actor_id,
           do: Repo.rollback(:invalid_query_resolution_evidence)

    audit =
      Audit.record_staff_event(
        %{
          actor_staff_user_id: gate.actor_id,
          action: "resolve_score_query_with_correction",
          target_type: "ScoreQuery",
          target_id: gate.query_id,
          reason: gate.reason,
          context: %{
            event_id: gate.event_id,
            round_id: gate.round_id,
            hole_result_id: gate.hole_id,
            scorecard_id: gate.card_id,
            hole_result_revision: gate.query_revision,
            resulting_hole_result_revision: gate.resulting_revision
          },
          changes: %{
            status: %{from: Atom.to_string(gate.original_status), to: "resolved"}
          }
        },
        authorize?: false
      )
      |> unwrap!()

    Process.put(@query_gate_key, Map.merge(gate, %{phase: :complete, query_audit: audit}))
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
