defmodule GolfScoring.Competition.Policies.RoundOpening do
  @moduledoc "Pure validation of current Round opening facts."
  alias GolfScoring.Competition.{
    FourBallStablefordV1SidePolicy,
    PlayingGroupReadiness,
    StartingParticipant
  }

  def evaluate(%{round: nil}), do: %{blockers: [:round_missing], warnings: []}

  def evaluate(f) do
    starters = Enum.filter(f.entries, &StartingParticipant.current_starting_participant?/1)
    holes = MapSet.new(f.holes, & &1.id)
    primary = Enum.filter(f.competitions, & &1.is_primary)

    competition =
      case primary do
        [c] -> c
        _ -> nil
      end

    route =
      Enum.sort(Enum.map(f.holes, & &1.play_order)) == Enum.to_list(1..18) and
        not duplicate?(f.holes, :id) and
        Enum.all?(f.holes, &(&1.round_id == f.round.id and &1.course_id == f.round.course_id))

    blockers = []
    blockers = add(blockers, !route, :invalid_route)
    blockers = add(blockers, starters == [], :no_starters)
    blockers = add(blockers, f.round.event_id != f.event_id, {:round, :event_mismatch})
    blockers = add(blockers, duplicate?(starters, :player_id), {:entry, :duplicate_player})

    blockers =
      Enum.reduce(starters, blockers, fn e, acc -> entry_checks(acc, f, e, competition, holes) end)

    blockers =
      Enum.reduce(f.groups, blockers, fn g, acc -> group_checks(acc, f, g, starters, holes) end)

    blockers = add(blockers, f.groups == [], {:group, :missing})
    blockers = add(blockers, length(primary) != 1, {:competition, :missing_or_duplicate})

    blockers =
      if competition,
        do: competition_checks(blockers, f, competition, starters),
        else: add(blockers, true, {:side, :competition_missing})

    blockers =
      Enum.reduce(f.roles, blockers, fn r, a ->
        add(
          a,
          r.round_id != f.round.id or !Enum.any?(f.groups, &(&1.id == r.playing_group_id)),
          {:role, r.id, :invalid_scope}
        )
      end)

    blockers =
      add(
        blockers,
        Enum.any?(f.tracks, &(&1.track_type not in [:mystery, :standard_better_ball])),
        {:track, :unexpected}
      )

    blockers = track_checks(blockers, f, competition, holes)
    %{blockers: Enum.sort(blockers), warnings: Enum.sort(Map.get(f, :warnings, []))}
  end

  defp entry_checks(acc, f, e, competition, holes) do
    player_ok = Enum.count(f.players, &(&1.id == e.player_id)) == 1

    group_ok =
      Enum.count(f.groups, &(&1.id == e.playing_group_id and &1.round_id == f.round.id)) == 1

    acc =
      add(
        acc,
        !player_ok or e.round_id != f.round.id or e.event_id != f.round.event_id,
        {:entry, e.id, :invalid_player_or_scope}
      )

    acc = add(acc, !group_ok, {:group, e.id, :missing_or_wrong_scope})

    tees =
      Enum.filter(
        f.tees,
        &(&1.id == e.round_tee_profile_snapshot_id and &1.round_id == f.round.id)
      )

    acc = add(acc, length(tees) != 1, {:tee, e.id, :missing_or_wrong_scope})

    tee_holes =
      Enum.filter(
        f.tee_holes,
        &(&1.round_tee_profile_snapshot_id == e.round_tee_profile_snapshot_id)
      )

    coverage =
      length(tee_holes) == 18 and MapSet.new(tee_holes, & &1.round_hole_id) == holes and
        Enum.all?(tee_holes, &(&1.round_id == f.round.id))

    acc = add(acc, !coverage, {:tee_holes, e.id, :incomplete})
    handicap_checks(acc, f, e, competition)
  end

  defp handicap_checks(acc, f, e, competition) do
    hs = Enum.filter(f.handicaps, &(&1.round_entry_id == e.id))

    handicap =
      case hs do
        [h] -> h
        _ -> nil
      end

    acc = add(acc, !valid_handicap?(handicap, f, e), {:handicap, e.id, :missing_or_stale})

    chs =
      Enum.filter(
        f.competition_handicaps,
        &(&1.round_entry_id == e.id and competition != nil and
            &1.round_competition_id == competition.id)
      )

    add(
      acc,
      !valid_competition_handicap?(chs, handicap, competition, f),
      {:competition_handicap, e.id, :missing_or_stale}
    )
  end

  defp valid_handicap?(nil, _f, _e), do: false

  defp valid_handicap?(h, f, e) do
    h.round_id == f.round.id and
      h.round_tee_profile_snapshot_id == e.round_tee_profile_snapshot_id and
      h.built_at != nil and h.course_handicap_rounded != nil and
      h.course_handicap_unrounded != nil and h.confirmed_at != nil and
      h.basis_source in [
        :official_or_preloaded,
        :player_declared,
        :committee_deemed,
        :committee_override
      ]
  end

  defp valid_competition_handicap?([ch], handicap, competition, f) when not is_nil(handicap) do
    ch.round_id == f.round.id and ch.handicap_snapshot_id == handicap.id and
      ch.playing_handicap != nil and
      ch.handicap_allowance_percent == competition.handicap_allowance_percent and
      ch.policy_identifier == "whs_golfrsa_2026_v1"
  end

  defp valid_competition_handicap?(_, _, _, _), do: false

  defp group_checks(acc, f, g, starters, holes) do
    members = Enum.filter(starters, &(&1.playing_group_id == g.id))

    acc =
      add(
        acc,
        g.round_id != f.round.id or
          !PlayingGroupReadiness.starting_participant_count_valid?(length(members)),
        {:group, g.id, :invalid_population}
      )

    acc =
      add(
        acc,
        !MapSet.member?(holes, g.starting_round_hole_id) or !is_integer(g.starting_position) or
          g.starting_position <= 0,
        {:group, g.id, :invalid_start}
      )

    active = Enum.filter(f.roles, &(&1.playing_group_id == g.id and &1.state == :active))
    ids = MapSet.new(members, & &1.id)

    acc =
      Enum.reduce([:primary_scorer, :designated_verifier], acc, fn role, a ->
        found = Enum.filter(active, &(&1.role == role))

        valid =
          case found do
            [r] -> r.round_id == f.round.id and MapSet.member?(ids, r.round_entry_id)
            _ -> false
          end

        add(a, !valid, {:role, g.id, role})
      end)

    add(acc, duplicate?(active, :round_entry_id), {:role, g.id, :holders_not_distinct})
  end

  defp valid_competition?(c, round) do
    c.round_id == round.id and c.event_id == round.event_id and
      c.scoring_policy_identifier == "four_ball_stableford_v1" and
      is_integer(c.handicap_allowance_percent) and c.handicap_allowance_percent in 0..100 and
      is_boolean(c.solo_sides_permitted) and
      c.solo_normalization_policy_identifier == "companion_max_p_minus_one_v1" and
      c.pickup_policy_identifier == "standard_pickup_v1"
  end

  defp competition_checks(acc, f, c, starters) do
    acc =
      add(acc, !valid_competition?(c, f.round), {:competition, c.id, :invalid_policy_or_scope})

    sides = Enum.filter(f.sides, &(&1.round_competition_id == c.id))
    memberships = Enum.filter(f.memberships, &(&1.round_competition_id == c.id))

    acc =
      Enum.reduce(starters, acc, fn e, a ->
        matching = Enum.filter(memberships, &(&1.round_entry_id == e.id))
        add(a, length(matching) != 1, {:side, e.id, :missing_or_duplicate_membership})
      end)

    acc = Enum.reduce(sides, acc, fn s, a -> side_checks(a, f, c, s, memberships, starters) end)

    add(
      acc,
      Enum.any?(memberships, fn m -> !Enum.any?(sides, &(&1.id == m.competition_side_id)) end),
      {:side, :orphan_membership}
    )
  end

  defp side_checks(acc, f, c, side, memberships, starters) do
    ms = Enum.filter(memberships, &(&1.competition_side_id == side.id))
    entries = Enum.flat_map(ms, fn m -> Enum.filter(starters, &(&1.id == m.round_entry_id)) end)

    valid =
      side.round_id == f.round.id and Enum.all?(ms, &(&1.round_id == f.round.id)) and
        length(entries) == length(ms) and
        FourBallStablefordV1SidePolicy.validate_membership(c, side.formation, entries) == :ok

    add(acc, !valid, {:side, side.id, :invalid_membership})
  end

  defp track_checks(acc, f, competition, holes) do
    specs = [
      standard_better_ball:
        {"Standard Better-Ball", false, "leaderboard_v1", "standard_better_ball_v1",
         "standard_countback_v1"},
      mystery:
        {"Mystery Leaderboard", true, "staff_only_v1", "mystery_v1",
         "mystery_holes_then_countback_v1"}
    ]

    acc =
      Enum.reduce(specs, acc, fn {type, spec}, a ->
        found = Enum.filter(f.tracks, &(&1.track_type == type))
        add(a, !valid_track?(found, spec, f.round, competition), {:track, type, :invalid})
      end)

    mystery_rule_checks(acc, f, holes)
  end

  defp valid_track?([t], spec, round, competition) when not is_nil(competition) do
    {t.name, t.is_primary, t.visibility_policy_identifier, t.aggregation_policy_identifier,
     t.tie_break_policy_identifier} == spec and
      t.round_id == round.id and t.event_id == round.event_id and
      t.round_competition_id == competition.id
  end

  defp valid_track?(_, _, _, _), do: false

  defp mystery_rule_checks(acc, f, holes) do
    mystery = Enum.filter(f.tracks, &(&1.track_type == :mystery))

    mystery_id =
      case mystery do
        [m] -> m.id
        _ -> nil
      end

    valid_rules =
      f.rules != [] and
        Enum.all?(
          f.rules,
          &(&1.round_id == f.round.id and &1.scoring_track_id == mystery_id and
              MapSet.member?(holes, &1.round_hole_id) and &1.rule in [:best, :worst, :both])
        ) and !duplicate?(f.rules, :round_hole_id)

    add(acc, !valid_rules, {:mystery_rule, :invalid_or_missing})
  end

  defp add(acc, true, blocker), do: [blocker | acc]
  defp add(acc, false, _), do: acc

  defp duplicate?(values, key),
    do: length(values) != length(Enum.uniq_by(values, &Map.get(&1, key)))
end
