defmodule GolfScoring.Scoring.Services.DecideScoreQuery do
  @moduledoc """
  Terminal no-change resolution or staff dismissal for an open or escalated dispute.

  One outer transaction, canonical locks and a mandatory audit. Scoring facts, certification
  and competitive review readiness stay unchanged. Correction-based resolution is unsupported.
  """

  alias Ash
  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.ScoreQuery

  @gate_key {__MODULE__, :decide}
  @manager_roles [:event_admin, :competition_manager]
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
  @unsupported_decisions ~w(resolve_with_correction correct resolve_correction)a

  @doc """
  Accepts `score_query_id`, `expected_revision`, `reason`, and `decision`
  (`:resolve_no_change` or `:dismiss`).
  """
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
        {:error, _} = error -> error
        _ -> {:error, :invalid_actor_or_input}
      end
    end
  end

  defp command(%{
         score_query_id: id,
         expected_revision: revision,
         reason: reason,
         decision: decision
       })
       when is_integer(revision) and revision > 0 and is_binary(reason) and
              byte_size(reason) <= 4096 do
    with {:ok, id} <- Ecto.UUID.cast(id),
         true <- String.valid?(reason),
         trimmed when trimmed != "" <- String.trim(reason),
         :ok <- validate_decision(decision) do
      {:ok, %{query_id: id, revision: revision, reason: trimmed, decision: decision}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_input}
    end
  end

  defp command(_), do: {:error, :invalid_input}

  defp validate_decision(decision) when decision in [:resolve_no_change, :dismiss], do: :ok

  defp validate_decision(decision) when decision in @unsupported_decisions,
    do: {:error, :unsupported_decision}

  defp validate_decision(_), do: {:error, :invalid_decision}

  defp execute(actor_id, event_id, round_id, command) do
    case Repo.transaction(fn ->
           scope = lock_scope!(actor_id, event_id, round_id, command)
           decide_locked!(scope, command)
         end) do
      {:ok, result} -> {:ok, result}
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
      subject = subject!(command.query_id, round_id)
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
          query_id: command.query_id,
          revision: command.revision,
          decision: command.decision,
          query_status: subject.status
        })

      sides = side_rows(scope)
      validate_side_scope!(sides)
      acquire!(competition_side: Enum.map(sides, & &1.side_id))
      acquire!(competition_side_result: Enum.map(sides, & &1.result_id))
      acquire!(score_row: [scope.card_id])
      scope = Map.put(scope, :sides, sides)
      validate_locked!(scope)
      scope
    else
      false -> Repo.rollback(:not_found_or_forbidden)
      {:error, _} -> Repo.rollback(:not_found_or_forbidden)
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
    current = subject!(scope.query_id, scope.round_id)
    sides = side_rows(scope)
    validate_side_scope!(sides)
    validate_decidable_status!(current.status)

    unless authorized?(scope.actor_id, scope.event_id) and valid_round?(scope),
      do: Repo.rollback(:not_found_or_forbidden)

    validate_revision!(current, scope)
    validate_affected_scope!(current, sides, scope)
    validate_review!(current, sides)
  end

  defp validate_revision!(current, scope) do
    unless current.current_revision == scope.revision and current.query_revision == scope.revision,
      do: Repo.rollback(:stale_revision)
  end

  defp validate_affected_scope!(current, sides, scope) do
    unless Map.take(current, [:hole_id, :card_id, :entry_id, :group_id]) ==
             Map.take(scope, [:hole_id, :card_id, :entry_id, :group_id]) and
             side_keys(sides) == side_keys(scope.sides),
           do: Repo.rollback(:scope_changed)
  end

  defp validate_review!(current, sides) do
    unless current.card_state == "review_required",
      do: Repo.rollback(:unsupported_scorecard_state)

    unless Enum.all?(sides, &(&1.state == "review_required")),
      do: Repo.rollback(:unsupported_side_result_state)
  end

  defp validate_decidable_status!(status) do
    cond do
      status in ["open", "escalated", :open, :escalated] -> :ok
      status in ["resolved", "dismissed", :resolved, :dismissed] -> Repo.rollback(:terminal_query)
      true -> Repo.rollback(:invalid_query_state)
    end
  end

  defp valid_round?(scope),
    do:
      Repo.query!("SELECT event_id::text, state FROM rounds WHERE id = $1::uuid", [
        uuid(scope.round_id)
      ]).rows in [[[scope.event_id, "scoring_open"]], [[scope.event_id, "scoring_closed"]]]

  defp decide_locked!(scope, command) do
    query = Ash.get!(ScoreQuery, scope.query_id, authorize?: false)
    original_status = query.status

    gate = %{
      scope: scope,
      reason: command.reason,
      decision: command.decision,
      original: Map.take(query, @evidence_fields),
      original_status: original_status,
      token: make_ref(),
      transaction_id: transaction_id(),
      phase: :ready
    }

    Process.put(@gate_key, gate)

    try do
      action =
        case command.decision do
          :resolve_no_change -> :resolve_no_change_internal
          :dismiss -> :dismiss_internal
        end

      query
      |> Changeset.for_update(action, %{})
      |> Changeset.set_context(%{score_query_decision: gate.token})
      |> Ash.update(authorize?: false)
      |> unwrap!()

      case Process.get(@gate_key) do
        %{phase: :complete, result: result} -> result
        _ -> Repo.rollback(:incomplete_query_decision)
      end
    after
      Process.delete(@gate_key)
    end
  end

  @doc false
  def around_resolve_no_change(changeset, callback),
    do: around_terminal(changeset, callback, :resolved, "resolve_score_query_no_change")

  @doc false
  def around_dismiss(changeset, callback),
    do: around_terminal(changeset, callback, :dismissed, "dismiss_score_query")

  defp around_terminal(changeset, callback, target_status, audit_action) do
    gate = gate!(changeset)
    validate_locked!(gate.scope)
    original_status = gate.original_status

    unless Map.take(changeset.data, @evidence_fields) == gate.original and
             changeset.data.status == original_status and
             original_status in [:open, :escalated] and
             Enum.all?(Map.keys(changeset.attributes), &(&1 == :updated_at)),
           do: Repo.rollback(:invalid_query_decision)

    Process.put(@gate_key, %{gate | phase: :writing})

    resolved_at = DateTime.utc_now(:microsecond)

    changeset =
      changeset
      |> Changeset.filter(
        id: gate.scope.query_id,
        status: original_status,
        hole_result_revision: gate.scope.revision
      )
      |> Changeset.force_change_attribute(:status, target_status)
      |> Changeset.force_change_attribute(:resolved_by_staff_user_id, gate.scope.actor_id)
      |> Changeset.force_change_attribute(:resolution_reason, gate.reason)
      |> Changeset.force_change_attribute(:resolved_at, resolved_at)
      |> Changeset.force_change_attribute(:resolved_by_round_entry_id, nil)

    case callback.(changeset) do
      {:ok, query, changeset, instructions} ->
        complete!(gate, query, target_status, audit_action)
        {:ok, query, changeset, instructions}

      {:error, error} ->
        Repo.rollback(error)
    end
  end

  defp gate!(changeset) do
    gate = Process.get(@gate_key)

    unless Repo.in_transaction?() and is_map(gate) and gate.phase == :ready and
             changeset.context[:score_query_decision] == gate.token and
             gate.transaction_id == transaction_id(),
           do: Repo.rollback(:invalid_query_decision_capability)

    gate
  end

  defp complete!(gate, query, target_status, audit_action) do
    persisted = Ash.get!(ScoreQuery, gate.scope.query_id, authorize?: false)

    unless query.status == target_status and persisted.status == target_status and
             Map.take(query, @evidence_fields) == gate.original and
             Map.take(persisted, @evidence_fields) == gate.original and
             query.resolution_reason == gate.reason and
             query.resolved_by_staff_user_id == gate.scope.actor_id and
             not is_nil(query.resolved_at) and
             is_nil(query.resolved_by_round_entry_id),
           do: Repo.rollback(:invalid_query_decision_evidence)

    audit = audit!(gate, audit_action, target_status)

    result = %{
      score_query: persisted,
      audit: audit,
      event_id: gate.scope.event_id,
      decision: gate.decision,
      side_results: Enum.map(gate.scope.sides, &%{id: &1.result_id})
    }

    Process.put(@gate_key, Map.merge(gate, %{phase: :complete, result: result}))
  end

  defp audit!(gate, action, target_status) do
    Audit.record_staff_event(
      %{
        actor_staff_user_id: gate.scope.actor_id,
        action: action,
        target_type: "ScoreQuery",
        target_id: gate.scope.query_id,
        reason: gate.reason,
        context: %{
          event_id: gate.scope.event_id,
          round_id: gate.scope.round_id,
          hole_result_id: gate.scope.hole_id,
          scorecard_id: gate.scope.card_id,
          hole_result_revision: gate.scope.revision,
          decision: Atom.to_string(gate.decision)
        },
        changes: %{
          status: %{from: Atom.to_string(gate.original_status), to: Atom.to_string(target_status)}
        }
      },
      authorize?: false
    )
    |> unwrap!()
  end

  defp side_keys(sides), do: Enum.map(sides, &{&1.side_id, &1.result_id})

  defp authorized?(actor, event), do: ActiveEventRole.authorized?(actor, event, @manager_roles)

  defp acquire!(request), do: request |> LockProtocol.acquire!() |> unwrap!()
  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, error}), do: Repo.rollback(error)
  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
