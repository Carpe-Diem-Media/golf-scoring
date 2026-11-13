defmodule GolfScoring.Competition.Services.ReplaceRoundEntry do
  @moduledoc false

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.GroupRoleAssignmentGuard
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]
  @pre_open_round_states ~w(draft ready)

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{original: RoundEntry.t(), replacement: RoundEntry.t()}} | {:error, term()}
  def run(actor, event_id, round_id, original_entry_id, replacement_player_id)
      when is_map(actor) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      run_standalone(actor, event_id, round_id, original_entry_id, replacement_player_id)
    end
  end

  def run(_actor, _event_id, _round_id, _original_entry_id, _replacement_player_id),
    do: {:error, :invalid_input}

  defp run_standalone(actor, event_id, round_id, original_entry_id, replacement_player_id) do
    actor_id = Map.get(actor, :id)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_replacement(round),
           {:ok, playing_group_id} <- fetch_playing_group_id(original_entry_id, round_id),
           :ok <- lock_playing_group_if_present(playing_group_id),
           {:ok, side_memberships} <- fetch_side_memberships(original_entry_id),
           :ok <- lock_side_membership_scope(side_memberships),
           {:ok, original} <- lock_round_entry(original_entry_id),
           :ok <- original_belongs_to_round(original, round_id, event_id),
           :ok <- verify_group_unchanged(original, playing_group_id),
           :ok <- GroupRoleAssignmentGuard.reject_active_role_replacement(original.id),
           :ok <- validate_original(original, replacement_player_id),
           :ok <- replacement_player_exists(replacement_player_id),
           :ok <- replacement_available(round_id, replacement_player_id),
           {:ok, marked} <- mark_original_replaced(original.id),
           {:ok, replacement} <- create_replacement(marked, replacement_player_id),
           :ok <- copy_side_memberships(side_memberships, replacement) do
        %{original: marked, replacement: replacement}
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

  defp round_accepts_replacement(%{state: state}) when state in @pre_open_round_states, do: :ok
  defp round_accepts_replacement(%{state: state}), do: {:error, {:invalid_round_state, state}}

  defp fetch_playing_group_id(original_entry_id, round_id) do
    case Repo.query!(
           """
           SELECT playing_group_id::text
           FROM round_entries
           WHERE id = $1::uuid AND round_id = $2::uuid
           """,
           [Ecto.UUID.dump!(original_entry_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [[nil]] -> {:ok, nil}
      [[group_id]] -> {:ok, Ecto.UUID.cast!(group_id)}
      [] -> {:error, :round_entry_not_found}
    end
  end

  defp lock_playing_group_if_present(nil), do: :ok

  defp lock_playing_group_if_present(playing_group_id) do
    case Repo.query!(
           "SELECT id::text FROM playing_groups WHERE id = $1::uuid FOR UPDATE",
           [Ecto.UUID.dump!(playing_group_id)]
         ).rows do
      [[_id]] -> :ok
      [] -> {:error, :playing_group_not_found}
    end
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

  defp verify_group_unchanged(%{playing_group_id: current}, expected) when current == expected,
    do: :ok

  defp verify_group_unchanged(_original, _expected),
    do: {:error, :playing_group_changed_under_lock}

  defp original_belongs_to_round(original, round_id, event_id) do
    if original.round_id == round_id and original.event_id == event_id do
      :ok
    else
      {:error, :round_entry_mismatch}
    end
  end

  defp validate_original(original, replacement_player_id) do
    cond do
      original.registration_status in [:no_show, :withdrawn_before_start, :replaced_before_start] ->
        {:error, :terminal_registration}

      original.participation_status != :not_started ->
        {:error, :participation_started}

      original.registration_status not in [:expected, :checked_in] ->
        {:error, :invalid_registration}

      original.player_id == replacement_player_id ->
        {:error, :same_player}

      true ->
        :ok
    end
  end

  defp replacement_player_exists(player_id) do
    if Repo.get(Player, player_id), do: :ok, else: {:error, :player_not_found}
  end

  defp replacement_available(round_id, replacement_player_id) do
    case Repo.query!(
           "SELECT 1 FROM round_entries WHERE round_id = $1::uuid AND player_id = $2::uuid LIMIT 1",
           [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(replacement_player_id)]
         ).rows do
      [] -> :ok
      [_row] -> {:error, :replacement_already_entered}
    end
  end

  defp mark_original_replaced(original_id) do
    RoundEntry
    |> Ash.get!(original_id, authorize?: false)
    |> Changeset.for_update(:mark_replaced_before_start_internal, %{})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, entry} -> {:ok, entry}
      {:error, _error} -> {:error, :mark_original_failed}
    end
  end

  defp create_replacement(original, replacement_player_id) do
    RoundEntry
    |> Changeset.for_create(:create_replacement_entry_internal, %{
      event_id: original.event_id,
      round_id: original.round_id,
      player_id: replacement_player_id,
      playing_group_id: original.playing_group_id
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, entry} -> {:ok, entry}
      {:error, error} -> {:error, error}
    end
  end

  defp fetch_side_memberships(original_entry_id) do
    rows =
      Repo.query!(
        """
        SELECT round_competition_id::text, competition_side_id::text, round_id::text
        FROM competition_side_memberships
        WHERE round_entry_id = $1::uuid
        ORDER BY round_competition_id, competition_side_id
        """,
        [Ecto.UUID.dump!(original_entry_id)]
      ).rows

    memberships =
      Enum.map(rows, fn [round_competition_id, competition_side_id, round_id] ->
        %{
          round_competition_id: Ecto.UUID.cast!(round_competition_id),
          competition_side_id: Ecto.UUID.cast!(competition_side_id),
          round_id: Ecto.UUID.cast!(round_id)
        }
      end)

    {:ok, memberships}
  end

  defp lock_side_membership_scope([]), do: :ok

  defp lock_side_membership_scope(memberships) do
    competition_ids =
      memberships
      |> Enum.map(& &1.round_competition_id)
      |> Enum.uniq()
      |> Enum.sort_by(&Ecto.UUID.dump!/1)

    side_ids =
      memberships
      |> Enum.map(& &1.competition_side_id)
      |> Enum.uniq()
      |> Enum.sort_by(&Ecto.UUID.dump!/1)

    with :ok <- lock_round_competitions(competition_ids) do
      lock_competition_sides(side_ids)
    end
  end

  defp lock_round_competitions(competition_ids) do
    for competition_id <- competition_ids do
      case Repo.query!(
             "SELECT id::text FROM round_competitions WHERE id = $1::uuid FOR UPDATE",
             [Ecto.UUID.dump!(competition_id)]
           ).rows do
        [[_id]] -> :ok
        [] -> throw({:error, :round_competition_not_found})
      end
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp lock_competition_sides(side_ids) do
    for side_id <- side_ids do
      case Repo.query!(
             "SELECT id::text FROM competition_sides WHERE id = $1::uuid FOR UPDATE",
             [Ecto.UUID.dump!(side_id)]
           ).rows do
        [[_id]] -> :ok
        [] -> throw({:error, :competition_side_not_found})
      end
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp copy_side_memberships([], _replacement), do: :ok

  defp copy_side_memberships(memberships, replacement) do
    for membership <- memberships do
      case CompetitionSideMembership
           |> Changeset.for_create(:create_internal, %{
             round_competition_id: membership.round_competition_id,
             competition_side_id: membership.competition_side_id,
             round_entry_id: replacement.id,
             round_id: membership.round_id
           })
           |> Ash.create(authorize?: false) do
        {:ok, _} -> :ok
        {:error, error} -> throw({:error, error})
      end
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}

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
end
