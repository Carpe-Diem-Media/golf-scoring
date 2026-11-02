defmodule GolfScoring.Competition.Services.AssignPlayingGroupStart do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(
          map(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer()
        ) :: {:ok, PlayingGroup.t()} | {:error, term()}
  def run(actor, event_id, round_id, playing_group_id, starting_round_hole_id, starting_position)
      when is_map(actor) and is_integer(starting_position) and starting_position > 0 do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_assignment(round),
           {:ok, group} <- lock_playing_group(playing_group_id),
           :ok <- group_belongs_to_round(group, round_id),
           :ok <- round_hole_belongs_to_round(starting_round_hole_id, round_id),
           {:ok, updated} <-
             apply_start_assignment(group, starting_round_hole_id, starting_position),
           :ok <-
             write_audit_if_ready(
               actor_id,
               event_id,
               round,
               group,
               starting_round_hole_id,
               starting_position
             ) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  def run(_actor, _event_id, _round_id, _playing_group_id, _hole_id, _position),
    do: {:error, :invalid_input}

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
           SELECT id::text, round_id::text, starting_round_hole_id::text, starting_position
           FROM playing_groups
           WHERE id = $1::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(playing_group_id)]
         ).rows do
      [[id, round_id, hole_id, position]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           round_id: Ecto.UUID.cast!(round_id),
           starting_round_hole_id: cast_optional_uuid(hole_id),
           starting_position: position
         }}

      [] ->
        {:error, :playing_group_not_found}
    end
  end

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp group_belongs_to_round(%{round_id: group_round_id}, round_id) do
    if group_round_id == round_id, do: :ok, else: {:error, :playing_group_mismatch}
  end

  defp round_hole_belongs_to_round(round_hole_id, round_id) do
    case Repo.query!(
           "SELECT id::text FROM round_holes WHERE id = $1::uuid AND round_id = $2::uuid",
           [Ecto.UUID.dump!(round_hole_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [_row] -> :ok
      [] -> {:error, :round_hole_not_found}
    end
  end

  defp apply_start_assignment(
         %{id: group_id, starting_round_hole_id: hole_id, starting_position: position},
         starting_round_hole_id,
         starting_position
       )
       when hole_id == starting_round_hole_id and position == starting_position do
    case Ash.get(PlayingGroup, group_id, authorize?: false) do
      {:ok, group} -> {:ok, group}
      {:error, error} -> {:error, error}
    end
  end

  defp apply_start_assignment(group, starting_round_hole_id, starting_position) do
    case Ash.get(PlayingGroup, group.id, authorize?: false) do
      {:ok, record} ->
        record
        |> Changeset.for_update(:assign_start_internal, %{
          starting_round_hole_id: starting_round_hole_id,
          starting_position: starting_position
        })
        |> Ash.update(authorize?: false)

      {:error, error} ->
        {:error, error}
    end
  end

  defp write_audit_if_ready(
         actor_id,
         event_id,
         %{id: round_id, state: "ready"},
         group,
         starting_round_hole_id,
         starting_position
       ) do
    if group.starting_round_hole_id == starting_round_hole_id and
         group.starting_position == starting_position do
      :ok
    else
      case Audit.record_staff_event(
             %{
               actor_staff_user_id: actor_id,
               action: "assign_playing_group_start",
               target_type: "round",
               target_id: round_id,
               context: %{"event_id" => event_id, "round_id" => round_id},
               changes: %{
                 "playing_group_id" => group.id,
                 "starting_round_hole_id" => %{
                   "from" => group.starting_round_hole_id,
                   "to" => starting_round_hole_id
                 },
                 "starting_position" => %{
                   "from" => group.starting_position,
                   "to" => starting_position
                 }
               }
             },
             authorize?: false
           ) do
        {:ok, _audit} -> :ok
        {:ok, _audit, _notifications} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp write_audit_if_ready(
         _actor_id,
         _event_id,
         _round,
         _group,
         _starting_round_hole_id,
         _starting_position
       ),
       do: :ok

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end
