defmodule GolfScoring.Competition.Services.AssignEntryToGroup do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideGroupCohesion
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Competition.PlayingGroupReadiness
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.StartingParticipant
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, RoundEntry.t()} | {:error, term()}
  def run(actor, event_id, round_id, round_entry_id, playing_group_id)
      when is_map(actor) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_assignment(round),
           {:ok, group} <- lock_playing_group(playing_group_id),
           :ok <- group_belongs_to_round(group, round_id),
           {:ok, entry} <- lock_round_entry(round_entry_id),
           :ok <- entry_belongs_to_round(entry, round_id, event_id),
           :ok <- validate_start_eligible(entry),
           :ok <- GroupRoleAssignmentGuard.reject_active_role_group_move(entry, playing_group_id),
           :ok <- validate_competition_side_group_cohesion(round_id, entry.id, playing_group_id),
           :ok <- validate_capacity(group.id, entry),
           {:ok, updated} <- assign_entry(entry, group.id),
           :ok <- write_audit_if_ready(actor_id, event_id, round, entry, group.id) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_result()
  end

  def run(_actor, _event_id, _round_id, _round_entry_id, _playing_group_id),
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
           registration_status: registration_status,
           participation_status: participation_status,
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

  defp validate_start_eligible(entry) do
    if StartingParticipant.current_starting_participant?(entry) do
      :ok
    else
      {:error, :not_current_starting_participant}
    end
  end

  defp validate_capacity(group_id, %{playing_group_id: current, id: _entry_id} = entry)
       when current == group_id do
    if StartingParticipant.current_starting_participant?(entry) do
      :ok
    else
      {:error, :not_current_starting_participant}
    end
  end

  defp validate_capacity(group_id, entry) do
    count = StartingParticipant.count_starters_in_group_excluding_entry(Repo, group_id, entry.id)

    if count + 1 > PlayingGroupReadiness.setup_capacity_max() do
      {:error, :group_capacity_exceeded}
    else
      :ok
    end
  end

  defp validate_competition_side_group_cohesion(round_id, entry_id, target_group_id) do
    side_ids = competition_side_ids_for_entry(entry_id, round_id)

    if side_ids == [] do
      :ok
    else
      with :ok <- lock_competition_sides(side_ids, round_id),
           :ok <- lock_current_starter_entries_on_sides(side_ids, round_id) do
        verify_side_group_cohesion(side_ids, round_id, entry_id, target_group_id)
      end
    end
  end

  defp competition_side_ids_for_entry(entry_id, round_id) do
    CompetitionSideMembership
    |> Ash.Query.filter(round_entry_id == ^entry_id and round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.competition_side_id)
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp lock_competition_sides(side_ids, round_id) do
    Enum.reduce_while(side_ids, :ok, fn side_id, :ok ->
      case Repo.query!(
             """
             SELECT id::text
             FROM competition_sides
             WHERE id = $1::uuid AND round_id = $2::uuid
             FOR UPDATE
             """,
             [Ecto.UUID.dump!(side_id), Ecto.UUID.dump!(round_id)]
           ).rows do
        [[_id]] -> {:cont, :ok}
        [] -> {:halt, {:error, :competition_side_not_found}}
      end
    end)
  end

  defp lock_current_starter_entries_on_sides(side_ids, round_id) do
    side_ids
    |> Enum.flat_map(fn side_id -> current_starter_entry_ids_on_side(side_id, round_id) end)
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
    |> Enum.reduce_while(:ok, fn locked_entry_id, :ok ->
      case Repo.query!(
             "SELECT id::text FROM round_entries WHERE id = $1::uuid AND round_id = $2::uuid FOR UPDATE",
             [Ecto.UUID.dump!(locked_entry_id), Ecto.UUID.dump!(round_id)]
           ).rows do
        [[_id]] -> {:cont, :ok}
        [] -> {:halt, {:error, :round_entry_not_found}}
      end
    end)
  end

  defp current_starter_entry_ids_on_side(side_id, round_id) do
    side_id
    |> load_side_member_entries(round_id)
    |> Enum.filter(&StartingParticipant.current_starting_participant?/1)
    |> Enum.map(& &1.id)
  end

  defp verify_side_group_cohesion(side_ids, round_id, moving_entry_id, target_group_id) do
    Enum.reduce_while(side_ids, :ok, fn side_id, :ok ->
      case side_cohesion_ok?(side_id, round_id, moving_entry_id, target_group_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp side_cohesion_ok?(side_id, round_id, moving_entry_id, target_group_id) do
    starters =
      side_id
      |> load_side_member_entries(round_id)
      |> Enum.filter(&StartingParticipant.current_starting_participant?/1)

    CompetitionSideGroupCohesion.validate(starters,
      moving_entry_id: moving_entry_id,
      target_group_id: target_group_id
    )
  end

  defp load_side_member_entries(side_id, round_id) do
    Repo.query!(
      """
      SELECT re.id::text, re.event_id::text, re.round_id::text,
             re.registration_status, re.participation_status, re.playing_group_id::text
      FROM competition_side_memberships csm
      JOIN round_entries re ON re.id = csm.round_entry_id
      WHERE csm.competition_side_id = $1::uuid
        AND csm.round_id = $2::uuid
      ORDER BY re.id
      """,
      [Ecto.UUID.dump!(side_id), Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, eid, rid, reg, part, group_id] ->
      %{
        id: Ecto.UUID.cast!(id),
        event_id: Ecto.UUID.cast!(eid),
        round_id: Ecto.UUID.cast!(rid),
        registration_status: String.to_existing_atom(reg),
        participation_status: String.to_existing_atom(part),
        playing_group_id: cast_optional_uuid(group_id)
      }
    end)
  end

  defp assign_entry(%{id: entry_id, playing_group_id: current_group_id}, playing_group_id)
       when current_group_id == playing_group_id do
    case Ash.get(RoundEntry, entry_id, authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, error} -> {:error, error}
    end
  end

  defp assign_entry(entry, playing_group_id) do
    case Ash.get(RoundEntry, entry.id, authorize?: false) do
      {:ok, record} ->
        record
        |> Changeset.for_update(:assign_playing_group_internal, %{
          playing_group_id: playing_group_id
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
         %{id: entry_id, playing_group_id: current_group_id},
         playing_group_id
       )
       when current_group_id != playing_group_id do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: actor_id,
             action: "assign_entry_to_group",
             target_type: "round",
             target_id: round_id,
             context: %{"event_id" => event_id, "round_id" => round_id},
             changes: %{
               "round_entry_id" => entry_id,
               "playing_group_id" => %{
                 "from" => current_group_id,
                 "to" => playing_group_id
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

  defp write_audit_if_ready(_actor_id, _event_id, _round, _entry, _group_id), do: :ok

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end
