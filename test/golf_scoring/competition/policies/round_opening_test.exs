defmodule GolfScoring.Competition.Policies.RoundOpeningTest do
  use ExUnit.Case, async: true

  alias GolfScoring.Competition.Policies.RoundOpening

  defp facts do
    %{
      round: %{id: "round", event_id: "event", course_id: "course"},
      event_id: "event",
      holes: [],
      entries: [],
      groups: [],
      roles: [],
      competitions: [],
      sides: [],
      memberships: [],
      tracks: [],
      rules: [],
      tees: [],
      tee_holes: [],
      handicaps: [],
      competition_handicaps: []
    }
  end

  test "empty facts produce deterministic blockers rather than an openable round" do
    result = RoundOpening.evaluate(%{facts() | round: nil})
    assert result.blockers != []
    assert result == RoundOpening.evaluate(%{facts() | round: nil})
    assert is_list(result.warnings)
  end

  test "an incomplete route and missing entrants are reported together" do
    result = RoundOpening.evaluate(facts())
    assert :invalid_route in result.blockers
    assert :no_starters in result.blockers
  end
end

defmodule GolfScoring.Competition.Policies.RoundOpeningCompleteTest do
  use ExUnit.Case, async: true
  alias GolfScoring.Competition.Policies.RoundOpening

  defp valid do
    holes = for n <- 1..18, do: %{id: "h#{n}", round_id: "r", course_id: "c", play_order: n}

    entries =
      for n <- 1..2,
          do: %{
            id: "e#{n}",
            round_id: "r",
            event_id: "v",
            player_id: "p#{n}",
            playing_group_id: "g",
            round_tee_profile_snapshot_id: "t",
            registration_status: :expected,
            participation_status: :not_started
          }

    handicaps =
      for n <- 1..2,
          do: %{
            id: "hs#{n}",
            round_id: "r",
            round_entry_id: "e#{n}",
            round_tee_profile_snapshot_id: "t",
            basis_source: :official_or_preloaded,
            confirmed_at: ~U[2026-01-01 00:00:00Z],
            built_at: ~U[2026-01-01 00:00:00Z],
            course_handicap_rounded: 10,
            course_handicap_unrounded: 10
          }

    chs =
      for n <- 1..2,
          do: %{
            id: "ch#{n}",
            round_id: "r",
            round_entry_id: "e#{n}",
            round_competition_id: "c1",
            handicap_snapshot_id: "hs#{n}",
            handicap_allowance_percent: 100,
            playing_handicap: 10,
            policy_identifier: "whs_golfrsa_2026_v1"
          }

    competition = %{
      id: "c1",
      round_id: "r",
      event_id: "v",
      is_primary: true,
      scoring_policy_identifier: "four_ball_stableford_v1",
      handicap_allowance_percent: 100,
      solo_sides_permitted: false,
      solo_normalization_policy_identifier: "companion_max_p_minus_one_v1",
      pickup_policy_identifier: "standard_pickup_v1"
    }

    standard = %{
      id: "s",
      round_id: "r",
      event_id: "v",
      round_competition_id: "c1",
      track_type: :standard_better_ball,
      name: "Standard Better-Ball",
      is_primary: false,
      visibility_policy_identifier: "leaderboard_v1",
      aggregation_policy_identifier: "standard_better_ball_v1",
      tie_break_policy_identifier: "standard_countback_v1",
      configuration_state: :draft
    }

    mystery = %{
      id: "m",
      round_id: "r",
      event_id: "v",
      round_competition_id: "c1",
      track_type: :mystery,
      name: "Mystery Leaderboard",
      is_primary: true,
      visibility_policy_identifier: "staff_only_v1",
      aggregation_policy_identifier: "mystery_v1",
      tie_break_policy_identifier: "mystery_holes_then_countback_v1",
      configuration_state: :draft
    }

    %{
      round: %{id: "r", event_id: "v", course_id: "c"},
      event_id: "v",
      holes: holes,
      entries: entries,
      players: [%{id: "p1"}, %{id: "p2"}],
      groups: [%{id: "g", round_id: "r", starting_round_hole_id: "h1", starting_position: 1}],
      roles: [
        %{
          id: "a",
          round_id: "r",
          playing_group_id: "g",
          round_entry_id: "e1",
          role: :primary_scorer,
          state: :active
        },
        %{
          id: "b",
          round_id: "r",
          playing_group_id: "g",
          round_entry_id: "e2",
          role: :designated_verifier,
          state: :active
        }
      ],
      competitions: [competition],
      sides: [%{id: "side", round_id: "r", round_competition_id: "c1", formation: :partnership}],
      memberships:
        for(
          n <- 1..2,
          do: %{
            id: "mem#{n}",
            round_id: "r",
            round_competition_id: "c1",
            competition_side_id: "side",
            round_entry_id: "e#{n}"
          }
        ),
      tracks: [standard, mystery],
      rules: [
        %{id: "rule", round_id: "r", scoring_track_id: "m", round_hole_id: "h1", rule: :best}
      ],
      tees: [%{id: "t", round_id: "r"}],
      tee_holes:
        for(
          h <- holes,
          do: %{
            id: "th#{h.id}",
            round_id: "r",
            round_hole_id: h.id,
            round_tee_profile_snapshot_id: "t"
          }
        ),
      handicaps: handicaps,
      competition_handicaps: chs
    }
  end

  test "complete facts have no blockers" do
    assert %{blockers: []} = RoundOpening.evaluate(valid())
  end

  for {field, blocker} <- [
        players: :entry,
        tees: :tee,
        tee_holes: :tee_holes,
        handicaps: :handicap,
        competition_handicaps: :competition_handicap,
        groups: :group,
        roles: :role,
        competitions: :competition,
        sides: :side,
        memberships: :side,
        tracks: :track,
        rules: :mystery_rule
      ] do
    test "missing #{field} blocks opening" do
      result = RoundOpening.evaluate(Map.put(valid(), unquote(field), []))
      assert Enum.any?(result.blockers, fn blocker -> elem(blocker, 0) == unquote(blocker) end)
    end
  end

  test "all blocker families are returned in stable order" do
    facts = %{
      valid()
      | players: [],
        tees: [],
        tee_holes: [],
        handicaps: [],
        competition_handicaps: [],
        groups: [],
        roles: [],
        competitions: [],
        sides: [],
        memberships: [],
        tracks: [],
        rules: []
    }

    result = RoundOpening.evaluate(facts)
    assert length(result.blockers) >= 10
    assert result == RoundOpening.evaluate(facts)
  end

  test "wrong policies and cross-scope facts produce blockers" do
    f = valid()
    [c] = f.competitions
    [s, m] = f.tracks
    [rule] = f.rules

    changed = %{
      f
      | competitions: [%{c | scoring_policy_identifier: "unsupported"}],
        tracks: [%{s | round_id: "other"}, m],
        rules: [%{rule | round_id: "other"}]
    }

    result = RoundOpening.evaluate(changed)
    assert {:competition, "c1", :invalid_policy_or_scope} in result.blockers
    assert {:track, :standard_better_ball, :invalid} in result.blockers
    assert {:mystery_rule, :invalid_or_missing} in result.blockers
  end

  test "duplicate player, invalid role holder, and orphan membership are rejected" do
    f = valid()
    [e1, e2] = f.entries
    [a, b] = f.roles
    [mem | _] = f.memberships

    changed = %{
      f
      | entries: [e1, %{e2 | player_id: e1.player_id}],
        roles: [a, %{b | round_entry_id: e1.id}],
        memberships: [%{mem | competition_side_id: "unknown"}]
    }

    result = RoundOpening.evaluate(changed)
    assert {:entry, :duplicate_player} in result.blockers
    assert {:role, "g", :holders_not_distinct} in result.blockers
    assert {:side, :orphan_membership} in result.blockers
  end

  test "optional contact warnings do not block" do
    f = valid()
    f = Map.put(f, :warnings, [{:contact, "p1", :missing}])
    assert %{blockers: [], warnings: [{:contact, "p1", :missing}]} = RoundOpening.evaluate(f)
  end

  test "stale handicap and tee associations block" do
    f = valid()
    [h1, h2] = f.handicaps
    [ch1, ch2] = f.competition_handicaps

    result =
      RoundOpening.evaluate(%{
        f
        | handicaps: [%{h1 | round_tee_profile_snapshot_id: "other"}, h2],
          competition_handicaps: [%{ch1 | handicap_allowance_percent: 75}, ch2]
      })

    assert {:handicap, "e1", :missing_or_stale} in result.blockers
    assert {:competition_handicap, "e1", :missing_or_stale} in result.blockers
  end

  test "a stray group and invalid start block" do
    f = valid()
    [g] = f.groups

    result =
      RoundOpening.evaluate(%{f | groups: [%{g | starting_position: 0}, %{g | id: "stray"}]})

    assert {:group, "g", :invalid_start} in result.blockers
    assert {:group, "stray", :invalid_population} in result.blockers
  end

  test "side cardinality follows the four-ball policy" do
    f = valid()
    [m | _] = f.memberships
    result = RoundOpening.evaluate(%{f | memberships: [m]})
    assert {:side, "side", :invalid_membership} in result.blockers
    assert {:side, "e2", :missing_or_duplicate_membership} in result.blockers
  end

  test "unsupported track and rule identifiers block" do
    f = valid()
    [s, m] = f.tracks
    [rule] = f.rules

    result =
      RoundOpening.evaluate(%{
        f
        | tracks: [s, %{m | visibility_policy_identifier: "public"}],
          rules: [%{rule | rule: :unknown}]
      })

    assert {:track, :mystery, :invalid} in result.blockers
    assert {:mystery_rule, :invalid_or_missing} in result.blockers
  end

  test "extra cross-scope tracks and roles fail closed" do
    f = valid()
    [s | _] = f.tracks
    [a | _] = f.roles

    result =
      RoundOpening.evaluate(%{
        f
        | tracks: [%{s | id: "extra", track_type: :unsupported} | f.tracks],
          roles: [%{a | id: "orphan", playing_group_id: "other"} | f.roles]
      })

    assert {:track, :unexpected} in result.blockers
    assert {:role, "orphan", :invalid_scope} in result.blockers
  end

  test "an unconfirmed handicap is not a current accepted input" do
    f = valid()
    [h1, h2] = f.handicaps

    result =
      RoundOpening.evaluate(%{
        f
        | handicaps: [%{h1 | basis_source: :committee_deemed, confirmed_at: nil}, h2]
      })

    assert {:handicap, "e1", :missing_or_stale} in result.blockers
  end

  test "a handicap build missing its unrounded output is incomplete" do
    f = valid()
    [h1, h2] = f.handicaps
    result = RoundOpening.evaluate(%{f | handicaps: [%{h1 | course_handicap_unrounded: nil}, h2]})
    assert {:handicap, "e1", :missing_or_stale} in result.blockers
  end

  test "duplicate route identities block even with distinct play order" do
    f = valid()
    [first, second | rest] = f.holes
    result = RoundOpening.evaluate(%{f | holes: [first, %{second | id: first.id} | rest]})
    assert :invalid_route in result.blockers
  end
end
