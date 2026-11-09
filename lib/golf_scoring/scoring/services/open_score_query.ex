defmodule GolfScoring.Scoring.Services.OpenScoreQuery do
  @moduledoc """
  Opens a staff dispute and reviews its scorecard and affected sides atomically.

  `run/4` accepts a trusted session StaffUser, expected_revision and a nonblank
  reason of at most 4096 bytes. It owns the outer transaction and canonical locks.
  The private query action wraps every required transition and the staff audit;
  it cannot commit a dispute on its own. Review actions consume exact, process-
  and transaction-bound capabilities and recheck persisted query evidence.

  Only scoring-open/closed rounds, in-progress/complete scorecards and provisional
  affected sides are supported. Zero affected sides is allowed. Duplicate open
  or escalated queries are conflicts, never idempotent retries. No score facts,
  certification, revision history or group progression are changed.
  """

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.ScoreQuery
  alias GolfScoring.Scoring.Services.ScoreQueryNotifier

  @gate_key {__MODULE__, :open}

  @doc "Opens a current-revision staff query; notification status is separate from committed success."
  def run(actor, event_id, round_id, command) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_required}
    else
      with %StaffUser{id: actor_id} <- actor,
           {:ok, actor_id} <- Ecto.UUID.cast(actor_id),
           {:ok, event_id} <- Ecto.UUID.cast(event_id),
           {:ok, round_id} <- Ecto.UUID.cast(round_id),
           {:ok, command} <- command(command) do
        execute(actor_id, event_id, round_id, command)
      else
        _ -> {:error, :invalid_actor_or_input}
      end
    end
  end

  defp command(%{hole_result_id: id, expected_revision: revision, reason: reason})
       when is_integer(revision) and revision > 0 and is_binary(reason) and
              byte_size(reason) <= 4096 do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- String.valid?(reason),
         trimmed when trimmed != "" <- String.trim(reason) do
      {:ok, %{hole_id: id, revision: revision, reason: trimmed}}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp command(_), do: {:error, :invalid_input}

  defp execute(actor_id, event_id, round_id, command) do
    result =
      Repo.transaction(fn ->
        scope = lock_scope!(actor_id, event_id, round_id, command)
        open_locked!(scope, command.reason)
      end)

    case result do
      {:ok, opened} -> {:ok, Map.put(opened, :notification, ScoreQueryNotifier.publish(opened))}
      {:error, _} = error -> error
    end
  end

  defp lock_scope!(actor_id, event_id, round_id, command) do
    with {:ok, _} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
         true <- authorized?(actor_id, event_id),
         {:ok, %{acquired: [round]}} <- LockProtocol.acquire!(round: [round_id]),
         true <-
           round.row.event_id == event_id and
             round.row.state in ["scoring_open", "scoring_closed"] do
      subject = subject!(command.hole_id, round_id)
      acquire!(playing_group: [subject.group_id])

      assignments =
        Repo.query!(
          "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active'",
          [uuid(subject.group_id)]
        ).rows
        |> Enum.map(&hd/1)

      acquire!(group_role_assignment: assignments)

      scope =
        Map.merge(subject, %{
          actor_id: actor_id,
          event_id: event_id,
          round_id: round_id,
          hole_id: command.hole_id,
          revision: command.revision
        })

      sides = side_rows(scope)
      validate_side_scope!(sides)
      acquire!(competition_side: Enum.map(sides, & &1.side_id))
      acquire!(competition_side_result: Enum.map(sides, & &1.result_id))
      acquire!(score_row: [subject.card_id])
      scope = Map.put(scope, :sides, sides)
      validate_locked!(scope)
      scope
    else
      false -> Repo.rollback(:forbidden_or_invalid_scope)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp subject!(hole_id, round_id) do
    case Repo.query!(
           """
           SELECT sc.id::text, re.id::text, re.playing_group_id::text, sc.state, hr.revision
           FROM hole_results hr
           JOIN scorecards sc ON sc.id = hr.scorecard_id AND sc.round_id = hr.round_id
           JOIN round_entries re ON re.id = sc.round_entry_id AND re.round_id = sc.round_id
           WHERE hr.id = $1::uuid AND hr.round_id = $2::uuid
           """,
           [uuid(hole_id), uuid(round_id)]
         ).rows do
      [[card, entry, group, state, revision]] when not is_nil(group) ->
        %{
          card_id: card,
          entry_id: entry,
          group_id: group,
          card_state: state,
          current_revision: revision
        }

      _ ->
        Repo.rollback(:invalid_result_scope)
    end
  end

  defp side_rows(scope) do
    Repo.query!(
      """
      SELECT m.competition_side_id::text, csr.id::text, csr.state,
        (cs.round_id = $2::uuid AND cs.round_competition_id = m.round_competition_id
         AND rc.round_id = $2::uuid AND rc.event_id = $3::uuid
         AND NOT EXISTS (
           SELECT 1 FROM competition_side_memberships peer
           LEFT JOIN round_entries re ON re.id = peer.round_entry_id
           WHERE peer.competition_side_id = cs.id
             AND (peer.round_id <> $2::uuid OR peer.round_competition_id <> rc.id
                  OR re.round_id IS DISTINCT FROM $2::uuid
                  OR re.event_id IS DISTINCT FROM $3::uuid
                  OR re.playing_group_id IS DISTINCT FROM $4::uuid)))
      FROM competition_side_memberships m
      LEFT JOIN competition_sides cs ON cs.id = m.competition_side_id
      LEFT JOIN round_competitions rc ON rc.id = m.round_competition_id
      LEFT JOIN competition_side_results csr ON csr.competition_side_id = cs.id
      WHERE m.round_entry_id = $1::uuid AND m.round_id = $2::uuid
      ORDER BY m.competition_side_id
      """,
      [uuid(scope.entry_id), uuid(scope.round_id), uuid(scope.event_id), uuid(scope.group_id)]
    ).rows
    |> Enum.map(fn [side, result, state, valid] ->
      %{side_id: side, result_id: result, state: state, valid?: valid}
    end)
  end

  defp validate_side_scope!(sides) do
    unless Enum.all?(sides, &(&1.valid? == true and not is_nil(&1.result_id))) and
             length(sides) == length(Enum.uniq_by(sides, & &1.side_id)),
           do: Repo.rollback(:invalid_side_membership)
  end

  defp validate_locked!(scope) do
    current = subject!(scope.hole_id, scope.round_id)
    sides = side_rows(scope)
    validate_side_scope!(sides)

    cond do
      current.current_revision != scope.revision ->
        Repo.rollback(:stale_revision)

      unresolved?(scope.hole_id) ->
        Repo.rollback(:unresolved_score_query)

      Map.take(current, [:card_id, :entry_id, :group_id]) !=
          Map.take(scope, [:card_id, :entry_id, :group_id]) ->
        Repo.rollback(:scope_changed)

      current.card_state not in ["in_progress", "complete"] ->
        Repo.rollback(:unsupported_scorecard_state)

      side_keys(sides) != side_keys(scope.sides) ->
        Repo.rollback(:scope_changed)

      not Enum.all?(sides, &(&1.state == "provisional")) ->
        Repo.rollback(:unsupported_side_result_state)

      true ->
        :ok
    end
  end

  defp open_locked!(scope, reason) do
    attrs = %{
      hole_result_id: scope.hole_id,
      scorecard_id: scope.card_id,
      round_id: scope.round_id,
      hole_result_revision: scope.revision,
      requested_by_staff_user_id: scope.actor_id,
      reason: reason
    }

    gate = %{
      scope: scope,
      attrs: attrs,
      query_id: Ecto.UUID.generate(),
      token: make_ref(),
      transaction_id: transaction_id(),
      phase: :opening
    }

    Process.put(@gate_key, gate)

    try do
      ScoreQuery
      |> Changeset.for_create(:open_internal, attrs)
      |> Changeset.force_change_attribute(:id, gate.query_id)
      |> Changeset.set_context(%{score_query_open: gate.token})
      |> Ash.create(authorize?: false)
      |> unwrap!()

      case Process.get(@gate_key) do
        %{phase: :complete, result: result} -> result
        _ -> Repo.rollback(:incomplete_query_open)
      end
    after
      Process.delete(@gate_key)
    end
  end

  @doc false
  def around_open(changeset, callback) do
    gate = gate!(changeset, :opening)
    validate_locked!(gate.scope)

    unless Changeset.get_attribute(changeset, :id) == gate.query_id and
             Map.new(gate.attrs, fn {key, _} -> {key, Changeset.get_attribute(changeset, key)} end) ==
               gate.attrs and
             Changeset.get_attribute(changeset, :status) == :open and no_resolution?(changeset),
           do: Repo.rollback(:invalid_query_evidence)

    Process.put(@gate_key, %{gate | phase: :inserting})

    case callback.(changeset) do
      {:ok, query, changeset, instructions} ->
        complete!(gate, query)
        {:ok, query, changeset, instructions}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp no_resolution?(changeset) do
    Enum.all?(
      [
        :requested_by_round_entry_id,
        :resolved_by_staff_user_id,
        :resolved_by_round_entry_id,
        :resolved_at,
        :resolution_reason
      ],
      &is_nil(Changeset.get_attribute(changeset, &1))
    )
  end

  defp complete!(gate, query) do
    unless query.id == gate.query_id, do: Repo.rollback(:invalid_query_evidence)
    Process.put(@gate_key, %{gate | phase: :card})

    card =
      Ash.get!(Scorecard, gate.scope.card_id, authorize?: false)
      |> update_review!()

    sides =
      Enum.map(gate.scope.sides, fn side ->
        Process.put(@gate_key, %{gate | phase: {:side, side.result_id, side.side_id}})
        Ash.get!(CompetitionSideResult, side.result_id, authorize?: false) |> update_review!()
      end)

    audit = audit!(gate)

    result = %{
      score_query: query,
      scorecard: card,
      side_results: sides,
      audit: audit,
      event_id: gate.scope.event_id
    }

    Process.put(@gate_key, Map.merge(gate, %{phase: :complete, result: result}))
  end

  defp update_review!(record) do
    gate = Process.get(@gate_key)

    record
    |> Changeset.for_update(:require_review_for_open_query_internal, %{})
    |> Changeset.set_context(%{score_query_open: gate.token})
    |> Ash.update(authorize?: false)
    |> unwrap!()
  end

  @doc false
  def prepare_review(changeset, kind) do
    gate = gate!(changeset, review_phase(changeset.data, kind))

    unless persisted_query?(gate) and valid_review_record?(changeset.data, kind, gate) and
             Enum.all?(Map.keys(changeset.attributes), &(&1 == :updated_at)),
           do: Repo.rollback(:invalid_query_review)

    Process.put(@gate_key, %{gate | phase: :transitioning})
    Changeset.force_change_attribute(changeset, :state, :review_required)
  end

  defp review_phase(_record, :card), do: :card
  defp review_phase(record, :side), do: {:side, record.id, record.competition_side_id}

  defp valid_review_record?(record, :card, gate) do
    record.id == gate.scope.card_id and record.round_id == gate.scope.round_id and
      record.round_entry_id == gate.scope.entry_id and record.state in [:in_progress, :complete]
  end

  defp valid_review_record?(record, :side, gate) do
    {record.competition_side_id, record.id} in side_keys(gate.scope.sides) and
      record.state == :provisional and
      Repo.query!("SELECT state FROM scorecards WHERE id = $1::uuid", [uuid(gate.scope.card_id)]).rows ==
        [["review_required"]]
  end

  defp persisted_query?(gate) do
    query = Ash.get!(ScoreQuery, gate.query_id, authorize?: false)

    Map.take(query, Map.keys(gate.attrs)) == gate.attrs and query.status == :open and
      is_nil(query.resolved_at) and is_nil(query.resolution_reason) and
      is_nil(query.resolved_by_staff_user_id) and is_nil(query.resolved_by_round_entry_id) and
      is_nil(query.requested_by_round_entry_id)
  end

  defp gate!(changeset, phase) do
    gate = Process.get(@gate_key)

    unless Repo.in_transaction?() and is_map(gate) and gate.phase == phase and
             changeset.context[:score_query_open] == gate.token and
             gate.transaction_id == transaction_id() and
             scope_current?(gate.scope),
           do: Repo.rollback(:invalid_query_capability)

    gate
  end

  defp scope_current?(scope) do
    current = subject!(scope.hole_id, scope.round_id)

    authorized?(scope.actor_id, scope.event_id) and
      Map.take(current, [:card_id, :entry_id, :group_id]) ==
        Map.take(scope, [:card_id, :entry_id, :group_id]) and
      current.current_revision == scope.revision and
      side_keys(side_rows(scope)) == side_keys(scope.sides) and
      Repo.query!("SELECT event_id::text, state FROM rounds WHERE id = $1::uuid", [
        uuid(scope.round_id)
      ]).rows in [[[scope.event_id, "scoring_open"]], [[scope.event_id, "scoring_closed"]]]
  end

  defp audit!(gate) do
    Audit.record_staff_event(
      %{
        actor_staff_user_id: gate.scope.actor_id,
        action: "query_hole_result",
        target_type: "ScoreQuery",
        target_id: gate.query_id,
        reason: gate.attrs.reason,
        context: %{
          event_id: gate.scope.event_id,
          round_id: gate.scope.round_id,
          hole_result_id: gate.scope.hole_id,
          scorecard_id: gate.scope.card_id,
          hole_result_revision: gate.scope.revision
        },
        changes: %{status: "open"}
      },
      authorize?: false
    )
    |> unwrap!()
  end

  defp unresolved?(hole_id),
    do:
      Repo.query!(
        "SELECT 1 FROM score_queries WHERE hole_result_id = $1::uuid AND status IN ('open', 'escalated') LIMIT 1",
        [uuid(hole_id)]
      ).rows != []

  defp side_keys(sides), do: Enum.map(sides, &{&1.side_id, &1.result_id})

  defp authorized?(actor, event),
    do: ActiveEventRole.authorized?(actor, event, [:event_admin, :competition_manager])

  defp acquire!(request), do: request |> LockProtocol.acquire!() |> unwrap!()
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
