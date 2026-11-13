defmodule GolfScoring.Competition.Services.AssignGroupRole do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Competition.StartingParticipant
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), atom()) ::
          {:ok, GroupRoleAssignment.t()} | {:error, term()}
  def run(actor, event_id, round_id, playing_group_id, round_entry_id, role)
      when role in [:primary_scorer, :designated_verifier] and is_map(actor) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      run_standalone(actor, event_id, round_id, playing_group_id, round_entry_id, role)
    end
  end

  def run(_actor, _event_id, _round_id, _playing_group_id, _round_entry_id, _role),
    do: {:error, :invalid_input}

  defp run_standalone(actor, event_id, round_id, playing_group_id, round_entry_id, role) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_assignment(round),
           {:ok, group} <- lock_playing_group(playing_group_id),
           :ok <- group_belongs_to_round(group, round_id),
           :ok <- GroupRoleAssignmentGuard.lock_active_assignments_for_group(Repo, group.id),
           {:ok, entry} <- lock_round_entry(round_entry_id),
           :ok <- entry_belongs_to_round(entry, round_id, event_id),
           :ok <- entry_in_group(entry, playing_group_id),
           :ok <- validate_start_eligible(entry),
           :ok <- ensure_no_active_holder(group.id, role),
           :ok <- ensure_entry_not_other_role(group.id, round_entry_id, role),
           {:ok, assignment} <- create_assignment(group, entry, role) do
        assignment
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, :forbidden}
    end
  end

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

  defp round_accepts_assignment(%{state: state}) when state in @pre_open_round_states, do: :ok

  defp round_accepts_assignment(%{state: state}),
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

  defp lock_round_entry(round_entry_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, player_id::text,
                  registration_status, participation_status, playing_group_id::text
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_entry_id)]
         ).rows do
      [[id, event_id, round_id, player_id, registration_status, participation_status, group_id]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           player_id: Ecto.UUID.cast!(player_id),
           registration_status: registration_atom(registration_status),
           participation_status: participation_atom(participation_status),
           playing_group_id: cast_optional_uuid(group_id)
         }}

      [] ->
        {:error, :round_entry_not_found}
    end
  end

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp entry_belongs_to_round(entry, round_id, event_id) do
    if entry.round_id == round_id and entry.event_id == event_id do
      :ok
    else
      {:error, :round_entry_mismatch}
    end
  end

  defp entry_in_group(%{playing_group_id: group_id}, playing_group_id)
       when group_id == playing_group_id,
       do: :ok

  defp entry_in_group(_, _), do: {:error, :round_entry_not_in_playing_group}

  defp validate_start_eligible(entry) do
    if StartingParticipant.current_starting_participant?(entry) do
      :ok
    else
      {:error, :not_current_starting_participant}
    end
  end

  defp ensure_no_active_holder(playing_group_id, role) do
    case GroupRoleAssignmentGuard.lock_active_assignment_for_group_role(
           Repo,
           playing_group_id,
           role
         ) do
      {:error, :no_active_assignment} -> :ok
      {:ok, _} -> {:error, :active_role_already_assigned}
    end
  end

  defp ensure_entry_not_other_role(playing_group_id, round_entry_id, role) do
    if GroupRoleAssignmentGuard.entry_holds_other_active_role?(
         Repo,
         playing_group_id,
         round_entry_id,
         role
       ) do
      {:error, :round_entry_already_holds_other_active_role}
    else
      :ok
    end
  end

  defp create_assignment(group, entry, role) do
    version =
      GroupRoleAssignmentGuard.next_assignment_version(Repo, group.id, role)

    GroupRoleAssignment
    |> Changeset.for_create(:create_internal, %{
      round_id: group.round_id,
      playing_group_id: group.id,
      round_entry_id: entry.id,
      role: role,
      state: :active,
      assignment_version: version
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, assignment} -> {:ok, assignment}
      {:error, %Ash.Error.Invalid{errors: errors}} -> {:error, classify_create_error(errors)}
      {:error, error} -> {:error, error}
    end
  end

  defp classify_create_error(errors) do
    if Enum.any?(errors, &unique_violation?/1) do
      :active_role_already_assigned
    else
      :assignment_create_failed
    end
  end

  defp unique_violation?(%{caused_by: %Postgrex.Error{postgres: %{code: :unique_violation}}}),
    do: true

  defp unique_violation?(_), do: false

  defp registration_atom("expected"), do: :expected
  defp registration_atom("checked_in"), do: :checked_in
  defp registration_atom("no_show"), do: :no_show
  defp registration_atom("withdrawn_before_start"), do: :withdrawn_before_start
  defp registration_atom("replaced_before_start"), do: :replaced_before_start

  defp participation_atom("not_started"), do: :not_started
  defp participation_atom("active"), do: :active
  defp participation_atom("completed"), do: :completed
  defp participation_atom("withdrawn"), do: :withdrawn
  defp participation_atom("disqualified"), do: :disqualified

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end
