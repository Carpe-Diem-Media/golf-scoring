defmodule GolfScoring.Competition.Services.RevokeGroupRole do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Repo

  @revoke_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom(), String.t()) ::
          {:ok, GroupRoleAssignment.t()} | {:error, term()}
  def run(actor, event_id, round_id, playing_group_id, role, reason)
      when role in [:primary_scorer, :designated_verifier] and is_map(actor) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      run_standalone(actor, event_id, round_id, playing_group_id, role, reason)
    end
  end

  def run(_actor, _event_id, _round_id, _playing_group_id, _role, _reason),
    do: {:error, :invalid_input}

  defp run_standalone(actor, event_id, round_id, playing_group_id, role, reason) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           :ok <- validate_reason(reason),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_revoke(round),
           {:ok, group} <- lock_playing_group(playing_group_id),
           :ok <- group_belongs_to_round(group, round_id),
           {:ok, current} <-
             GroupRoleAssignmentGuard.lock_active_assignment_for_group_role(
               Repo,
               playing_group_id,
               role
             ),
           {:ok, revoked} <- mark_revoked(current.id),
           :ok <- write_revoke_audit(actor_id, round_id, group.id, role, revoked, reason) do
        revoked
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @revoke_roles) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_reason(reason) when is_binary(reason) do
    if String.trim(reason) == "" do
      {:error, :revoke_reason_required}
    else
      :ok
    end
  end

  defp validate_reason(_), do: {:error, :revoke_reason_required}

  defp lock_round(round_id) do
    case Repo.query!(
           "SELECT id::text, event_id::text, state FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id, event_id, state]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           state: state
         }}

      [] ->
        {:error, :round_not_found}
    end
  end

  defp round_belongs_to_event(%{event_id: round_event_id}, event_id) do
    if round_event_id == event_id, do: :ok, else: {:error, :event_mismatch}
  end

  defp round_accepts_revoke(%{state: state}) when state in @pre_open_round_states, do: :ok

  defp round_accepts_revoke(%{state: state}),
    do: {:error, {:invalid_round_state, state}}

  defp lock_playing_group(playing_group_id) do
    case Repo.query!(
           """
           SELECT id::text, round_id::text
           FROM playing_groups
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(playing_group_id)]
         ).rows do
      [[id, round_id]] ->
        {:ok, %{id: Ecto.UUID.cast!(id), round_id: Ecto.UUID.cast!(round_id)}}

      [] ->
        {:error, :playing_group_not_found}
    end
  end

  defp group_belongs_to_round(%{round_id: group_round_id}, round_id) do
    if group_round_id == round_id, do: :ok, else: {:error, :playing_group_mismatch}
  end

  defp mark_revoked(assignment_id) do
    GroupRoleAssignment
    |> Ash.get!(assignment_id, authorize?: false)
    |> Changeset.for_update(:mark_revoked_internal, %{})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, error} -> {:error, error}
    end
  end

  defp write_revoke_audit(actor_id, round_id, playing_group_id, role, revoked, reason) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: actor_id,
             action: "revoke_group_role",
             target_type: "PlayingGroup",
             target_id: playing_group_id,
             context: %{
               round_id: round_id,
               role: to_string(role)
             },
             changes: %{
               assignment_id: revoked.id,
               round_entry_id: revoked.round_entry_id,
               assignment_version: revoked.assignment_version
             },
             reason: reason
           },
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end
