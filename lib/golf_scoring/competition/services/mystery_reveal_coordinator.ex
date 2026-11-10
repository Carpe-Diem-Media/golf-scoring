defmodule GolfScoring.Competition.Services.MysteryRevealCoordinator do
  @moduledoc "Transaction-scoped global Mystery resolution and reveal coordinator."

  alias Ash.Changeset
  alias GolfScoring.Competition.MysteryReveal
  alias GolfScoring.Competition.Policies.MysteryRevealEligibility
  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @creation_key {__MODULE__, :creation}

  @scheduled_holes 18

  @doc "Proof-free rechecks are not authorized, even inside a transaction."
  def recheck(_round_id, _round_hole_id), do: {:error, :unauthorized_mystery_recheck}

  @doc false
  def recheck_many(_round_id, _competition_id, _holes),
    do: {:error, :unauthorized_mystery_recheck}

  @doc false
  def recheck(round_id, round_hole_id, proof) do
    scope = %{round_id: round_id, competition_id: nil, holes: [round_hole_id]}

    with :ok <- consume_origin(proof, scope),
         {:ok, specs} <- rule_specs_for_holes(round_id, scope.holes),
         do: recheck_specs(specs, round_id)
  end

  @doc false
  def recheck_many(round_id, competition_id, holes, proof) when is_list(holes) do
    scope = %{round_id: round_id, competition_id: competition_id, holes: canonical_holes(holes)}

    with :ok <- consume_origin(proof, scope),
         {:ok, specs} <- rule_specs_for_competition(round_id, competition_id, scope.holes),
         do: recheck_specs(specs, round_id)
  end

  def recheck_many(_, _, _, _), do: {:error, :unauthorized_mystery_recheck}

  defp consume_origin(%{owner: owner} = proof, scope)
       when owner in [SubmitGroupHole, ExcludeCompetitionSideBeforeHole] do
    owner.consume_mystery_recheck(proof, scope)
  end

  defp consume_origin(_, _), do: {:error, :unauthorized_mystery_recheck}

  defp canonical_holes(holes) do
    holes |> Enum.uniq() |> Enum.sort_by(&Ecto.UUID.dump!/1)
  rescue
    ArgumentError -> :invalid
  end

  defp rule_specs_for_holes(round_id, round_hole_ids) do
    specs =
      Repo.query!(
        """
        SELECT id::text, round_hole_id::text
        FROM mystery_hole_rules
        WHERE round_id = $1::uuid
          AND round_hole_id = ANY($2::uuid[])
        ORDER BY id
        """,
        [Ecto.UUID.dump!(round_id), Enum.map(Enum.uniq(round_hole_ids), &Ecto.UUID.dump!/1)]
      ).rows
      |> Enum.map(fn [id, hole_id] ->
        %{id: Ecto.UUID.cast!(id), round_hole_id: Ecto.UUID.cast!(hole_id)}
      end)

    {:ok, specs}
  end

  defp rule_specs_for_competition(_round_id, _round_competition_id, []), do: {:ok, []}

  defp rule_specs_for_competition(round_id, round_competition_id, round_hole_ids) do
    specs =
      Repo.query!(
        """
        SELECT mhr.id::text, mhr.round_hole_id::text
        FROM mystery_hole_rules mhr
        JOIN scoring_tracks st ON st.id = mhr.scoring_track_id
        WHERE mhr.round_id = $1::uuid
          AND st.round_competition_id = $2::uuid
          AND mhr.round_hole_id = ANY($3::uuid[])
        ORDER BY mhr.id
        """,
        [
          Ecto.UUID.dump!(round_id),
          Ecto.UUID.dump!(round_competition_id),
          Enum.map(Enum.uniq(round_hole_ids), &Ecto.UUID.dump!/1)
        ]
      ).rows
      |> Enum.map(fn [id, hole_id] ->
        %{id: Ecto.UUID.cast!(id), round_hole_id: Ecto.UUID.cast!(hole_id)}
      end)

    {:ok, specs}
  end

  defp recheck_specs([], _round_id), do: {:ok, %{created?: false}}

  defp recheck_specs(specs, round_id) do
    specs_by_id = Map.new(specs, &{&1.id, &1.round_hole_id})
    rule_ids = Map.keys(specs_by_id)

    with {:ok, %{acquired: locked_rules}} <-
           LockProtocol.acquire!(mystery_hole_rule: rule_ids) do
      recheck_locked_rules(locked_rules, specs_by_id, round_id, false)
    end
  end

  defp recheck_locked_rules([], _specs_by_id, _round_id, any_created?),
    do: {:ok, %{created?: any_created?}}

  defp recheck_locked_rules([locked_rule | remaining], specs_by_id, round_id, any_created?) do
    round_hole_id = Map.fetch!(specs_by_id, locked_rule.id)

    with {:ok, created?} <- recheck_rule(locked_rule.id, round_id, round_hole_id) do
      recheck_locked_rules(
        remaining,
        specs_by_id,
        round_id,
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
         {:ok, cohort} <- required_cohort(round_competition_id, round_id),
         {:ok, facts} <- resolution_facts(cohort, round_competition_id, round_id, round_hole_id),
         {:ok, eligibility} <-
           MysteryRevealEligibility.evaluate(cohort.group_ids, facts) do
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

  defp required_cohort(round_competition_id, round_id) do
    rows =
      Repo.query!(
        """
        SELECT cs.id::text, csm.round_id::text, csm.round_competition_id::text,
               csm.round_entry_id::text, re.id::text, re.round_id::text,
               re.playing_group_id::text, pg.round_id::text
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

      Enum.any?(rows, &ambiguous_membership_row?(&1, round_competition_id, round_id)) ->
        {:error, :ambiguous_mystery_reveal_cohort}

      side_spans_groups?(rows) ->
        {:error, :ambiguous_mystery_reveal_cohort}

      true ->
        side_ids_by_group = cohort_side_ids_by_group(rows)
        group_ids = Enum.sort_by(Map.keys(side_ids_by_group), &Ecto.UUID.dump!/1)

        if group_ids == [] or Enum.any?(Map.values(side_ids_by_group), &(&1 == [])) do
          {:error, :empty_mystery_reveal_cohort}
        else
          {:ok, %{group_ids: group_ids, side_ids_by_group: side_ids_by_group}}
        end
    end
  end

  defp cohort_side_ids_by_group(rows) do
    rows
    |> Enum.group_by(&cohort_group_id/1)
    |> Map.new(fn {group_id, group_rows} ->
      side_ids =
        group_rows
        |> Enum.map(&cohort_side_id/1)
        |> Enum.uniq()
        |> Enum.sort_by(&Ecto.UUID.dump!/1)

      {group_id, side_ids}
    end)
  end

  defp cohort_group_id(row), do: row |> Enum.at(6) |> Ecto.UUID.cast!()
  defp cohort_side_id([side_id | _rest]), do: Ecto.UUID.cast!(side_id)

  defp ambiguous_membership_row?(
         [
           side_id,
           membership_round_id,
           membership_competition_id,
           entry_id,
           re_id,
           entry_round_id,
           group_id,
           group_round_id
         ],
         expected_competition_id,
         expected_round_id
       ) do
    is_nil(side_id) or is_nil(entry_id) or is_nil(re_id) or is_nil(group_id) or
      is_nil(group_round_id) or
      Ecto.UUID.cast!(membership_round_id) != expected_round_id or
      Ecto.UUID.cast!(membership_competition_id) != expected_competition_id or
      Ecto.UUID.cast!(entry_round_id) != expected_round_id or
      Ecto.UUID.cast!(group_round_id) != expected_round_id
  end

  defp side_spans_groups?(rows) do
    rows
    |> Enum.group_by(fn row -> row |> hd() |> Ecto.UUID.cast!() end)
    |> Enum.any?(fn {_side_id, side_rows} ->
      side_rows
      |> Enum.map(fn row -> row |> Enum.at(6) |> Ecto.UUID.cast!() end)
      |> Enum.uniq()
      |> length()
      |> Kernel.>(1)
    end)
  end

  defp resolution_facts(cohort, round_competition_id, round_id, round_hole_id) do
    Enum.reduce_while(cohort.group_ids, {:ok, []}, fn group_id, {:ok, acc} ->
      side_ids = Map.fetch!(cohort.side_ids_by_group, group_id)

      case resolution_for_group(
             group_id,
             side_ids,
             round_competition_id,
             round_id,
             round_hole_id
           ) do
        {:ok, resolution} ->
          fact = %{playing_group_id: group_id, resolution: resolution}
          {:cont, {:ok, [fact | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, facts} -> {:ok, Enum.reverse(facts)}
      error -> error
    end
  end

  defp resolution_for_group(group_id, side_ids, round_competition_id, round_id, round_hole_id) do
    case accepted_submission_source(round_id, group_id, round_hole_id) do
      "paper_recovery" ->
        {:ok, :paper_recovered}

      source when is_binary(source) ->
        {:ok, :submitted}

      nil ->
        resolve_without_submission(
          group_id,
          side_ids,
          round_competition_id,
          round_id,
          round_hole_id
        )
    end
  end

  defp accepted_submission_source(round_id, group_id, round_hole_id) do
    case Repo.query!(
           """
           SELECT source
           FROM hole_submissions
           WHERE round_id = $1::uuid
             AND playing_group_id = $2::uuid
             AND round_hole_id = $3::uuid
           ORDER BY inserted_at, id
           LIMIT 1
           """,
           [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(round_hole_id)]
         ).rows do
      [[source]] -> source
      [] -> nil
    end
  end

  defp resolve_without_submission(
         group_id,
         side_ids,
         round_competition_id,
         round_id,
         round_hole_id
       ) do
    with {:ok, route} <- group_hole_position(group_id, round_id, round_hole_id),
         {:ok, rows} <- side_exclusion_rows(side_ids) do
      side_rows = Enum.zip(side_ids, rows)

      all_excluded_before_target? =
        length(rows) == length(side_ids) and side_ids != [] and
          Enum.all?(side_rows, fn {side_id, row} ->
            row.side_id == side_id and
              valid_exclusion_row?(
                row,
                round_id,
                round_competition_id,
                group_id,
                route.start_play_order
              ) and row.effective_play_index <= route.target_play_index
          end)

      if all_excluded_before_target?,
        do: {:ok, :not_applicable},
        else: {:ok, :unresolved}
    end
  end

  defp group_hole_position(group_id, round_id, round_hole_id) do
    case Repo.query!(
           """
           SELECT target.play_order::int, start.play_order::int,
                  (SELECT count(*)::int FROM round_holes WHERE round_id = $1::uuid),
                  (SELECT min(play_order)::int FROM round_holes WHERE round_id = $1::uuid),
                  (SELECT max(play_order)::int FROM round_holes WHERE round_id = $1::uuid)
           FROM playing_groups pg
           JOIN round_holes start ON start.id = pg.starting_round_hole_id
           JOIN round_holes target ON target.id = $3::uuid
           WHERE pg.id = $2::uuid
             AND pg.round_id = $1::uuid
             AND start.round_id = $1::uuid
             AND target.round_id = $1::uuid
           """,
           [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(round_hole_id)]
         ).rows do
      [[target_order, start_order, 18, 1, 18]] ->
        {:ok,
         %{
           target_play_index: Integer.mod(target_order - start_order, @scheduled_holes),
           start_play_order: start_order
         }}

      [] ->
        {:error, :ambiguous_mystery_reveal_route}

      _ ->
        {:error, :ambiguous_mystery_reveal_route}
    end
  end

  defp side_exclusion_rows(side_ids) do
    rows =
      Repo.query!(
        """
        SELECT required.side_id::text, cs.round_id::text, cs.round_competition_id::text,
               csr.state, csr.excluded_playing_group_id::text,
               csr.excluded_effective_round_hole_id::text,
               csr.excluded_effective_play_index,
               csr.excluded_preplay_confirmed,
               effective.round_id::text, effective.play_order::int
        FROM unnest($1::uuid[]) AS required(side_id)
        LEFT JOIN competition_sides cs ON cs.id = required.side_id
        LEFT JOIN competition_side_results csr ON csr.competition_side_id = cs.id
        LEFT JOIN round_holes effective
          ON effective.id = csr.excluded_effective_round_hole_id
        ORDER BY required.side_id
        """,
        [Enum.map(side_ids, &Ecto.UUID.dump!/1)]
      ).rows
      |> Enum.map(fn [
                       side_id,
                       side_round_id,
                       side_competition_id,
                       state,
                       excluded_group_id,
                       effective_hole_id,
                       effective_play_index,
                       preplay_confirmed,
                       effective_round_id,
                       effective_play_order
                     ] ->
        %{
          side_id: cast_optional_uuid(side_id),
          side_round_id: cast_optional_uuid(side_round_id),
          side_competition_id: cast_optional_uuid(side_competition_id),
          state: state,
          excluded_group_id: cast_optional_uuid(excluded_group_id),
          effective_hole_id: cast_optional_uuid(effective_hole_id),
          effective_play_index: effective_play_index,
          preplay_confirmed?: preplay_confirmed,
          effective_round_id: cast_optional_uuid(effective_round_id),
          effective_play_order: effective_play_order
        }
      end)

    if length(rows) == length(side_ids),
      do: {:ok, rows},
      else: {:error, :ambiguous_mystery_reveal_cohort}
  end

  defp valid_exclusion_row?(row, round_id, round_competition_id, group_id, start_play_order) do
    valid_excluded_side?(row, round_id, round_competition_id, group_id) and
      valid_effective_hole?(row, round_id) and
      valid_effective_play_index?(row, start_play_order)
  end

  defp valid_excluded_side?(row, round_id, round_competition_id, group_id) do
    row.state == "excluded" and row.side_round_id == round_id and
      row.side_competition_id == round_competition_id and row.excluded_group_id == group_id and
      row.preplay_confirmed? == true
  end

  defp valid_effective_hole?(row, round_id) do
    not is_nil(row.effective_hole_id) and row.effective_round_id == round_id
  end

  defp valid_effective_play_index?(row, start_play_order) do
    is_integer(row.effective_play_index) and row.effective_play_index in 0..17 and
      is_integer(row.effective_play_order) and
      Integer.mod(row.effective_play_order - start_play_order, @scheduled_holes) ==
        row.effective_play_index
  end

  defp cast_optional_uuid(nil), do: nil
  defp cast_optional_uuid(value), do: Ecto.UUID.cast!(value)

  # This private call is reachable only after the locked current A2 evaluation.
  defp create_reveal(rule_id) do
    proof = %{token: make_ref(), pid: self(), transaction_id: transaction_id(), rule_id: rule_id}
    if Process.get(@creation_key), do: Repo.rollback(:nested_mystery_creation)
    Process.put(@creation_key, proof)

    try do
      case MysteryReveal
           |> Changeset.for_create(:create_internal, %{mystery_hole_rule_id: rule_id})
           |> Changeset.set_context(%{mystery_reveal_creation: proof.token})
           |> Ash.create(authorize?: false) do
        {:ok, _reveal} -> {:ok, true}
        {:error, error} -> {:error, error}
      end
    after
      Process.delete(@creation_key)
    end
  end

  @doc false
  def consume_creation(token, rule_id) do
    case Process.get(@creation_key) do
      %{token: ^token, pid: pid, transaction_id: transaction, rule_id: ^rule_id}
      when pid == self() ->
        if Repo.in_transaction?() and transaction == transaction_id() do
          Process.delete(@creation_key)
          :ok
        else
          {:error, :unauthorized_mystery_creation}
        end

      _ ->
        {:error, :unauthorized_mystery_creation}
    end
  end

  defp transaction_id, do: Repo.query!("SELECT pg_current_xact_id()::text").rows |> hd() |> hd()
end
