defmodule GolfScoring.Competition.Services.MysteryRevealCoordinator do
  @moduledoc "Transaction-scoped global Mystery reveal eligibility recheck."

  alias Ash.Changeset
  alias GolfScoring.Competition.MysteryReveal
  alias GolfScoring.Competition.Policies.MysteryRevealEligibility
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @spec recheck(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, %{created?: boolean()}} | {:error, term()}
  def recheck(round_id, round_hole_id) do
    with :ok <- require_transaction(),
         {:ok, rule_ids} <- rule_ids_for_hole(round_id, round_hole_id) do
      recheck_rules(rule_ids, round_id, round_hole_id)
    end
  end

  defp require_transaction do
    if Repo.in_transaction?(), do: :ok, else: {:error, :transaction_required}
  end

  defp rule_ids_for_hole(round_id, round_hole_id) do
    ids =
      Repo.query!(
        """
        SELECT id::text
        FROM mystery_hole_rules
        WHERE round_id = $1::uuid AND round_hole_id = $2::uuid
        ORDER BY id
        """,
        [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(round_hole_id)]
      ).rows
      |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

    {:ok, ids}
  end

  defp recheck_rules([], _round_id, _round_hole_id),
    do: {:ok, %{created?: false}}

  defp recheck_rules(rule_ids, round_id, round_hole_id) do
    with {:ok, %{acquired: locked_rules}} <-
           LockProtocol.acquire!(mystery_hole_rule: rule_ids) do
      recheck_locked_rules(locked_rules, round_id, round_hole_id, false)
    end
  end

  defp recheck_locked_rules([], _round_id, _round_hole_id, any_created?),
    do: {:ok, %{created?: any_created?}}

  defp recheck_locked_rules(
         [locked_rule | remaining],
         round_id,
         round_hole_id,
         any_created?
       ) do
    with {:ok, created?} <- recheck_rule(locked_rule.id, round_id, round_hole_id) do
      recheck_locked_rules(
        remaining,
        round_id,
        round_hole_id,
        any_created? or created?
      )
    end
  end

  defp recheck_rule(rule_id, round_id, round_hole_id) do
    if reveal_exists?(rule_id) do
      {:ok, false}
    else
      recheck_unrevealed_rule(rule_id, round_id, round_hole_id)
    end
  end

  defp recheck_unrevealed_rule(rule_id, round_id, round_hole_id) do
    with {:ok, round_competition_id} <-
           rule_round_competition(rule_id, round_id, round_hole_id),
         {:ok, required_group_ids} <- required_group_ids(round_competition_id, round_id),
         {:ok, facts} <- resolution_facts_for_groups(required_group_ids, round_id, round_hole_id),
         {:ok, eligibility} <-
           MysteryRevealEligibility.evaluate(required_group_ids, facts) do
      create_reveal_if_eligible(rule_id, eligibility.eligible?)
    end
  end

  defp create_reveal_if_eligible(rule_id, true), do: create_reveal(rule_id)
  defp create_reveal_if_eligible(_rule_id, false), do: {:ok, false}

  defp rule_round_competition(rule_id, expected_round_id, expected_hole_id) do
    case Repo.query!(
           """
           SELECT mhr.round_id::text, mhr.round_hole_id::text,
                  st.round_id::text, rc.id::text, rc.round_id::text
           FROM mystery_hole_rules mhr
           JOIN scoring_tracks st ON st.id = mhr.scoring_track_id
           JOIN round_competitions rc ON rc.id = st.round_competition_id
           WHERE mhr.id = $1::uuid
           """,
           [Ecto.UUID.dump!(rule_id)]
         ).rows do
      [[rule_round_id, rule_hole_id, track_round_id, competition_id, competition_round_id]] ->
        same_scope? =
          Ecto.UUID.cast!(rule_round_id) == expected_round_id and
            Ecto.UUID.cast!(rule_hole_id) == expected_hole_id and
            Ecto.UUID.cast!(track_round_id) == expected_round_id and
            Ecto.UUID.cast!(competition_round_id) == expected_round_id

        if same_scope?,
          do: {:ok, Ecto.UUID.cast!(competition_id)},
          else: {:error, :ambiguous_mystery_reveal_scope}

      [] ->
        {:error, :mystery_hole_rule_not_found}

      _rows ->
        {:error, :ambiguous_mystery_reveal_scope}
    end
  end

  defp reveal_exists?(rule_id) do
    case Repo.query!(
           "SELECT 1 FROM mystery_reveals WHERE mystery_hole_rule_id = $1::uuid",
           [Ecto.UUID.dump!(rule_id)]
         ).rows do
      [] -> false
      [[1]] -> true
    end
  end

  defp required_group_ids(round_competition_id, round_id) do
    rows =
      Repo.query!(
        """
        SELECT cs.id::text, csm.round_id::text, csm.round_entry_id::text,
               re.id::text, re.round_id::text, re.playing_group_id::text,
               pg.round_id::text
        FROM competition_sides cs
        JOIN competition_side_memberships csm
          ON csm.competition_side_id = cs.id
         AND csm.round_competition_id = cs.round_competition_id
         AND csm.round_id = cs.round_id
        LEFT JOIN round_entries re ON re.id = csm.round_entry_id
        LEFT JOIN playing_groups pg ON pg.id = re.playing_group_id
        WHERE cs.round_competition_id = $1::uuid
          AND cs.round_id = $2::uuid
        ORDER BY cs.id, csm.round_entry_id
        """,
        [Ecto.UUID.dump!(round_competition_id), Ecto.UUID.dump!(round_id)]
      ).rows

    cond do
      rows == [] ->
        {:error, :empty_mystery_reveal_cohort}

      Enum.any?(rows, &ambiguous_membership_row?(&1, round_id)) ->
        {:error, :ambiguous_mystery_reveal_cohort}

      true ->
        group_ids =
          rows
          |> Enum.map(fn [
                           _side_id,
                           _membership_round,
                           _entry_id,
                           _re_id,
                           _entry_round,
                           group_id,
                           _group_round
                         ] ->
            Ecto.UUID.cast!(group_id)
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&Ecto.UUID.dump!/1)

        if group_ids == [],
          do: {:error, :empty_mystery_reveal_cohort},
          else: {:ok, group_ids}
    end
  end

  defp ambiguous_membership_row?(
         [
           _side_id,
           membership_round_id,
           entry_id,
           re_id,
           entry_round_id,
           group_id,
           group_round_id
         ],
         expected_round_id
       ) do
    is_nil(entry_id) or is_nil(re_id) or is_nil(group_id) or is_nil(group_round_id) or
      Ecto.UUID.cast!(membership_round_id) != expected_round_id or
      Ecto.UUID.cast!(entry_round_id) != expected_round_id or
      Ecto.UUID.cast!(group_round_id) != expected_round_id
  end

  defp resolution_facts_for_groups(group_ids, round_id, round_hole_id) do
    facts =
      Repo.query!(
        """
        SELECT required.playing_group_id::text,
               CASE WHEN EXISTS (
                 SELECT 1
                 FROM hole_submissions hs
                 WHERE hs.round_id = $1::uuid
                   AND hs.playing_group_id = required.playing_group_id
                   AND hs.round_hole_id = $3::uuid
               ) THEN 'submitted' ELSE 'unresolved' END
        FROM unnest($2::uuid[]) AS required(playing_group_id)
        ORDER BY required.playing_group_id
        """,
        [
          Ecto.UUID.dump!(round_id),
          Enum.map(group_ids, &Ecto.UUID.dump!/1),
          Ecto.UUID.dump!(round_hole_id)
        ]
      ).rows
      |> Enum.map(fn [group_id, resolution] ->
        %{playing_group_id: Ecto.UUID.cast!(group_id), resolution: resolution_atom(resolution)}
      end)

    {:ok, facts}
  end

  defp resolution_atom("submitted"), do: :submitted
  defp resolution_atom(_), do: :unresolved

  defp create_reveal(rule_id) do
    case MysteryReveal
         |> Changeset.for_create(:create_internal, %{mystery_hole_rule_id: rule_id})
         |> Ash.create(authorize?: false) do
      {:ok, _reveal} -> {:ok, true}
      {:error, error} -> {:error, error}
    end
  end
end
