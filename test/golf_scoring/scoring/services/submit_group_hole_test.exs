defmodule GolfScoring.Scoring.Services.SubmitGroupHoleTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Decimal, as: D
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.HoleSubmission
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @password "GLS-34 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls34_prefix, "gls34-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  for player_count <- [2, 3, 4] do
    @tag player_count: player_count
    test "valid #{player_count}-player group submits first holed_out hole (revision 0 -> 1)", %{
      player_count: player_count
    } do
      setup = setup_submit_fixture!(player_count)
      hole_id = expected_hole_id!(setup)
      command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

      Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

      assert {:ok, receipt} =
               SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

      assert receipt.client_submission_id == command.client_submission_id
      assert receipt.expected_group_score_revision == 0

      group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
      assert group.state == :playing
      assert group.scoring_revision == 1

      for entry <- setup.entries do
        loaded = Ash.get!(RoundEntry, entry.id, authorize?: false)
        assert loaded.participation_status == :active
      end

      scorecards =
        Scorecard
        |> Ash.Query.filter(round_entry_id in ^Enum.map(setup.entries, & &1.id))
        |> Ash.read!(authorize?: false)

      assert length(scorecards) == player_count
      assert Enum.all?(scorecards, &(&1.state == :in_progress))

      assert_receive {:group_hole_submitted, payload}
      assert payload.round_id == setup.round.id
      assert payload.playing_group_id == setup.group.id
      assert payload.round_hole_id == hole_id
      assert payload.scoring_revision == 1
    end
  end

  test "identical retry is idempotent (same receipt, no extra audit, hole results, or pubsub)" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 5))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, first} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert_receive {:group_hole_submitted, _}

    audits_before = audit_count!()
    results_before = hole_result_count!()
    submissions_before = hole_submission_count!()

    assert {:ok, second} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert second.id == first.id
    assert audit_count!() == audits_before
    assert hole_result_count!() == results_before
    assert hole_submission_count!() == submissions_before
    refute_receive {:group_hole_submitted, _}, 50
  end

  test "stale expected_group_score_revision is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 1, holed_out_results(setup.entries, 4))

    assert {:error, :stale_scoring_revision} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert hole_submission_count!() == 0
  end

  test "wrong round_hole_id is rejected" do
    setup = setup_submit_fixture!(2)
    expected = expected_hole_id!(setup)
    wrong = Enum.find(setup.route, &(&1.id != expected)).id

    command = base_command(setup, wrong, 0, holed_out_results(setup.entries, 4))

    assert {:error, :wrong_round_hole} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "missing result entry is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [first | _] = setup.entries
    results = holed_out_results([first], 4)

    command = base_command(setup, hole_id, 0, results)

    assert {:error, :results_count_mismatch} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "extra result for unknown entry is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [first | _] = setup.entries

    results = [
      %{round_entry_id: first.id, outcome: :holed_out, gross_strokes: 4},
      %{round_entry_id: Ecto.UUID.generate(), outcome: :holed_out, gross_strokes: 4}
    ]

    command = base_command(setup, hole_id, 0, results)

    assert {:error, :results_participant_mismatch} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "event_admin staff can submit" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "registration_staff cannot submit" do
    setup = setup_submit_fixture!(2)
    reg_staff = create_staff_user!()

    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: setup.event.id, staff_user_id: reg_staff.id, role: :registration_staff},
        actor: setup.admin
      )

    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    assert {:error, :forbidden} =
             SubmitGroupHole.run(reg_staff, setup.event.id, setup.round.id, command)
  end

  test "primary scorer player grant submits with role_assignment_version" do
    setup = setup_submit_fixture!(2)
    scorer_entry = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer_entry.player_id)

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(
        playing_group_id == ^setup.group.id and round_entry_id == ^scorer_entry.id and
          role == :primary_scorer and state == :active
      )
      |> Ash.read_one!(authorize?: false)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version)

    assert {:ok, receipt} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)

    assert receipt.submitted_by_round_entry_id == scorer_entry.id
    assert receipt.role_assignment_version == assignment.assignment_version
  end

  test "player submit rejects stale role_assignment_version" do
    setup = setup_submit_fixture!(2)
    scorer_entry = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer_entry.player_id)

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(
        playing_group_id == ^setup.group.id and round_entry_id == ^scorer_entry.id and
          role == :primary_scorer
      )
      |> Ash.read_one!(authorize?: false)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version + 99)

    assert {:error, :stale_role_assignment} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  test "player grant without primary scorer role is rejected" do
    setup = setup_submit_fixture!(2)
    non_scorer = List.last(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, non_scorer.player_id)

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(playing_group_id == ^setup.group.id and role == :primary_scorer)
      |> Ash.read_one!(authorize?: false)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version)

    assert {:error, :not_primary_scorer} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  test "Scoring.submit_group_hole delegates to service" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    assert {:ok, _} =
             Scoring.submit_group_hole(setup.admin, setup.event.id, setup.round.id, command)
  end

  defp setup_submit_fixture!(player_count) do
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
             AssignPlayingGroupStart.run(
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
                 AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

        assert {:ok, _} =
                 Competition.assign_round_tee(admin, event.id, round.id, entry.id, tee.id)

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
             Competition.assign_primary_scorer(
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
      competition: competition
    }
  end

  defp expected_hole_id!(%{start_hole: start_hole}), do: start_hole.id

  defp base_command(setup, round_hole_id, revision, results) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: setup.group.id,
      round_hole_id: round_hole_id,
      expected_group_score_revision: revision,
      results: results,
      captured_at: DateTime.utc_now()
    }
  end

  defp holed_out_results(entries, strokes) do
    Enum.map(entries, fn entry ->
      %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: strokes}
    end)
  end

  defp audit_count! do
    AuditEvent
    |> Ash.Query.filter(action == "submit_group_hole")
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp hole_result_count! do
    HoleResult |> Ash.read!(authorize?: false) |> length()
  end

  defp hole_submission_count! do
    HoleSubmission |> Ash.read!(authorize?: false) |> length()
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  defp create_event! do
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
