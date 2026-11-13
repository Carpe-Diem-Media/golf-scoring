defmodule GolfScoring.Scoring.Services.PaperRecoveryFixtures do
  @moduledoc false

  import ExUnit.Assertions

  alias Ash.Changeset
  alias Decimal, as: D
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap

  @password "GLS-34 synthetic staff passphrase 2026"

  def setup_shotgun_fixture!(start_play_order) do
    setup = setup_submit_fixture!(2)
    set_round_state!(setup.round, :draft)
    start_hole = Enum.find(setup.route, &(&1.play_order == start_play_order))

    assert {:ok, _} =
             assign_start_for_fixture(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               start_hole.id,
               start_play_order
             )

    set_round_state!(setup.round, :scoring_open)
    Map.put(setup, :start_hole, start_hole)
  end

  def setup_submit_fixture!(player_count) do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    holes = create_eighteen_holes!(event, admin, course)
    white = create_tee_set!(event, admin, course, "White")
    profile = create_profile!(event, admin, white, holes, "Men", par: 4, slope: 113)

    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, route} = ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))
    {:ok, [tee]} = SnapshotRoundTeeProfiles.run(admin, round.id, [profile.id])

    {:ok, competition} =
      ConfigureRoundCompetition.run(admin, event.id, round.id, %{
        handicap_allowance_percent: 100,
        pickup_policy_identifier: "standard_pickup_v1"
      })

    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    start_hole = hd(route)

    assert {:ok, _} =
             assign_start_for_fixture(
               admin,
               event.id,
               round.id,
               group.id,
               start_hole.id,
               1
             )

    entries =
      for _ <- 1..player_count do
        player = create_player!()

        {:ok, entry} =
          Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

        assert {:ok, _} =
                 assign_entry_to_group_for_fixture(admin, event.id, round.id, entry.id, group.id)

        assert {:ok, _} =
                 assign_round_tee_for_fixture(admin, event.id, round.id, entry.id, tee.id)

        assert {:ok, _} =
                 Scoring.confirm_handicap_input(admin, event.id, round.id, entry.id, %{
                   source_handicap_index: D.new("10.0")
                 })

        {:ok, attrs} =
          CourseHandicap.calculate(
            D.new("10.0"),
            tee.slope_rating,
            tee.course_rating,
            tee.applicable_par
          )

        {:ok, snapshot} = Scoring.build_handicap_snapshot(entry.id, attrs)
        {:ok, playing} = PlayingHandicap.calculate(snapshot.course_handicap_unrounded, 100)

        assert {:ok, _} =
                 Scoring.build_competition_handicap(
                   entry.id,
                   competition.id,
                   Map.merge(playing, %{
                     policy_identifier: "whs_golfrsa_2026_v1",
                     allowance_applied: true
                   })
                 )

        entry
      end

    [scorer | _] = entries

    assert {:ok, _} =
             assign_primary_scorer_for_fixture(
               admin,
               event.id,
               round.id,
               group.id,
               scorer.id
             )

    set_round_state!(round, :scoring_open)

    %{
      event: event,
      round: round,
      admin: admin,
      group: group,
      entries: entries,
      route: route,
      start_hole: start_hole,
      competition: competition,
      course: course,
      catalog_holes: holes,
      tee_set: white,
      tee_profile: profile,
      tee_snapshot: tee
    }
  end

  def configure_single_group_mystery!(setup) do
    configure_mystery_for_groups!(setup, [{setup.group, setup.entries}])
  end

  def configure_mystery_for_groups!(setup, group_entries) do
    set_round_state!(setup.round, :draft)

    for {_group, entries} <- group_entries do
      {:ok, side} =
        Competition.create_competition_side(
          setup.admin,
          setup.event.id,
          setup.round.id,
          setup.competition.id,
          :partnership
        )

      assert {:ok, _} =
               set_side_membership_for_fixture(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 setup.competition.id,
                 side.id,
                 Enum.map(entries, & &1.id)
               )
    end

    assert {:ok, track} =
             Competition.configure_scoring_track(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               %{
                 track_type: :mystery,
                 name: "GLS-35 Mystery",
                 is_primary: true,
                 visibility_policy_identifier: "staff_only_v1",
                 aggregation_policy_identifier: "mystery_v1",
                 tie_break_policy_identifier: "mystery_holes_then_countback_v1"
               }
             )

    assert {:ok, rule} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               track.id,
               setup.start_hole.id,
               :best
             )

    set_round_state!(setup.round, :scoring_open)
    %{track: track, rule: rule}
  end

  def add_player_entries_to_group!(setup, group, player_count) do
    entries =
      for _ <- 1..player_count do
        player = create_player!()

        assert {:ok, entry} =
                 Competition.add_round_entry(setup.event.id, setup.round.id, player.id,
                   actor: setup.admin
                 )

        assert {:ok, _} =
                 assign_entry_to_group_for_fixture(
                   setup.admin,
                   setup.event.id,
                   setup.round.id,
                   entry.id,
                   group.id
                 )

        assert {:ok, _} =
                 assign_round_tee_for_fixture(
                   setup.admin,
                   setup.event.id,
                   setup.round.id,
                   entry.id,
                   setup.tee_snapshot.id
                 )

        assert {:ok, _} =
                 Scoring.confirm_handicap_input(
                   setup.admin,
                   setup.event.id,
                   setup.round.id,
                   entry.id,
                   %{
                     source_handicap_index: D.new("10.0")
                   }
                 )

        {:ok, attrs} =
          CourseHandicap.calculate(
            D.new("10.0"),
            setup.tee_snapshot.slope_rating,
            setup.tee_snapshot.course_rating,
            setup.tee_snapshot.applicable_par
          )

        {:ok, snapshot} = Scoring.build_handicap_snapshot(entry.id, attrs)
        {:ok, playing} = PlayingHandicap.calculate(snapshot.course_handicap_unrounded, 100)

        assert {:ok, _} =
                 Scoring.build_competition_handicap(
                   entry.id,
                   setup.competition.id,
                   Map.merge(playing, %{
                     policy_identifier: "whs_golfrsa_2026_v1",
                     allowance_applied: true
                   })
                 )

        entry
      end

    [scorer | _] = entries

    assert {:ok, _} =
             assign_primary_scorer_for_fixture(
               setup.admin,
               setup.event.id,
               setup.round.id,
               group.id,
               scorer.id
             )

    entries
  end

  def setup_two_group_mystery_fixture! do
    setup = setup_submit_fixture!(2)
    set_round_state!(setup.round, :draft)

    assert {:ok, group_b} =
             Competition.create_playing_group(setup.event.id, setup.round.id, actor: setup.admin)

    assert {:ok, _} =
             assign_start_for_fixture(
               setup.admin,
               setup.event.id,
               setup.round.id,
               group_b.id,
               setup.start_hole.id,
               2
             )

    entries_b = add_player_entries_to_group!(setup, group_b, 2)

    mystery =
      configure_mystery_for_groups!(setup, [{setup.group, setup.entries}, {group_b, entries_b}])

    Map.merge(setup, %{
      group_b: group_b,
      entries_b: entries_b,
      mystery: mystery
    })
  end

  def set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  # Fixture transactions use internal actions instead of composing standalone services.
  defp assign_start_for_fixture(actor, event_id, round_id, group_id, hole_id, position) do
    if Repo.in_transaction?() do
      fixture_update(PlayingGroup, group_id, :assign_start_internal, %{
        starting_round_hole_id: hole_id,
        starting_position: position
      })
    else
      AssignPlayingGroupStart.run(actor, event_id, round_id, group_id, hole_id, position)
    end
  end

  defp assign_entry_to_group_for_fixture(actor, event_id, round_id, entry_id, group_id) do
    if Repo.in_transaction?() do
      fixture_update(RoundEntry, entry_id, :assign_playing_group_internal, %{
        playing_group_id: group_id
      })
    else
      AssignEntryToGroup.run(actor, event_id, round_id, entry_id, group_id)
    end
  end

  defp assign_round_tee_for_fixture(actor, event_id, round_id, entry_id, tee_snapshot_id) do
    if Repo.in_transaction?() do
      fixture_update(RoundEntry, entry_id, :assign_round_tee_internal, %{
        round_tee_profile_snapshot_id: tee_snapshot_id
      })
    else
      Competition.assign_round_tee(actor, event_id, round_id, entry_id, tee_snapshot_id)
    end
  end

  defp assign_primary_scorer_for_fixture(actor, event_id, round_id, group_id, entry_id) do
    if Repo.in_transaction?() do
      fixture_create(GroupRoleAssignment, :create_internal, %{
        round_id: round_id,
        playing_group_id: group_id,
        round_entry_id: entry_id,
        role: :primary_scorer,
        assignment_version: 1
      })
    else
      Competition.assign_primary_scorer(actor, event_id, round_id, group_id, entry_id)
    end
  end

  def assign_designated_verifier_for_fixture(actor, event_id, round_id, group_id, entry_id) do
    if Repo.in_transaction?() do
      fixture_create(GroupRoleAssignment, :create_internal, %{
        round_id: round_id,
        playing_group_id: group_id,
        round_entry_id: entry_id,
        role: :designated_verifier,
        assignment_version: 1
      })
    else
      Competition.assign_designated_verifier(actor, event_id, round_id, group_id, entry_id)
    end
  end

  def set_side_membership_for_fixture(
        actor,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        entry_ids
      ) do
    if Repo.in_transaction?() do
      memberships =
        Enum.map(entry_ids, fn entry_id ->
          {:ok, membership} =
            fixture_create(CompetitionSideMembership, :create_internal, %{
              round_id: round_id,
              round_competition_id: round_competition_id,
              competition_side_id: side_id,
              round_entry_id: entry_id
            })

          membership
        end)

      {:ok, memberships}
    else
      Competition.set_side_membership(
        actor,
        event_id,
        round_id,
        round_competition_id,
        side_id,
        entry_ids
      )
    end
  end

  defp fixture_create(resource, action, attributes) do
    resource
    |> Changeset.for_create(action, attributes)
    |> Ash.create(authorize?: false)
  end

  defp fixture_update(resource, record_id, action, attributes) do
    with {:ok, record} <- Ash.get(resource, record_id, authorize?: false) do
      record
      |> Changeset.for_update(action, attributes)
      |> Ash.update(authorize?: false)
    end
  end

  def create_event! do
    Event
    |> Changeset.for_create(:create_internal, %{})
    |> Ash.create!(authorize?: false)
  end

  defp create_event_admin!(event) do
    staff = create_staff_user!()

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id)]
    )

    staff
  end

  defp create_staff_user! do
    email = "#{Process.get(:gls34_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfCatalog.create_course(
        event.id,
        %{name: "GLS-34 Course", location: "Test"},
        actor: admin
      )

    course
  end

  defp create_eighteen_holes!(event, admin, course) do
    for n <- 1..18 do
      {:ok, hole} =
        GolfCatalog.configure_course_hole(
          event.id,
          %{course_id: course.id, hole_number: n},
          actor: admin
        )

      hole
    end
  end

  defp create_tee_set!(event, admin, course, name) do
    {:ok, tee_set} =
      GolfCatalog.configure_tee_set(event.id, %{course_id: course.id, name: name}, actor: admin)

    tee_set
  end

  defp create_profile!(event, admin, tee_set, holes, label, opts) do
    par = Keyword.get(opts, :par, 4)
    slope = Keyword.get(opts, :slope, 113)

    hole_ratings =
      Enum.map(holes, fn hole ->
        %{
          course_hole_id: hole.id,
          par: par,
          stroke_index: hole.hole_number,
          distance_m: 300 + hole.hole_number
        }
      end)

    {:ok, profile} =
      GolfCatalog.configure_tee_rating_profile(
        event.id,
        %{
          tee_set_id: tee_set.id,
          rating_label: label,
          course_rating: D.new("72.0"),
          slope_rating: slope,
          total_par: par * 18,
          hole_ratings: hole_ratings
        },
        actor: admin
      )

    profile
  end

  defp create_player! do
    Player
    |> Changeset.for_create(:create_internal, %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    })
    |> Ash.create!(authorize?: false)
  end
end
