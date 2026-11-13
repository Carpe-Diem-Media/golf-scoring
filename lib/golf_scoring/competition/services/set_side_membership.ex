defmodule GolfScoring.Competition.Services.SetSideMembership do
  @moduledoc false

  require Ash.Query

  alias Ash.Changeset
  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.EventAuthorityLock
  alias GolfScoring.Audit
  alias GolfScoring.Competition.CompetitionSideGroupCohesion
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.FourBallStablefordV1SidePolicy
  alias GolfScoring.Repo

  @manager_roles [:event_admin, :competition_manager]

  @spec run(map(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, %{memberships: [CompetitionSideMembership.t()]}} | {:error, term()}
  def run(actor, event_id, round_id, round_competition_id, competition_side_id, round_entry_ids)
      when is_map(actor) and is_list(round_entry_ids) do
    if Repo.in_transaction?() do
      {:error, :transaction_already_open}
    else
      run_standalone(
        actor,
        event_id,
        round_id,
        round_competition_id,
        competition_side_id,
        round_entry_ids
      )
    end
  end

  def run(_actor, _event_id, _round_id, _round_competition_id, _competition_side_id, _entry_ids),
    do: {:error, :invalid_input}

  defp run_standalone(
         actor,
         event_id,
         round_id,
         round_competition_id,
         competition_side_id,
         round_entry_ids
       ) do
    actor_id = Map.get(actor, :id)
    round_entry_ids = normalize_entry_ids(round_entry_ids)

    Repo.transaction(fn ->
      with {:ok, _scope} <- EventAuthorityLock.lock_scope!(event_id, [actor_id]),
           :ok <- authorize(actor_id, event_id),
           {:ok, round} <- lock_round(round_id),
           :ok <- round_belongs_to_event(round, event_id),
           :ok <- round_accepts_membership(round),
           {:ok, competition} <- lock_round_competition(round_competition_id, round_id),
           {:ok, affected_side_ids} <-
             {:ok,
              collect_affected_side_ids(
                round_competition_id,
                competition_side_id,
                round_entry_ids
              )},
           :ok <- lock_competition_sides(affected_side_ids, round_competition_id, round_id),
           {:ok, side} <-
             fetch_competition_side(competition_side_id, round_competition_id, round_id),
           {:ok, entries} <- lock_round_entries(round_entry_ids, round_id, event_id),
           :ok <- validate_scope(entries, round_id),
           :ok <- validate_policy(competition, side, entries),
           :ok <- validate_group_cohesion(entries),
           :ok <- remove_existing_memberships(round_competition_id, round_entry_ids),
           :ok <- replace_side_memberships(round, competition, side, round_entry_ids),
           :ok <- validate_affected_sides(competition, affected_side_ids, round_id),
           :ok <- write_audit_if_ready(actor_id, round),
           {:ok, memberships} <- load_side_memberships(competition_side_id) do
        %{memberships: memberships}
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

  defp normalize_entry_ids(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
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
           state: String.to_existing_atom(state)
         }}

      [] ->
        {:error, :round_not_found}
    end
  end

  defp round_belongs_to_event(%{event_id: round_event_id}, event_id) do
    if round_event_id == event_id, do: :ok, else: {:error, :event_mismatch}
  end

  defp round_accepts_membership(%{state: state}) when state in [:draft, :ready], do: :ok

  defp round_accepts_membership(%{state: state}),
    do: {:error, {:invalid_round_state, state}}

  defp lock_round_competition(round_competition_id, round_id) do
    case Repo.query!(
           """
           SELECT id::text, scoring_policy_identifier, solo_sides_permitted
           FROM round_competitions
           WHERE id = $1::uuid AND round_id = $2::uuid
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(round_competition_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [[id, policy, solo?]] ->
        {:ok,
         %{
           id: Ecto.UUID.cast!(id),
           scoring_policy_identifier: policy,
           solo_sides_permitted: solo? == true
         }}

      [] ->
        {:error, :round_competition_not_found}
    end
  end

  defp fetch_competition_side(competition_side_id, round_competition_id, round_id) do
    case Repo.query!(
           """
           SELECT id::text, formation
           FROM competition_sides
           WHERE id = $1::uuid
             AND round_competition_id = $2::uuid
             AND round_id = $3::uuid
           """,
           [
             Ecto.UUID.dump!(competition_side_id),
             Ecto.UUID.dump!(round_competition_id),
             Ecto.UUID.dump!(round_id)
           ]
         ).rows do
      [[id, formation]] ->
        {:ok, %{id: Ecto.UUID.cast!(id), formation: String.to_existing_atom(formation)}}

      [] ->
        {:error, :competition_side_not_found}
    end
  end

  defp collect_affected_side_ids(round_competition_id, target_side_id, round_entry_ids) do
    source_side_ids =
      if round_entry_ids == [] do
        []
      else
        CompetitionSideMembership
        |> Ash.Query.filter(
          round_competition_id == ^round_competition_id and
            round_entry_id in ^round_entry_ids
        )
        |> Ash.read!(authorize?: false)
        |> Enum.map(& &1.competition_side_id)
      end

    [target_side_id | source_side_ids]
    |> Enum.uniq()
    |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp lock_competition_sides(side_ids, round_competition_id, round_id) do
    Enum.reduce_while(side_ids, :ok, fn side_id, :ok ->
      case Repo.query!(
             """
             SELECT id::text
             FROM competition_sides
             WHERE id = $1::uuid
               AND round_competition_id = $2::uuid
               AND round_id = $3::uuid
             FOR UPDATE
             """,
             [
               Ecto.UUID.dump!(side_id),
               Ecto.UUID.dump!(round_competition_id),
               Ecto.UUID.dump!(round_id)
             ]
           ).rows do
        [[_id]] -> {:cont, :ok}
        [] -> {:halt, {:error, :competition_side_not_found}}
      end
    end)
  end

  defp validate_affected_sides(competition, side_ids, round_id) do
    Enum.reduce_while(side_ids, :ok, fn side_id, :ok ->
      case validate_one_side_composition(competition, side_id, round_id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_one_side_composition(competition, side_id, round_id) do
    with {:ok, side} <- fetch_competition_side(side_id, competition.id, round_id),
         {:ok, entries} <- load_side_member_entries(side_id, round_id) do
      validate_side_members_composition(competition, side, entries)
    end
  end

  defp validate_side_members_composition(competition, side, entries) do
    case competition.scoring_policy_identifier do
      "four_ball_stableford_v1" ->
        with :ok <-
               FourBallStablefordV1SidePolicy.validate_side_composition(
                 competition,
                 side.formation,
                 entries
               ) do
          CompetitionSideGroupCohesion.validate(entries)
        end

      _ ->
        {:error, :unsupported_scoring_policy}
    end
  end

  defp load_side_member_entries(side_id, round_id) do
    rows =
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

    {:ok, map_locked_round_entries(rows)}
  end

  defp lock_round_entries(round_entry_ids, round_id, event_id) do
    if round_entry_ids == [] do
      {:ok, []}
    else
      round_entry_ids
      |> fetch_locked_round_entry_rows(round_id)
      |> validate_locked_row_count(round_entry_ids)
      |> validate_locked_entries_event(event_id)
    end
  end

  defp fetch_locked_round_entry_rows(round_entry_ids, round_id) do
    dumped_ids = Enum.map(round_entry_ids, &Ecto.UUID.dump!/1)

    Repo.query!(
      """
      SELECT id::text, event_id::text, round_id::text,
             registration_status, participation_status, playing_group_id::text
      FROM round_entries
      WHERE round_id = $1::uuid
        AND id = ANY($2::uuid[])
      ORDER BY id
      FOR UPDATE
      """,
      [Ecto.UUID.dump!(round_id), dumped_ids]
    ).rows
  end

  defp validate_locked_row_count(rows, round_entry_ids) do
    if length(rows) == length(round_entry_ids) do
      {:ok, map_locked_round_entries(rows)}
    else
      {:error, :round_entry_not_found}
    end
  end

  defp validate_locked_entries_event({:error, _} = error, _event_id), do: error

  defp validate_locked_entries_event({:ok, entries}, event_id) do
    if Enum.all?(entries, &(&1.event_id == event_id)) do
      {:ok, entries}
    else
      {:error, :event_mismatch}
    end
  end

  defp map_locked_round_entries(rows) do
    Enum.map(rows, fn
      [id, eid, rid, reg, part, group_id] ->
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

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp validate_group_cohesion(entries), do: CompetitionSideGroupCohesion.validate(entries)

  defp validate_scope(entries, round_id) do
    if Enum.all?(entries, &(&1.round_id == round_id)),
      do: :ok,
      else: {:error, :round_entry_mismatch}
  end

  defp validate_policy(competition, side, entries) do
    case competition.scoring_policy_identifier do
      "four_ball_stableford_v1" ->
        FourBallStablefordV1SidePolicy.validate_membership(competition, side.formation, entries)

      _ ->
        {:error, :unsupported_scoring_policy}
    end
  end

  defp remove_existing_memberships(round_competition_id, round_entry_ids) do
    Enum.reduce_while(round_entry_ids, :ok, fn entry_id, :ok ->
      case destroy_memberships_for_entry(round_competition_id, entry_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp destroy_memberships_for_entry(round_competition_id, entry_id) do
    memberships =
      CompetitionSideMembership
      |> Ash.Query.filter(
        round_competition_id == ^round_competition_id and round_entry_id == ^entry_id
      )
      |> Ash.read!(authorize?: false)

    Enum.reduce_while(memberships, :ok, fn membership, :ok ->
      case Ash.destroy(membership, action: :destroy_internal, authorize?: false) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp replace_side_memberships(round, competition, side, round_entry_ids) do
    _ =
      CompetitionSideMembership
      |> Ash.Query.filter(competition_side_id == ^side.id)
      |> Ash.read!(authorize?: false)
      |> Enum.each(fn membership ->
        case Ash.destroy(membership, action: :destroy_internal, authorize?: false) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, error} -> throw({:error, error})
        end
      end)

    for entry_id <- round_entry_ids do
      case create_membership!(round, competition, side, entry_id) do
        :ok -> :ok
        {:error, reason} -> throw({:error, reason})
      end
    end

    :ok
  catch
    {:error, reason} -> {:error, reason}
  end

  defp create_membership!(round, competition, side, entry_id) do
    case CompetitionSideMembership
         |> Changeset.for_create(:create_internal, %{
           round_competition_id: competition.id,
           competition_side_id: side.id,
           round_entry_id: entry_id,
           round_id: round.id
         })
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        if unique_violation?(error) do
          {:error, :entry_already_in_competition}
        else
          {:error, :membership_create_failed}
        end
    end
  end

  defp unique_violation?(%Ash.Error.Unknown{errors: errors}) do
    Enum.any?(errors, fn
      %{caused_by: %Postgrex.Error{postgres: %{code: :unique_violation}}} -> true
      _ -> false
    end)
  end

  defp unique_violation?(%Postgrex.Error{postgres: %{code: :unique_violation}}), do: true
  defp unique_violation?(_), do: false

  defp load_side_memberships(competition_side_id) do
    memberships =
      CompetitionSideMembership
      |> Ash.Query.filter(competition_side_id == ^competition_side_id)
      |> Ash.read(authorize?: false)

    case memberships do
      {:ok, rows} -> {:ok, rows}
      {:error, error} -> {:error, error}
    end
  end

  defp write_audit_if_ready(actor_id, %{state: :ready, id: round_id}) do
    case Audit.record_staff_event(
           %{
             actor_staff_user_id: actor_id,
             action: "set_side_membership",
             target_type: "Round",
             target_id: round_id,
             context: %{round_id: round_id},
             changes: %{operation: "set_side_membership"}
           },
           authorize?: false
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_audit_if_ready(_actor_id, _round), do: :ok

  defp normalize_result({:ok, result}), do: {:ok, result}
  defp normalize_result({:error, reason}), do: {:error, reason}
  defp normalize_result({:error, :rollback, reason}), do: {:error, reason}
end
