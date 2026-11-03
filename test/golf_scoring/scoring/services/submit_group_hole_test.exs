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

    submissions_before = hole_submission_count_for_round!(setup.round.id)
    assert hole_submission_count_for_round!(setup.round.id) == submissions_before
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

  test "pickup uses primary RoundCompetition when a non-primary side exists with different policy" do
    setup = setup_submit_fixture!(2)
    insert_non_primary_competition!(setup, "never_pickup_policy")

    hole_id = expected_hole_id!(setup)
    [entry | _] = setup.entries

    results = [
      %{
        round_entry_id: entry.id,
        outcome: :picked_up,
        gross_strokes: nil,
        strokes_taken: 8
      },
      %{round_entry_id: List.last(setup.entries).id, outcome: :holed_out, gross_strokes: 4}
    ]

    command = base_command(setup, hole_id, 0, results)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "primary competition query requires is_primary filter (non-primary row ignored)" do
    setup = setup_submit_fixture!(2)
    insert_non_primary_competition!(setup, "decoy_policy_should_not_win")

    hole_id = expected_hole_id!(setup)

    [[primary]] =
      Repo.query!(
        "SELECT pickup_policy_identifier FROM round_competitions WHERE round_id = $1::uuid AND is_primary = true",
        [Ecto.UUID.dump!(setup.round.id)]
      ).rows

    assert primary == "standard_pickup_v1"

    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "eligible standard pickup accepts picked_up without gross_strokes" do
    setup = setup_submit_fixture!(2)
    set_playing_handicap!(setup, hd(setup.entries).id, 18)
    hole_id = expected_hole_id!(setup)

    results =
      pickup_results(setup.entries, hole_id, setup, strokes_taken: 10, eligible?: true)

    command = base_command(setup, hole_id, 0, results)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "ineligible pickup returns pickup_not_eligible" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    results =
      pickup_results(setup.entries, hole_id, setup, strokes_taken: 1, eligible?: false)

    command = base_command(setup, hole_id, 0, results)

    assert {:error, :pickup_not_eligible} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "plus playing handicap pickup uses frozen plus_stroke_order facts" do
    setup = setup_submit_fixture!(2)
    apply_plus_stroke_orders!(setup)
    set_playing_handicap!(setup, hd(setup.entries).id, -1)
    set_playing_handicap!(setup, List.last(setup.entries).id, 10)
    hole_id = expected_hole_id!(setup)

    results =
      pickup_results(setup.entries, hole_id, setup, strokes_taken: 10, eligible?: true)

    command = base_command(setup, hole_id, 0, results)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "unsupported pickup policy on primary competition is rejected" do
    setup = setup_submit_fixture!(2)

    Repo.query!(
      "UPDATE round_competitions SET pickup_policy_identifier = $1 WHERE id = $2::uuid",
      ["unsupported_pickup_v999", Ecto.UUID.dump!(setup.competition.id)]
    )

    hole_id = expected_hole_id!(setup)

    results =
      pickup_results(setup.entries, hole_id, setup, strokes_taken: 10, eligible?: true)

    command = base_command(setup, hole_id, 0, results)

    assert {:error, :unsupported_pickup_policy} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "final hole acceptance finishes group and completes lifecycle" do
    setup = setup_submit_fixture!(2)
    advance_to_revision!(setup, 17)

    hole_id = hole_at_revision!(setup, 17)
    command = base_command(setup, hole_id, 17, holed_out_results(setup.entries, 4))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, receipt} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert receipt.expected_group_score_revision == 17

    group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    assert group.state == :finished_playing
    assert group.scoring_revision == 18

    for entry <- setup.entries do
      assert Ash.get!(RoundEntry, entry.id, authorize?: false).participation_status == :completed
    end

    cards =
      Scorecard
      |> Ash.Query.filter(round_entry_id in ^Enum.map(setup.entries, & &1.id))
      |> Ash.read!(authorize?: false)

    assert Enum.all?(cards, &(&1.state == :complete))
    assert_receive {:group_hole_submitted, _}
  end

  test "final hole identical retry is idempotent without side effects" do
    setup = setup_submit_fixture!(2)
    advance_to_revision!(setup, 17)
    hole_id = hole_at_revision!(setup, 17)
    command = base_command(setup, hole_id, 17, holed_out_results(setup.entries, 4))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, first} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert_receive {:group_hole_submitted, _}

    audits = audit_count!()
    results = hole_result_count!()
    submissions = hole_submission_count!()

    assert {:ok, second} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert second.id == first.id
    assert audit_count!() == audits
    assert hole_result_count!() == results
    assert hole_submission_count!() == submissions
    refute_receive {:group_hole_submitted, _}, 50
  end

  test "new command after group finished is rejected" do
    setup = setup_submit_fixture!(2)
    advance_to_revision!(setup, 18)

    hole_id = hole_at_revision!(setup, 17)

    command =
      base_command(setup, hole_id, 18, holed_out_results(setup.entries, 4))
      |> Map.put(:client_submission_id, Ecto.UUID.generate())

    assert {:error, {:invalid_group_state, :finished_playing}} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "same client key with different payload after finish returns idempotency conflict" do
    setup = setup_submit_fixture!(2)
    advance_to_revision!(setup, 17)
    hole_id = hole_at_revision!(setup, 17)
    submission_id = Ecto.UUID.generate()

    command =
      base_command(setup, hole_id, 17, holed_out_results(setup.entries, 4))
      |> Map.put(:client_submission_id, submission_id)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    changed =
      command
      |> Map.put(:results, holed_out_results(setup.entries, 5))

    assert {:error, :idempotency_payload_conflict} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, changed)
  end

  test "reordered equivalent results produce identical idempotent retry" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [a, b] = setup.entries

    ordered = [
      %{round_entry_id: a.id, outcome: :holed_out, gross_strokes: 4},
      %{round_entry_id: b.id, outcome: :holed_out, gross_strokes: 5}
    ]

    reversed = Enum.reverse(ordered)
    submission_id = Ecto.UUID.generate()
    captured_at = DateTime.utc_now()

    first_cmd =
      base_command(setup, hole_id, 0, ordered)
      |> Map.put(:client_submission_id, submission_id)
      |> Map.put(:captured_at, captured_at)

    assert {:ok, receipt} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, first_cmd)

    retry_cmd = Map.put(first_cmd, :results, reversed)

    assert {:ok, second} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, retry_cmd)

    assert second.id == receipt.id
  end

  test "staff command with role_assignment_version is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, 1)

    assert {:error, :staff_role_version_forbidden} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  for role <- [:competition_manager, :scoring_support] do
    @tag staff_role: role
    test "staff emergency role #{role} can submit", %{staff_role: role} do
      setup = setup_submit_fixture!(2)
      staff = create_staff_user!()

      {:ok, _} =
        Accounts.assign_event_staff_role(
          %{event_id: setup.event.id, staff_user_id: staff.id, role: role},
          actor: setup.admin
        )

      hole_id = expected_hole_id!(setup)
      command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

      assert {:ok, _} = SubmitGroupHole.run(staff, setup.event.id, setup.round.id, command)
    end
  end

  test "internal lifecycle transitions without SubmitGroupHole progression are blocked" do
    setup = setup_submit_fixture!(2)
    entry = hd(setup.entries)

    assert {:error, %Ash.Error.Invalid{}} =
             RoundEntry
             |> Ash.get!(entry.id, authorize?: false)
             |> Changeset.for_update(:mark_participation_completed_internal, %{})
             |> Ash.update(authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             PlayingGroup
             |> Ash.get!(setup.group.id, authorize?: false)
             |> Changeset.for_update(:increment_scoring_revision_internal, %{})
             |> Ash.update(authorize?: false)
  end

  test "shotgun start advances through wrap and final scheduled hole" do
    setup = setup_shotgun_fixture!(10)

    for rev <- 0..16 do
      hole_id = hole_at_revision!(setup, rev)

      assert {:ok, _} =
               SubmitGroupHole.run(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 base_command(setup, hole_id, rev, holed_out_results(setup.entries, 4))
               )
    end

    final_hole = hole_at_revision!(setup, 17)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, final_hole, 17, holed_out_results(setup.entries, 4))
             )

    group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    assert group.scoring_revision == 18
    assert group.state == :finished_playing
  end

  test "idempotency rejects actor mismatch on same client key" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    submission_id = Ecto.UUID.generate()

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:client_submission_id, submission_id)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    other = create_staff_user!()

    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: setup.event.id, staff_user_id: other.id, role: :competition_manager},
        actor: setup.admin
      )

    assert {:error, :idempotency_actor_mismatch} =
             SubmitGroupHole.run(other, setup.event.id, setup.round.id, command)
  end

  test "idempotency rejects payload conflict on same client key" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    submission_id = Ecto.UUID.generate()

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:client_submission_id, submission_id)

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    changed =
      command
      |> Map.put(:results, holed_out_results(setup.entries, 6))

    assert {:error, :idempotency_payload_conflict} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, changed)
  end

  test "different client key at stale revision is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    assert {:error, :stale_scoring_revision} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )
  end

  test "expired player grant is rejected" do
    setup = setup_submit_fixture!(2)
    scorer = hd(setup.entries)
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(
               setup.admin,
               setup.event.id,
               scorer.player_id,
               expires_at: past
             )

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(playing_group_id == ^setup.group.id and role == :primary_scorer)
      |> Ash.read_one!(authorize?: false)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version)

    assert {:error, :invalid_player_session} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  test "wrong-event player grant is rejected" do
    setup = setup_submit_fixture!(2)
    wrong_event = create_event!()
    scorer = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(playing_group_id == ^setup.group.id and role == :primary_scorer)
      |> Ash.read_one!(authorize?: false)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version)

    assert {:error, :invalid_player_session} =
             SubmitGroupHole.run(grant, wrong_event.id, setup.round.id, command)
  end

  test "revoked player grant is rejected" do
    setup = setup_submit_fixture!(2)
    scorer = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(playing_group_id == ^setup.group.id and role == :primary_scorer)
      |> Ash.read_one!(authorize?: false)

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, scorer.player_id)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, assignment.assignment_version)

    assert {:error, :invalid_player_session} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  test "post-write injected failure rolls back all scoring artifacts" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    Process.put(:gls34_inject_failure_after_hole_results, true)

    try do
      assert {:error, :gls34_injected_test_failure} =
               SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
    after
      Process.delete(:gls34_inject_failure_after_hole_results)
    end

    results_before = hole_result_count_for_round!(setup.round.id)
    submissions_before = hole_submission_count_for_round!(setup.round.id)
    audits_before = audit_count!()

    Process.put(:gls34_inject_failure_after_hole_results, true)

    try do
      assert {:error, :gls34_injected_test_failure} =
               SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
    after
      Process.delete(:gls34_inject_failure_after_hole_results)
    end

    assert hole_result_count_for_round!(setup.round.id) == results_before
    assert hole_submission_count_for_round!(setup.round.id) == submissions_before
    assert audit_count!() == audits_before
    group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    assert group.scoring_revision == 0
    assert group.state == :not_started
    refute_receive {:group_hole_submitted, _}, 50
  end

  @tag :real_concurrency
  test "simultaneous submissions serialize on the playing group lock" do
    setup =
      Sandbox.unboxed_run(Repo, fn ->
        setup_submit_fixture!(2)
      end)

    hole_id = expected_hole_id!(setup)
    parent = self()
    start_ref = make_ref()
    staff_id = setup.admin.id

    task_a =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {start_ref, :ready_a})

          receive do
            ^start_ref -> :go
          end

          SubmitGroupHole.run(
            %{id: staff_id},
            setup.event.id,
            setup.round.id,
            base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
          )
        end)
      end)

    task_b =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Sandbox.allow(Repo, parent, self())
          send(parent, {start_ref, :ready_b})

          receive do
            ^start_ref -> :go
          end

          SubmitGroupHole.run(
            %{id: staff_id},
            setup.event.id,
            setup.round.id,
            base_command(setup, hole_id, 0, holed_out_results(setup.entries, 5))
          )
        end)
      end)

    assert_receive {^start_ref, :ready_a}, 5_000
    assert_receive {^start_ref, :ready_b}, 5_000
    send(task_a.pid, start_ref)
    send(task_b.pid, start_ref)

    results = [Task.await(task_a, 20_000), Task.await(task_b, 20_000)]
    oks = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.count(results, &match?({:error, _}, &1))

    assert oks == 1,
           "expected one acceptance, got #{inspect(results)}"

    assert errors == 1
    assert hole_result_count_for_round!(setup.round.id) == 2
    assert hole_submission_count_for_round!(setup.round.id) == 1
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 1
  end

  defp setup_shotgun_fixture!(start_play_order) do
    setup = setup_submit_fixture!(2)
    set_round_state!(setup.round, :draft)
    start_hole = Enum.find(setup.route, &(&1.play_order == start_play_order))

    assert {:ok, _} =
             AssignPlayingGroupStart.run(
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

  defp hole_at_revision!(%{route: route, start_hole: start_hole}, revision) do
    start_index = Enum.find_index(route, &(&1.id == start_hole.id))
    {head, tail} = Enum.split(route, start_index)
    rotated = tail ++ head
    Enum.at(rotated, revision).id
  end

  defp advance_to_revision!(setup, target_revision) do
    for rev <- 0..(target_revision - 1) do
      hole_id = hole_at_revision!(setup, rev)

      assert {:ok, _} =
               SubmitGroupHole.run(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 base_command(setup, hole_id, rev, holed_out_results(setup.entries, 4))
               )
    end
  end

  defp insert_non_primary_competition!(setup, pickup_policy) do
    Repo.query!(
      """
      INSERT INTO round_competitions (
        id, event_id, round_id, is_primary, scoring_policy_identifier,
        handicap_allowance_percent, pickup_policy_identifier
      )
      SELECT gen_random_uuid(), event_id, round_id, false, scoring_policy_identifier,
             handicap_allowance_percent, $2
      FROM round_competitions
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(setup.competition.id), pickup_policy]
    )
  end

  defp set_playing_handicap!(setup, entry_id, handicap) do
    Repo.query!(
      """
      UPDATE competition_handicaps
      SET playing_handicap = $1
      WHERE round_entry_id = $2::uuid AND round_competition_id = $3::uuid
      """,
      [handicap, Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(setup.competition.id)]
    )
  end

  defp apply_plus_stroke_orders!(setup) do
    plus_by_si = %{10 => 1, 3 => 2, 14 => 3, 7 => 4, 18 => 5, 2 => 6, 11 => 7, 5 => 8}

    for hole <- setup.route do
      si = hole.play_order

      if order = Map.get(plus_by_si, si) do
        Repo.query!(
          """
          UPDATE round_tee_hole_snapshots rts
          SET plus_stroke_order = $1
          FROM round_entries re
          WHERE re.round_tee_profile_snapshot_id = rts.round_tee_profile_snapshot_id
            AND rts.round_hole_id = $2::uuid
            AND re.round_id = $3::uuid
          """,
          [order, Ecto.UUID.dump!(hole.id), Ecto.UUID.dump!(setup.round.id)]
        )
      end
    end
  end

  defp pickup_results(entries, _hole_id, _setup, opts) do
    strokes_taken = Keyword.fetch!(opts, :strokes_taken)
    eligible? = Keyword.get(opts, :eligible?, true)

    taken =
      if eligible? do
        strokes_taken
      else
        0
      end

    Enum.map(entries, fn entry ->
      %{
        round_entry_id: entry.id,
        outcome: :picked_up,
        gross_strokes: nil,
        strokes_taken: taken
      }
    end)
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

  defp hole_submission_count_for_round!(round_id) do
    HoleSubmission
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp hole_result_count_for_round!(round_id) do
    HoleResult
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> length()
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
