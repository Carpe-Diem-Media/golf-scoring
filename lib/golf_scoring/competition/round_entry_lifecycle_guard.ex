defmodule GolfScoring.Competition.RoundEntryLifecycleGuard do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Repo

  @registration_roles [:event_admin, :competition_manager, :registration_staff]
  @post_play_round_states ~w(scoring_closed finalized cancelled)

  @impl true
  def change(changeset, opts, context) do
    operation = Keyword.fetch!(opts, :operation)
    actor_id = if is_map(context.actor), do: Map.get(context.actor, :id), else: nil

    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      if Repo.in_transaction?() do
        Ash.Changeset.add_error(changeset,
          field: :registration_status,
          message: ":transaction_already_open"
        )
      else
        changeset
      end
    end)
    |> Ash.Changeset.before_action(fn changeset ->
      apply_operation(changeset, operation, actor_id)
    end)
  end

  defp apply_operation(changeset, operation, actor_id) do
    entry = changeset.data

    with {:ok, _scope} <- EventAuthorityLock.lock_scope!(entry.event_id, [actor_id]),
         :ok <- authorize(actor_id, entry.event_id),
         {:ok, round} <- lock_round(entry.round_id),
         :ok <- round_allows_operation(round, operation),
         {:ok, locked_entry} <- lock_round_entry(entry.id),
         :ok <- validate_active_role_not_blocking(locked_entry.id, operation),
         :ok <- validate_transition(locked_entry, operation),
         {:ok, attrs} <- build_attrs(locked_entry, operation, actor_id) do
      Enum.reduce(attrs, Map.put(changeset, :data, locked_entry), fn {field, value}, cs ->
        Ash.Changeset.force_change_attribute(cs, field, value)
      end)
    else
      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :registration_status, message: message)
    end
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @registration_roles) do
      :ok
    else
      {:error,
       "an active EventAdmin, CompetitionManager, or RegistrationStaff assignment for this Event is required"}
    end
  end

  defp lock_round(round_id) do
    case Repo.query!(
           "SELECT id::text, state FROM rounds WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id, state]] -> {:ok, %{id: Ecto.UUID.cast!(id), state: state}}
      [] -> {:error, "Round does not exist"}
    end
  end

  defp lock_round_entry(round_entry_id) do
    case Repo.query!(
           """
           SELECT id::text, event_id::text, round_id::text, player_id::text,
                  registration_status, participation_status
           FROM round_entries
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_entry_id)]
         ).rows do
      [[id, event_id, round_id, player_id, registration_status, participation_status]] ->
        {:ok,
         %RoundEntry{
           id: Ecto.UUID.cast!(id),
           event_id: Ecto.UUID.cast!(event_id),
           round_id: Ecto.UUID.cast!(round_id),
           player_id: Ecto.UUID.cast!(player_id),
           registration_status: registration_atom(registration_status),
           participation_status: participation_atom(participation_status)
         }}

      [] ->
        {:error, "RoundEntry does not exist"}
    end
  end

  defp round_allows_operation(%{state: state}, :check_in_round_entry)
       when state in @post_play_round_states do
    {:error, "cannot check in while the Round is #{state}"}
  end

  defp round_allows_operation(%{state: state}, operation)
       when operation in [:mark_no_show, :withdraw_before_start] and
              state in @post_play_round_states do
    {:error, "cannot update registration while the Round is #{state}"}
  end

  defp round_allows_operation(_round, _operation), do: :ok

  defp validate_active_role_not_blocking(_entry_id, :check_in_round_entry), do: :ok

  defp validate_active_role_not_blocking(entry_id, operation)
       when operation in [:mark_no_show, :withdraw_before_start] do
    case GroupRoleAssignmentGuard.reject_active_role_registration_transition(entry_id) do
      :ok ->
        :ok

      {:error, :active_group_role_assignment_blocks_registration_transition} ->
        {:error, "RoundEntry holds an active group role; hand over or revoke first"}
    end
  end

  defp validate_active_role_not_blocking(_entry_id, _operation), do: :ok

  defp validate_transition(%{registration_status: status}, _operation)
       when status in [:no_show, :withdrawn_before_start, :replaced_before_start] do
    {:error, "registration is terminal for this RoundEntry"}
  end

  defp validate_transition(%{participation_status: status}, _operation)
       when status != :not_started do
    {:error, "RoundEntry participation is already #{status}"}
  end

  defp validate_transition(%{registration_status: :expected}, :check_in_round_entry), do: :ok

  defp validate_transition(%{registration_status: :checked_in}, :check_in_round_entry) do
    {:error, "RoundEntry is already checked in"}
  end

  defp validate_transition(
         %{registration_status: status},
         operation
       )
       when status in [:expected, :checked_in] and
              operation in [:mark_no_show, :withdraw_before_start],
       do: :ok

  defp validate_transition(_, _operation) do
    {:error, "RoundEntry cannot make the requested registration transition"}
  end

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

  defp build_attrs(_entry, :check_in_round_entry, actor_id) do
    {:ok,
     %{
       registration_status: :checked_in,
       checked_in_at: DateTime.utc_now(:microsecond),
       checked_in_by_staff_user_id: actor_id
     }}
  end

  defp build_attrs(_entry, :mark_no_show, _actor_id) do
    {:ok, %{registration_status: :no_show}}
  end

  defp build_attrs(_entry, :withdraw_before_start, _actor_id) do
    {:ok, %{registration_status: :withdrawn_before_start}}
  end
end
