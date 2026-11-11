defmodule GolfScoring.Scoring.Services.VerifyHoleResult do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Accounts.PlayerAccessGrant
  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.ScoreVerification
  alias GolfScoring.Scoring.ScoreVerificationWriteGuard

  @verification_gate_key {__MODULE__, :verification_write}

  def run(actor, event_id, round_id, command),
    do: execute(actor, event_id, round_id, command, :verify)

  def override(actor, event_id, round_id, command),
    do: execute(actor, event_id, round_id, command, :override)

  defp execute(actor, event_id, round_id, command, operation) do
    if Repo.in_transaction?() do
      {:error, :outer_transaction_required}
    else
      execute_standalone(actor, event_id, round_id, command, operation)
    end
  end

  defp execute_standalone(actor, event_id, round_id, command, operation) when is_map(command) do
    with {:ok, event_id} <- Ecto.UUID.cast(event_id),
         {:ok, round_id} <- Ecto.UUID.cast(round_id),
         {:ok, group_id} <- Ecto.UUID.cast(command[:playing_group_id]),
         {:ok, result_id} <- Ecto.UUID.cast(command[:hole_result_id]),
         revision when is_integer(revision) and revision > 0 <- command[:hole_result_revision] do
      Repo.transaction(fn ->
        execute_locked(
          actor,
          %{
            event_id: event_id,
            round_id: round_id,
            group_id: group_id,
            result_id: result_id,
            revision: revision
          },
          command,
          operation
        )
      end)
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp execute_standalone(_, _, _, _, _), do: {:error, :invalid_input}

  defp execute_locked(actor, ids, command, operation) do
    with {:ok, actor_context} <- lock_actor(actor, ids.event_id, operation),
         {:ok, scope} <- lock_scope(ids.round_id, ids.group_id),
         :ok <- validate_scope(scope, ids.event_id, ids.round_id),
         {:ok, assignments} <- lock_assignments(ids.group_id),
         {:ok, scorecard_id} <- find_scorecard(ids.result_id),
         {:ok, _} <- LockProtocol.acquire!(score_row: [scorecard_id]),
         {:ok, result} <- current_result(ids.result_id, scorecard_id),
         :ok <- validate_result(result, ids.round_id, ids.group_id, ids.revision),
         {:ok, evidence} <- eligibility(actor_context, assignments, result, command, operation),
         {:ok, verification} <- certify(result, ids.group_id, evidence, operation, ids.event_id) do
      verification
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp lock_actor(%PlayerAccessGrant{id: id}, event_id, :verify) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         [[player_id, state, expires_at]] <-
           Repo.query!(
             "SELECT player_id::text, state, expires_at FROM player_access_grants WHERE id = $1::uuid AND event_id = $2::uuid FOR UPDATE",
             [uuid(id), uuid(event_id)]
           ).rows,
         true <-
           state == "active" and
             not PlayerAccessGrantGuard.grant_expired?(
               %{expires_at: expires_at},
               DateTime.utc_now()
             ) do
      {:ok, %{player_id: Ecto.UUID.cast!(player_id), expires_at: expires_at}}
    else
      _ -> {:error, :invalid_player_session}
    end
  end

  defp lock_actor(%StaffUser{id: id}, event_id, :override) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, _} <- EventAuthorityLock.lock_scope!(event_id, [id]),
         true <- ActiveEventRole.authorized?(id, event_id, [:event_admin, :competition_manager]) do
      {:ok, %{staff_id: id}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp lock_actor(_, _, _), do: {:error, :invalid_actor}

  defp lock_scope(round_id, group_id) do
    with {:ok, %{acquired: rows}} <-
           LockProtocol.acquire!(round: [round_id], playing_group: [group_id]) do
      {:ok,
       %{
         round: Enum.find(rows, &(&1.class == :round)).row,
         group: Enum.find(rows, &(&1.class == :playing_group)).row
       }}
    end
  end

  defp validate_scope(%{round: round, group: group}, event_id, round_id) do
    if round.event_id == event_id and round.state in ["scoring_open", "scoring_closed"] and
         group.round_id == round_id,
       do: :ok,
       else: {:error, :invalid_scope}
  end

  defp lock_assignments(group_id) do
    ids =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY id",
        [uuid(group_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    with {:ok, %{acquired: rows}} <- LockProtocol.acquire!(group_role_assignment: ids) do
      {:ok, Enum.map(rows, & &1.row)}
    end
  end

  defp find_scorecard(result_id) do
    case Repo.query!("SELECT scorecard_id::text FROM hole_results WHERE id = $1::uuid", [
           uuid(result_id)
         ]).rows do
      [[id]] -> {:ok, Ecto.UUID.cast!(id)}
      [] -> {:error, :hole_result_not_found}
    end
  end

  defp current_result(result_id, scorecard_id) do
    case Repo.query!(
           """
           SELECT hr.round_id::text, hr.revision, sc.round_entry_id::text, re.playing_group_id::text
           FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id
           JOIN round_entries re ON re.id = sc.round_entry_id
           WHERE hr.id = $1::uuid AND sc.id = $2::uuid
           """,
           [uuid(result_id), uuid(scorecard_id)]
         ).rows do
      [[round, revision, subject, group]] ->
        {:ok,
         %{
           id: result_id,
           scorecard_id: scorecard_id,
           round_id: Ecto.UUID.cast!(round),
           revision: revision,
           subject_id: Ecto.UUID.cast!(subject),
           group_id: cast_optional(group)
         }}

      [] ->
        {:error, :hole_result_not_found}
    end
  end

  defp validate_result(result, round_id, group_id, revision) do
    cond do
      result.round_id != round_id or result.group_id != group_id -> {:error, :invalid_scope}
      result.revision != revision -> {:error, :stale_revision}
      true -> :ok
    end
  end

  defp eligibility(%{player_id: player_id} = grant, assignments, result, command, :verify) do
    with false <- PlayerAccessGrantGuard.grant_expired?(grant, DateTime.utc_now()),
         {:ok, assignment_id} <- Ecto.UUID.cast(command[:role_assignment_id]),
         version when is_integer(version) and version > 0 <- command[:role_assignment_version],
         %{id: ^assignment_id, assignment_version: ^version} = assignment <-
           Enum.find(assignments, &(&1.id == assignment_id)),
         [[entry_id]] <-
           Repo.query!(
             "SELECT id::text FROM round_entries WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND player_id = $3::uuid AND registration_status IN ('expected','checked_in') AND participation_status IN ('not_started','active','completed') FOR UPDATE",
             [uuid(result.round_id), uuid(result.group_id), uuid(player_id)]
           ).rows,
         entry_id <- Ecto.UUID.cast!(entry_id),
         true <- assignment.round_entry_id == entry_id and entry_id != result.subject_id,
         true <- eligible_role?(assignment, assignments, result.subject_id) do
      {:ok,
       %{
         verifier_round_entry_id: entry_id,
         role_assignment_id: assignment.id,
         role_assignment_version: version
       }}
    else
      _ -> {:error, :ineligible_verifier}
    end
  end

  defp eligibility(%{staff_id: id}, _assignments, _result, command, :override) do
    case command[:reason] do
      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> {:error, :reason_required}
          trimmed -> {:ok, %{overridden_by_staff_user_id: id, override_reason: trimmed}}
        end

      _ ->
        {:error, :reason_required}
    end
  end

  defp eligible_role?(%{role: "designated_verifier"}, _, _), do: true

  defp eligible_role?(%{role: "primary_scorer"}, assignments, subject_id),
    do:
      Enum.any?(
        assignments,
        &(&1.role == "designated_verifier" and &1.round_entry_id == subject_id)
      )

  defp eligible_role?(_, _, _), do: false

  defp certify(result, group_id, evidence, operation, event_id) do
    authority = %{operation: operation, evidence: evidence, event_id: event_id}

    existing =
      ScoreVerification
      |> Ash.Query.filter(
        hole_result_id == ^result.id and hole_result_revision == ^result.revision
      )
      |> Ash.read_one!(authorize?: false)

    with {:ok, pending} <- pending(existing, result, group_id, authority),
         {:ok, verification} <- transition(pending, evidence, operation, authority),
         :ok <- audit_override(verification, evidence, operation, pending.status) do
      {:ok, verification}
    end
  end

  defp pending(nil, result, group_id, authority) do
    ScoreVerification
    |> Changeset.for_create(:create_pending_internal, %{
      hole_result_id: result.id,
      hole_result_revision: result.revision,
      scorecard_id: result.scorecard_id,
      round_id: result.round_id,
      playing_group_id: group_id,
      subject_round_entry_id: result.subject_id
    })
    |> write_verification(authority)
  end

  defp pending(existing, result, group_id, _authority) do
    if existing.scorecard_id == result.scorecard_id and existing.round_id == result.round_id and
         existing.subject_round_entry_id == result.subject_id and
         existing.playing_group_id == group_id do
      {:ok, existing}
    else
      {:error, :conflicting_certification}
    end
  end

  defp transition(%{status: :pending} = pending, evidence, operation, authority) do
    action = if operation == :verify, do: :verify_internal, else: :override_internal
    pending |> Changeset.for_update(action, evidence) |> write_verification(authority)
  end

  defp transition(%{status: :verified} = existing, evidence, :verify, _authority) do
    if Enum.all?(evidence, fn {key, value} -> Map.get(existing, key) == value end),
      do: {:ok, existing},
      else: {:error, :conflicting_certification}
  end

  defp transition(%{status: :overridden} = existing, evidence, :override, _authority) do
    if Enum.all?(evidence, fn {key, value} -> Map.get(existing, key) == value end),
      do: {:ok, existing},
      else: {:error, :conflicting_certification}
  end

  defp transition(_, _, _, _), do: {:error, :conflicting_certification}

  # Issuance stays private and follows locked actor, assignment and revision checks.
  defp write_verification(changeset, authority) do
    proof = %{
      owner: __MODULE__,
      operation: authority.operation,
      authority: authority,
      action: changeset.action.name,
      scope: ScoreVerificationWriteGuard.scope(changeset),
      record: changeset.data,
      pid: self(),
      token: make_ref(),
      transaction_id: verification_transaction_id(),
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
         Repo.in_transaction?() and proof.transaction_id == verification_transaction_id() do
      Process.put(@verification_gate_key, %{proof | used?: true})
      :ok
    else
      {:error, :unauthorized_verification_write}
    end
  end

  defp verification_transaction_id,
    do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()

  defp audit_override(_, _, :verify, _), do: :ok
  defp audit_override(_, _, :override, :overridden), do: :ok

  defp audit_override(verification, evidence, :override, :pending) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: evidence.overridden_by_staff_user_id,
             action: "override_hole_verification",
             target_type: "ScoreVerification",
             target_id: verification.id,
             context: %{
               round_id: verification.round_id,
               hole_result_id: verification.hole_result_id,
               hole_result_revision: verification.hole_result_revision
             },
             changes: %{status: "overridden"},
             reason: evidence.override_reason
           },
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp cast_optional(nil), do: nil
  defp cast_optional(id), do: Ecto.UUID.cast!(id)
end
