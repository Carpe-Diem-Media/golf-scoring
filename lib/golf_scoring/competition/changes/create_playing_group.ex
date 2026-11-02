defmodule GolfScoring.Competition.Changes.CreatePlayingGroup do
  @moduledoc false

  use Ash.Resource.Change

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @impl true
  def change(changeset, _opts, context) do
    actor_id = if is_map(context.actor), do: Map.get(context.actor, :id), else: nil

    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      event_id = Ash.Changeset.get_argument(changeset, :event_id)
      round_id = Ash.Changeset.get_attribute(changeset, :round_id)

      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_group_configuration(round) do
        changeset
        |> Ash.Changeset.force_change_attribute(:state, :not_started)
        |> Ash.Changeset.set_context(%{
          ready_configuration_audit: %{
            actor_id: actor_id,
            event_id: event_id,
            round_id: round.id,
            round_state: round.state
          }
        })
      else
        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :round_id, message: message)
      end
    end)
    |> Ash.Changeset.after_action(fn changeset, group ->
      write_audit_if_ready(changeset, group)
    end)
  end

  defp authorize(actor_id, event_id) do
    if ActiveEventRole.authorized?(actor_id, event_id, @manager_roles) do
      :ok
    else
      {:error, "an active EventAdmin or CompetitionManager assignment for this Event is required"}
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
        {:error, "Round does not exist"}
    end
  end

  defp round_belongs_to_event(%{event_id: round_event_id}, event_id) do
    if round_event_id == event_id do
      :ok
    else
      {:error, "Round does not belong to the requested Event"}
    end
  end

  defp round_accepts_group_configuration(%{state: state}) when state in @pre_open_round_states,
    do: :ok

  defp round_accepts_group_configuration(%{state: state}) do
    {:error, "cannot configure PlayingGroups while the Round is #{state}"}
  end

  defp write_audit_if_ready(
         %{context: %{ready_configuration_audit: %{round_state: "ready"} = mutation}},
         group
       ) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: mutation.actor_id,
             action: "create_playing_group",
             target_type: "round",
             target_id: mutation.round_id,
             context: %{
               "event_id" => mutation.event_id,
               "round_id" => mutation.round_id
             },
             changes: %{
               "playing_group_id" => group.id,
               "state" => %{"from" => nil, "to" => Atom.to_string(group.state)}
             }
           },
           authorize?: false
         ) do
      {:ok, _audit} -> {:ok, group}
      {:ok, _audit, _notifications} -> {:ok, group}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_audit_if_ready(_changeset, group), do: {:ok, group}
end
