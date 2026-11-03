defmodule GolfScoring.Scoring.Services.SubmitGroupHoleTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Competition.Services.MysteryRevealCoordinator
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.HoleSubmission
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @advisory_submit_audit 9_034_034
  @advisory_handover_audit 9_034_035
  @advisory_mystery_reveal_insert 9_035_036

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
    mystery = configure_single_group_mystery!(setup)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 5))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, first} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert_receive {:group_hole_submitted, _}
    assert_receive {:mystery_reveal_changed, payload}
    assert payload == %{round_id: setup.round.id}

    audits_before = audit_count!()
    results_before = hole_result_count!()
    submissions_before = hole_submission_count!()
    reveals_before = mystery_reveal_count_for_rule!(mystery.rule.id)
    group_before = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)

    assert {:ok, second} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert second.id == first.id
    assert audit_count!() == audits_before
    assert hole_result_count!() == results_before
    assert hole_submission_count!() == submissions_before
    assert mystery_reveal_count_for_rule!(mystery.rule.id) == reveals_before

    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision ==
             group_before.scoring_revision

    refute_receive {:group_hole_submitted, _}, 50
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "MysteryReveal is hidden by row absence and unique per rule with no PlayingGroup foreign key" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)

    assert [[true]] =
             Repo.query!("SELECT to_regclass('public.mystery_reveals') IS NOT NULL").rows

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 0

    Repo.query!(
      "INSERT INTO mystery_reveals (mystery_hole_rule_id) VALUES ($1::uuid)",
      [Ecto.UUID.dump!(mystery.rule.id)]
    )

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 1

    duplicate =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO mystery_reveals (mystery_hole_rule_id) VALUES ($1::uuid)",
          [Ecto.UUID.dump!(mystery.rule.id)]
        )
      end

    assert duplicate.postgres.code == :unique_violation
    assert duplicate.postgres.constraint == "mystery_reveals_unique_mystery_hole_rule_index"

    assert [[0]] =
             Repo.query!("""
             SELECT count(*)::int
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'mystery_reveals'
               AND column_name = 'playing_group_id'
             """).rows

    assert [[0]] =
             Repo.query!("""
             SELECT count(*)::int
             FROM pg_constraint
             WHERE conrelid = 'public.mystery_reveals'::regclass
               AND contype = 'f'
               AND confrelid = 'public.playing_groups'::regclass
             """).rows
  end

  test "ordinary accepted submission without a MysteryHoleRule does not emit a reveal refresh" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    assert_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "single-group Mystery cohort reveals after the accepted target-hole submission" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(
                 setup,
                 setup.start_hole.id,
                 0,
                 holed_out_results(setup.entries, 4)
               )
             )

    assert_receive {:group_hole_submitted, _}
    assert_receive {:mystery_reveal_changed, payload}
    assert payload == %{round_id: setup.round.id}
    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 1
  end

  test "coordinator leaves a required group hidden without an accepted submission" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)

    assert {:ok, %{created?: false}} =
             Repo.transaction(fn ->
               assert {:ok, %{created?: false}} =
                        MysteryRevealCoordinator.recheck(
                          setup.round.id,
                          setup.start_hole.id
                        )

               %{created?: false}
             end)

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 0
  end

  test "multiple-group cohort waits for the last required group submission" do
    setup = setup_two_group_mystery_fixture!()
    group_b = Map.merge(setup, %{group: setup.group_b, entries: setup.entries_b})

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(
                 setup,
                 setup.start_hole.id,
                 0,
                 holed_out_results(setup.entries, 4)
               )
             )

    assert_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}, 50
    assert mystery_reveal_count_for_rule!(setup.mystery.rule.id) == 0

    assert {:ok, _} =
             SubmitGroupHole.run(
               group_b.admin,
               group_b.event.id,
               group_b.round.id,
               base_command(
                 group_b,
                 setup.start_hole.id,
                 0,
                 holed_out_results(group_b.entries, 5)
               )
             )

    assert_receive {:group_hole_submitted, _}
    assert_receive {:mystery_reveal_changed, payload}
    assert payload == %{round_id: setup.round.id}
    assert mystery_reveal_count_for_rule!(setup.mystery.rule.id) == 1
  end

  test "coordinator recheck after reveal is an idempotent no-op" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)
    hole_id = setup.start_hole.id

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 1

    assert {:ok, %{created?: false}} =
             Repo.transaction(fn ->
               assert {:ok, %{created?: false}} =
                        MysteryRevealCoordinator.recheck(setup.round.id, hole_id)

               %{created?: false}
             end)

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 1
  end

  test "committed reveal remains readable when no PubSub subscriber observes it" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(
                 setup,
                 setup.start_hole.id,
                 0,
                 holed_out_results(setup.entries, 4)
               )
             )

    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 1
  end

  test "late MysteryReveal insert failure rolls back the new submission and emits no PubSub" do
    setup = setup_submit_fixture!(2)
    mystery = configure_single_group_mystery!(setup)
    force_mystery_reveal_insert_failure!()

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:error, _reason} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(
                 setup,
                 setup.start_hole.id,
                 0,
                 holed_out_results(setup.entries, 4)
               )
             )

    assert hole_result_count_for_round!(setup.round.id) == 0
    assert hole_submission_count_for_round!(setup.round.id) == 0
    assert audit_count_for_round!(setup.round.id) == 0
    assert scorecard_facts_for_round!(setup.round.id) == []
    assert mystery_reveal_count_for_rule!(mystery.rule.id) == 0
    group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    assert group.scoring_revision == 0
    assert group.state == :not_started

    for entry <- setup.entries do
      assert Ash.get!(RoundEntry, entry.id, authorize?: false).participation_status ==
               :not_started
    end

    refute_receive {:group_hole_submitted, _}, 50
    refute_receive {:mystery_reveal_changed, _}, 50
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

  test "late submit_group_hole audit failure rolls back all scoring artifacts" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    results_before = hole_result_count_for_round!(setup.round.id)
    submissions_before = hole_submission_count_for_round!(setup.round.id)
    audits_before = audit_count_for_round!(setup.round.id)
    group_before = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    scorecards_before = scorecard_facts_for_round!(setup.round.id)
    assert scorecards_before == []

    install_gls34_reject_submit_audit_trigger!()

    try do
      assert {:error, _} =
               SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
    after
      remove_gls34_reject_submit_audit_trigger!()
    end

    assert hole_result_count_for_round!(setup.round.id) == results_before
    assert hole_submission_count_for_round!(setup.round.id) == submissions_before
    assert audit_count_for_round!(setup.round.id) == audits_before
    assert scorecard_facts_for_round!(setup.round.id) == scorecards_before

    refute Enum.any?(scorecard_facts_for_round!(setup.round.id), fn %{state: state} ->
             state in [:in_progress, :complete, "in_progress", "complete"]
           end)

    group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)
    assert group.scoring_revision == group_before.scoring_revision
    assert group.state == group_before.state

    for entry <- setup.entries do
      assert Ash.get!(RoundEntry, entry.id, authorize?: false).participation_status ==
               :not_started
    end

    refute_receive {:group_hole_submitted, _}, 50
  end

  test "committed scoring race fixture cleanup removes fixture-owned catalog rows" do
    fixture = setup_committed_scoring_race_fixture!()

    assert catalog_entity_exists?(:courses, fixture.course.id)
    assert catalog_entity_exists?(:tee_sets, fixture.tee_set.id)
    assert catalog_entity_exists?(:tee_rating_profiles, fixture.tee_profile.id)
    assert course_hole_count!(fixture.course.id) == 18

    cleanup_committed_scoring_fixture!(fixture)

    refute catalog_entity_exists?(:courses, fixture.course.id)
    refute catalog_entity_exists?(:tee_sets, fixture.tee_set.id)
    refute catalog_entity_exists?(:tee_rating_profiles, fixture.tee_profile.id)
    assert course_hole_count!(fixture.course.id) == 0
  end

  @tag :real_concurrency
  test "concurrent final-group submissions produce exactly one global reveal" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup = setup_two_group_mystery_fixture!()
        scorer_a = hd(setup.entries)
        scorer_b = hd(setup.entries_b)
        grant_a = issue_group_scorer_grant!(setup, scorer_a)
        grant_b = issue_group_scorer_grant!(setup, scorer_b)

        Map.merge(setup, %{
          grant_a: grant_a,
          grant_b: grant_b,
          assignment_a: active_primary_assignment!(setup.group.id),
          assignment_b: active_primary_assignment!(setup.group_b.id)
        })
      end)

    try do
      setup_a = fixture
      setup_b = Map.merge(fixture, %{group: fixture.group_b, entries: fixture.entries_b})
      parent = self()

      Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

      task_a =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            pid = pg_backend_pid!()
            send(parent, {:gls35_submit_ready, :group_a, pid})
            receive do: (:gls35_submit_go -> :ok)

            command =
              base_command(
                setup_a,
                fixture.start_hole.id,
                0,
                holed_out_results(setup_a.entries, 4)
              )
              |> Map.put(:role_assignment_version, fixture.assignment_a.assignment_version)

            SubmitGroupHole.run(fixture.grant_a, fixture.event.id, fixture.round.id, command)
          end)
        end)

      task_b =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            pid = pg_backend_pid!()
            send(parent, {:gls35_submit_ready, :group_b, pid})
            receive do: (:gls35_submit_go -> :ok)

            command =
              base_command(
                setup_b,
                fixture.start_hole.id,
                0,
                holed_out_results(setup_b.entries, 5)
              )
              |> Map.put(:role_assignment_version, fixture.assignment_b.assignment_version)

            SubmitGroupHole.run(fixture.grant_b, fixture.event.id, fixture.round.id, command)
          end)
        end)

      assert_receive {:gls35_submit_ready, :group_a, pid_a}, 10_000
      assert_receive {:gls35_submit_ready, :group_b, pid_b}, 10_000
      refute pid_a == pid_b
      send(task_a.pid, :gls35_submit_go)
      send(task_b.pid, :gls35_submit_go)

      results = [Task.await(task_a, 20_000), Task.await(task_b, 20_000)]

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert hole_submission_count_for_round!(fixture.round.id) == 2
      assert mystery_reveal_count_for_rule!(fixture.mystery.rule.id) == 1

      assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
      assert round_id == fixture.round.id
      refute_receive {:mystery_reveal_changed, _}, 50
    after
      cleanup_committed_scoring_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "a recheck waits for the accepted final submission and observes its reveal" do
    fixture =
      Sandbox.unboxed_run(Repo, fn -> setup_two_group_mystery_fixture!() end)

    parent = self()
    Process.delete(:gls35_final_reveal_barrier_task)
    Process.delete(:gls35_final_reveal_tasks)

    try do
      Sandbox.unboxed_run(Repo, fn -> remove_gls35_reveal_insert_barrier_trigger!() end)

      Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

      setup_a = fixture
      setup_b = Map.merge(fixture, %{group: fixture.group_b, entries: fixture.entries_b})

      assert {:ok, _} =
               Sandbox.unboxed_run(Repo, fn ->
                 SubmitGroupHole.run(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   base_command(
                     setup_a,
                     fixture.start_hole.id,
                     0,
                     holed_out_results(setup_a.entries, 4)
                   )
                 )
               end)

      assert_receive {:group_hole_submitted, _}
      refute_receive {:mystery_reveal_changed, _}, 50

      assert 0 ==
               Sandbox.unboxed_run(Repo, fn ->
                 mystery_reveal_count_for_rule!(fixture.mystery.rule.id)
               end)

      Sandbox.unboxed_run(Repo, fn -> install_gls35_reveal_insert_barrier_trigger!() end)

      lock_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!(
                "SELECT pg_advisory_xact_lock($1)",
                [@advisory_mystery_reveal_insert]
              )

              send(parent, {:gls35_reveal_barrier_held, pg_backend_pid!()})
              receive do: (:gls35_release_reveal_barrier -> :ok)
            end)
          end)
        end)

      Process.put(:gls35_final_reveal_barrier_task, lock_holder)
      assert_receive {:gls35_reveal_barrier_held, _lock_pid}, 5_000

      final_submit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            pid = pg_backend_pid!()
            send(parent, {:gls35_final_submit_started, pid})

            SubmitGroupHole.run(
              fixture.admin,
              fixture.event.id,
              fixture.round.id,
              base_command(
                setup_b,
                fixture.start_hole.id,
                0,
                holed_out_results(setup_b.entries, 5)
              )
            )
          end)
        end)

      Process.put(:gls35_final_reveal_tasks, [final_submit])
      assert_receive {:gls35_final_submit_started, submit_pid}, 10_000
      await_backend_advisory_wait!(submit_pid, System.monotonic_time(:millisecond) + 10_000)

      recheck =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            pid = pg_backend_pid!()
            send(parent, {:gls35_final_recheck_started, pid})

            Repo.transaction(fn ->
              MysteryRevealCoordinator.recheck(fixture.round.id, fixture.start_hole.id)
            end)
          end)
        end)

      Process.put(:gls35_final_reveal_tasks, [final_submit, recheck])
      assert_receive {:gls35_final_recheck_started, recheck_pid}, 10_000
      refute submit_pid == recheck_pid
      await_blocked_by!(recheck_pid, submit_pid, System.monotonic_time(:millisecond) + 10_000)

      send(lock_holder.pid, :gls35_release_reveal_barrier)

      assert {:ok, receipt} = Task.await(final_submit, 20_000)
      assert receipt.playing_group_id == fixture.group_b.id
      Process.put(:gls35_final_reveal_tasks, [recheck])
      assert {:ok, {:ok, %{created?: false}}} = Task.await(recheck, 20_000)

      Process.delete(:gls35_final_reveal_tasks)
      Task.await(lock_holder, 10_000)
      Process.delete(:gls35_final_reveal_barrier_task)

      Sandbox.unboxed_run(Repo, fn -> remove_gls35_reveal_insert_barrier_trigger!() end)

      assert mystery_reveal_count_for_rule!(fixture.mystery.rule.id) == 1

      assert_receive {:group_hole_submitted, %{playing_group_id: group_id}}
      assert group_id == fixture.group_b.id
      assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
      assert round_id == fixture.round.id
      refute_receive {:mystery_reveal_changed, _}, 50
    after
      if lock_holder = Process.delete(:gls35_final_reveal_barrier_task) do
        send(lock_holder.pid, :gls35_release_reveal_barrier)
        Task.shutdown(lock_holder, 10_000)
      end

      for task <- Process.delete(:gls35_final_reveal_tasks) || [] do
        try do
          Task.shutdown(task, 10_000)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end

      Sandbox.unboxed_run(Repo, fn -> remove_gls35_reveal_insert_barrier_trigger!() end)
      cleanup_committed_scoring_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "simultaneous submissions serialize on the playing group lock" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_submit_fixture!(2)
      end)

    try do
      hole_id = expected_hole_id!(fixture)
      parent = self()
      staff_id = fixture.admin.id

      Sandbox.unboxed_run(Repo, fn ->
        install_gls34_submit_audit_barrier_trigger!()
      end)

      lock_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.query!("SELECT pg_advisory_lock($1)", [@advisory_submit_audit])
            send(parent, {:gls34_advisory_held, pg_backend_pid!()})

            receive do
              :gls34_release_advisory ->
                Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_submit_audit])
            end
          end)
        end)

      assert_receive {:gls34_advisory_held, _}, 5_000

      deadline = System.monotonic_time(:millisecond) + 15_000

      task_a =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Sandbox.allow(Repo, parent, self())
            submit_a_pid = pg_backend_pid!()
            send(parent, {:gls34_submit_a_pid, submit_a_pid})

            SubmitGroupHole.run(
              %{id: staff_id},
              fixture.event.id,
              fixture.round.id,
              base_command(fixture, hole_id, 0, holed_out_results(fixture.entries, 4))
            )
          end)
        end)

      assert_receive {:gls34_submit_a_pid, submit_a_pid}, 10_000
      await_backend_advisory_wait!(submit_a_pid, deadline)

      task_b =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Sandbox.allow(Repo, parent, self())
            submit_b_pid = pg_backend_pid!()
            send(parent, {:gls34_submit_b_pid, submit_b_pid})

            SubmitGroupHole.run(
              %{id: staff_id},
              fixture.event.id,
              fixture.round.id,
              base_command(fixture, hole_id, 0, holed_out_results(fixture.entries, 5))
            )
          end)
        end)

      assert_receive {:gls34_submit_b_pid, submit_b_pid}, 10_000

      await_blocked_by!(
        submit_b_pid,
        submit_a_pid,
        System.monotonic_time(:millisecond) + 10_000
      )

      send(lock_holder.pid, :gls34_release_advisory)

      results = [Task.await(task_a, 20_000), Task.await(task_b, 20_000)]
      Task.await(lock_holder, 10_000)

      oks = Enum.count(results, &match?({:ok, _}, &1))
      errors = Enum.count(results, &match?({:error, _}, &1))

      assert oks == 1, "expected one acceptance, got #{inspect(results)}"
      assert errors == 1
      assert hole_result_count_for_round!(fixture.round.id) == 2
      assert hole_submission_count_for_round!(fixture.round.id) == 1
      assert Ash.get!(PlayingGroup, fixture.group.id, authorize?: false).scoring_revision == 1
    after
      Sandbox.unboxed_run(Repo, fn ->
        remove_gls34_submit_audit_barrier_trigger!()
      end)

      cleanup_committed_scoring_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "SubmitGroupHole holds shared locks before HandoverGroupRole proceeds (case A)" do
    fixture = setup_committed_scoring_race_fixture!()
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 15_000

    Sandbox.unboxed_run(Repo, fn ->
      install_gls34_submit_audit_barrier_trigger!()
    end)

    try do
      lock_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.query!("SELECT pg_advisory_lock($1)", [@advisory_submit_audit])
            send(parent, {:gls34_advisory_held, pg_backend_pid!()})

            receive do
              :gls34_release_advisory ->
                Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_submit_audit])
            end
          end)
        end)

      assert_receive {:gls34_advisory_held, _}, 5_000

      submit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            submit_pid = pg_backend_pid!()
            send(parent, {:gls34_submit_started, submit_pid})
            player_submit_command!(fixture)
          end)
        end)

      assert_receive {:gls34_submit_started, submit_pid}, 10_000
      await_backend_advisory_wait!(submit_pid, deadline)

      handover =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handover_pid = pg_backend_pid!()
            send(parent, {:gls34_handover_started, handover_pid})

            HandoverGroupRole.run(
              fixture.admin,
              fixture.event.id,
              fixture.round.id,
              fixture.group.id,
              fixture.successor_entry_id,
              :primary_scorer
            )
          end)
        end)

      assert_receive {:gls34_handover_started, handover_pid}, 10_000

      await_blocked_by!(
        handover_pid,
        submit_pid,
        System.monotonic_time(:millisecond) + 10_000
      )

      send(lock_holder.pid, :gls34_release_advisory)

      assert {:ok, _receipt} = Task.await(submit, 20_000)
      assert {:ok, successor} = Task.await(handover, 20_000)
      Task.await(lock_holder, 10_000)

      assert successor.round_entry_id == fixture.successor_entry_id
      assert successor.assignment_version == fixture.assignment_version + 1
      assert hole_submission_count_for_round!(fixture.round.id) == 1
      assert hole_result_count_for_round!(fixture.round.id) == 2
      assert Ash.get!(PlayingGroup, fixture.group.id, authorize?: false).scoring_revision == 1

      handed_over =
        GroupRoleAssignment
        |> Ash.get!(fixture.assignment_id, authorize?: false)

      assert handed_over.state == :handed_over
    after
      Sandbox.unboxed_run(Repo, fn ->
        remove_gls34_submit_audit_barrier_trigger!()
      end)

      cleanup_committed_scoring_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "HandoverGroupRole blocks stale SubmitGroupHole after authority changes (case B)" do
    fixture = setup_committed_scoring_race_fixture!()
    parent = self()
    deadline = System.monotonic_time(:millisecond) + 15_000

    Sandbox.unboxed_run(Repo, fn ->
      install_gls34_handover_audit_barrier_trigger!()
    end)

    try do
      lock_holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.query!("SELECT pg_advisory_lock($1)", [@advisory_handover_audit])
            send(parent, {:gls34_handover_lock_held, pg_backend_pid!()})

            receive do
              :gls34_release_handover_advisory ->
                Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_handover_audit])
            end
          end)
        end)

      assert_receive {:gls34_handover_lock_held, _}, 5_000

      handover =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handover_pid = pg_backend_pid!()
            send(parent, {:gls34_handover_started, handover_pid})

            HandoverGroupRole.run(
              fixture.admin,
              fixture.event.id,
              fixture.round.id,
              fixture.group.id,
              fixture.successor_entry_id,
              :primary_scorer
            )
          end)
        end)

      assert_receive {:gls34_handover_started, handover_pid}, 10_000
      await_backend_advisory_wait!(handover_pid, deadline)

      submit =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            submit_pid = pg_backend_pid!()
            send(parent, {:gls34_submit_started, submit_pid})
            player_submit_command!(fixture)
          end)
        end)

      assert_receive {:gls34_submit_started, submit_pid}, 10_000

      await_blocked_by!(
        submit_pid,
        handover_pid,
        System.monotonic_time(:millisecond) + 10_000
      )

      send(lock_holder.pid, :gls34_release_handover_advisory)

      assert {:ok, successor} = Task.await(handover, 20_000)
      assert {:error, :stale_role_assignment} = Task.await(submit, 20_000)
      Task.await(lock_holder, 10_000)

      assert successor.assignment_version == fixture.assignment_version + 1
      assert hole_submission_count_for_round!(fixture.round.id) == 0
      assert hole_result_count_for_round!(fixture.round.id) == 0
      assert Ash.get!(PlayingGroup, fixture.group.id, authorize?: false).scoring_revision == 0
    after
      Sandbox.unboxed_run(Repo, fn ->
        remove_gls34_handover_audit_barrier_trigger!()
      end)

      cleanup_committed_scoring_fixture!(fixture)
    end
  end

  test "withdrawn participant is excluded from the next required result set" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    [withdrawn, active] = setup.entries

    set_participation_status!(withdrawn.id, :withdrawn)

    hole_two = hole_at_revision!(setup, 1)
    active_only = holed_out_results([active], 4)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_two, 1, active_only)
             )

    assert hole_result_count_for_entry!(withdrawn.id) == 1
    assert hole_result_count_for_entry!(active.id) == 2
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 2
  end

  test "disqualified participant is excluded from the next required result set" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    [disqualified, active] = setup.entries
    set_participation_status!(disqualified.id, :disqualified)

    hole_two = hole_at_revision!(setup, 1)

    assert {:ok, _} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_two, 1, holed_out_results([active], 4))
             )

    assert hole_result_count_for_entry!(disqualified.id) == 1
    assert hole_result_count_for_entry!(active.id) == 2
  end

  test "forged progression context cannot bypass durable scorecard completion guard" do
    setup = setup_submit_fixture!(2)
    entry = hd(setup.entries)

    card =
      Scorecard
      |> Changeset.for_create(:create_internal, %{
        round_id: setup.round.id,
        round_entry_id: entry.id
      })
      |> Ash.create!(authorize?: false)

    batch = make_ref()

    previous =
      Process.put({GolfScoring.Scoring.Services.SubmitGroupHole, :progression_batch}, batch)

    ctx = %{
      submit_group_hole_progression: %{
        playing_group_id: setup.group.id,
        operation: :mark_complete,
        record_id: card.id,
        batch: batch
      }
    }

    try do
      assert {:error, %Ash.Error.Invalid{}} =
               card
               |> Changeset.for_update(:mark_complete_internal, %{})
               |> Ash.Changeset.set_context(ctx)
               |> Ash.update(authorize?: false)

      group = Ash.get!(PlayingGroup, setup.group.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               group
               |> Changeset.for_update(:mark_group_finished, %{})
               |> Ash.Changeset.set_context(
                 Map.put(ctx, :submit_group_hole_progression, %{
                   playing_group_id: setup.group.id,
                   operation: :mark_group_finished,
                   record_id: setup.group.id,
                   batch: batch
                 })
               )
               |> Ash.update(authorize?: false)
    after
      if previous,
        do:
          Process.put(
            {GolfScoring.Scoring.Services.SubmitGroupHole, :progression_batch},
            previous
          ),
        else: Process.delete({GolfScoring.Scoring.Services.SubmitGroupHole, :progression_batch})
    end
  end

  test "round not in scoring_open rejects without mutation" do
    setup = setup_submit_fixture!(2)
    set_round_state!(setup.round, :ready)
    hole_id = expected_hole_id!(setup)

    assert {:error, {:invalid_round_state, "ready"}} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    assert hole_submission_count_for_round!(setup.round.id) == 0
  end

  test "playing group in attention_required rejects without mutation" do
    setup = setup_submit_fixture!(2)

    Repo.query!("UPDATE playing_groups SET state = 'attention_required' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(setup.group.id)
    ])

    hole_id = expected_hole_id!(setup)

    assert {:error, {:invalid_group_state, :attention_required}} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )

    assert hole_submission_count_for_round!(setup.round.id) == 0
  end

  test "duplicate round_entry_id in results is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    entry = hd(setup.entries)

    results = [
      %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 4},
      %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
    ]

    assert {:error, :duplicate_result_entry} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, results)
             )
  end

  test "blank outcome is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [bad | _] = setup.entries

    results =
      holed_out_results(setup.entries, 4, %{bad.id => %{outcome: nil}})

    assert {:error, :invalid_result} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, results)
             )
  end

  test "unsupported outcome is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [bad | _] = setup.entries

    results =
      holed_out_results(setup.entries, 4, %{bad.id => %{outcome: :skipped}})

    assert {:error, :invalid_result} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, results)
             )
  end

  for invalid_outcome <- ["skipped", "", "bogus"] do
    test "string outcome #{invalid_outcome} is rejected without raising" do
      setup = setup_submit_fixture!(2)
      hole_id = expected_hole_id!(setup)

      command =
        string_results_command(
          setup,
          hole_id,
          0,
          unquote(invalid_outcome),
          setup.entries
        )

      assert {:error, :invalid_result} =
               SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
    end
  end

  test "holed_out with nil gross_strokes is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [bad | _] = setup.entries

    results =
      holed_out_results(setup.entries, 4, %{bad.id => %{gross_strokes: nil}})

    assert {:error, :invalid_gross_strokes} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, results)
             )
  end

  test "holed_out with zero gross_strokes is rejected" do
    setup = setup_submit_fixture!(2)
    hole_id = expected_hole_id!(setup)
    [bad | _] = setup.entries

    results =
      holed_out_results(setup.entries, 4, %{bad.id => %{gross_strokes: 0}})

    assert {:error, :invalid_gross_strokes} =
             SubmitGroupHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, results)
             )
  end

  test "unassigned staff user is forbidden" do
    setup = setup_submit_fixture!(2)
    stranger = create_staff_user!()
    hole_id = expected_hole_id!(setup)

    assert {:error, :forbidden} =
             SubmitGroupHole.run(
               stranger,
               setup.event.id,
               setup.round.id,
               base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
             )
  end

  test "player submit rejects nil role_assignment_version" do
    setup = setup_submit_fixture!(2)
    scorer = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    hole_id = expected_hole_id!(setup)
    command = base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))

    assert {:error, :role_assignment_version_required} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  test "player submit rejects zero role_assignment_version" do
    setup = setup_submit_fixture!(2)
    scorer = hd(setup.entries)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    hole_id = expected_hole_id!(setup)

    command =
      base_command(setup, hole_id, 0, holed_out_results(setup.entries, 4))
      |> Map.put(:role_assignment_version, 0)

    assert {:error, :role_assignment_version_required} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, command)
  end

  defp setup_shotgun_fixture!(start_play_order),
    do: PaperRecoveryFixtures.setup_shotgun_fixture!(start_play_order)

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

  defp setup_committed_scoring_race_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      setup = setup_submit_fixture!(2)
      [scorer, successor] = setup.entries

      {:ok, %{grant: grant}} =
        Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

      assignment =
        GroupRoleAssignment
        |> Ash.Query.filter(
          playing_group_id == ^setup.group.id and round_entry_id == ^scorer.id and
            role == :primary_scorer and state == :active
        )
        |> Ash.read_one!(authorize?: false)

      Map.merge(setup, %{
        scorer_entry_id: scorer.id,
        successor_entry_id: successor.id,
        grant: grant,
        assignment_id: assignment.id,
        assignment_version: assignment.assignment_version
      })
    end)
  end

  defp player_submit_command!(fixture) do
    command =
      base_command(fixture, expected_hole_id!(fixture), 0, holed_out_results(fixture.entries, 4))
      |> Map.put(:role_assignment_version, fixture.assignment_version)

    SubmitGroupHole.run(fixture.grant, fixture.event.id, fixture.round.id, command)
  end

  defp issue_group_scorer_grant!(fixture, scorer_entry) do
    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(
               fixture.admin,
               fixture.event.id,
               scorer_entry.player_id
             )

    grant
  end

  defp active_primary_assignment!(playing_group_id) do
    GroupRoleAssignment
    |> Ash.Query.filter(playing_group_id == ^playing_group_id and role == :primary_scorer)
    |> Ash.read_one!(authorize?: false)
  end

  defp cleanup_committed_scoring_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      round = Ecto.UUID.dump!(fixture.round.id)
      event = Ecto.UUID.dump!(fixture.event.id)
      staff = Ecto.UUID.dump!(fixture.admin.id)

      player_ids =
        Repo.query!("SELECT player_id::text FROM round_entries WHERE round_id = $1::uuid", [round]).rows
        |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

      for table_query <- [
            {"DELETE FROM hole_results WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM hole_submissions WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM audit_events WHERE context->>'round_id' = $1", [fixture.round.id]},
            {"DELETE FROM scorecards WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM mystery_reveals WHERE mystery_hole_rule_id IN (SELECT id FROM mystery_hole_rules WHERE round_id = $1::uuid)",
             [round]},
            {"DELETE FROM mystery_hole_rules WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM scoring_tracks WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
             [round]},
            {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM competition_sides WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM group_role_assignments WHERE playing_group_id IN (SELECT id FROM playing_groups WHERE round_id = $1::uuid)",
             [round]},
            {"DELETE FROM round_entries WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM playing_groups WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_competitions WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
             [round]},
            {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_holes WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM rounds WHERE id = $1::uuid", [round]},
            {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid",
             [Ecto.UUID.dump!(fixture.tee_profile.id)]},
            {"DELETE FROM tee_sets WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.tee_set.id)]},
            {"DELETE FROM course_holes WHERE course_id = $1::uuid",
             [Ecto.UUID.dump!(fixture.course.id)]},
            {"DELETE FROM courses WHERE id = $1::uuid", [Ecto.UUID.dump!(fixture.course.id)]},
            {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [event]},
            {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [event]},
            {"DELETE FROM events WHERE id = $1::uuid", [event]},
            {"DELETE FROM staff_users WHERE id = $1::uuid", [staff]}
          ] do
        {sql, args} = table_query
        Repo.query!(sql, args)
      end

      for player_id <- player_ids do
        Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(player_id)])
      end
    end)
  end

  defp pg_backend_pid! do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp await_blocked_by!(waiting_pid, blocking_pid, deadline) do
    [[blocked?]] =
      Repo.query!(
        "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))",
        [blocking_pid, waiting_pid]
      ).rows

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected PostgreSQL blocking between #{waiting_pid} and #{blocking_pid}")

      true ->
        Process.sleep(5)
        await_blocked_by!(waiting_pid, blocking_pid, deadline)
    end
  end

  defp await_backend_advisory_wait!(backend_pid, deadline) do
    {wait_type, wait_event} =
      Sandbox.unboxed_run(Repo, fn ->
        case Repo.query!(
               "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
               [backend_pid]
             ).rows do
          [[wait_type, wait_event]] -> {wait_type, wait_event}
          _ -> {nil, nil}
        end
      end)

    cond do
      wait_type == "Lock" and wait_event == "advisory" ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "expected backend #{backend_pid} to wait on advisory lock before proceeding, got wait_event_type=#{inspect(wait_type)} wait_event=#{inspect(wait_event)}"
        )

      true ->
        Process.sleep(5)
        await_backend_advisory_wait!(backend_pid, deadline)
    end
  end

  defp remove_gls35_reveal_insert_barrier_trigger! do
    Repo.query!("""
    DROP TRIGGER IF EXISTS gls35_wait_before_mystery_reveal_insert_trigger
    ON mystery_reveals
    """)

    Repo.query!("DROP FUNCTION IF EXISTS gls35_wait_before_mystery_reveal_insert()")
  end

  defp install_gls35_reveal_insert_barrier_trigger! do
    remove_gls35_reveal_insert_barrier_trigger!()

    Repo.query!("""
    CREATE FUNCTION gls35_wait_before_mystery_reveal_insert()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      PERFORM pg_advisory_xact_lock(#{@advisory_mystery_reveal_insert});
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls35_wait_before_mystery_reveal_insert_trigger
    BEFORE INSERT ON mystery_reveals
    FOR EACH ROW EXECUTE FUNCTION gls35_wait_before_mystery_reveal_insert()
    """)
  end

  defp install_gls34_reject_submit_audit_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls34_reject_submit_group_hole_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'submit_group_hole' THEN
        RAISE EXCEPTION 'gls34 simulated submit_group_hole audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls34_reject_submit_group_hole_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls34_reject_submit_group_hole_audit()
    """)
  end

  defp remove_gls34_reject_submit_audit_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls34_reject_submit_group_hole_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls34_reject_submit_group_hole_audit()")
  end

  defp install_gls34_submit_audit_barrier_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls34_barrier_submit_group_hole_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'submit_group_hole' THEN
        PERFORM pg_advisory_lock(9034034);
        PERFORM pg_advisory_unlock(9034034);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls34_barrier_submit_group_hole_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls34_barrier_submit_group_hole_audit()
    """)
  end

  defp remove_gls34_submit_audit_barrier_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls34_barrier_submit_group_hole_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls34_barrier_submit_group_hole_audit()")
  end

  defp install_gls34_handover_audit_barrier_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls34_barrier_handover_group_role_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'handover_group_role' THEN
        PERFORM pg_advisory_lock(9034035);
        PERFORM pg_advisory_unlock(9034035);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls34_barrier_handover_group_role_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls34_barrier_handover_group_role_audit()
    """)
  end

  defp remove_gls34_handover_audit_barrier_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls34_barrier_handover_group_role_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls34_barrier_handover_group_role_audit()")
  end

  defp set_participation_status!(entry_id, status) do
    Repo.query!("UPDATE round_entries SET participation_status = $1 WHERE id = $2::uuid", [
      Atom.to_string(status),
      Ecto.UUID.dump!(entry_id)
    ])
  end

  defp hole_result_count_for_entry!(entry_id) do
    Repo.query!(
      """
      SELECT count(*)::int
      FROM hole_results hr
      INNER JOIN scorecards sc ON sc.id = hr.scorecard_id
      WHERE sc.round_entry_id = $1::uuid
      """,
      [Ecto.UUID.dump!(entry_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp setup_submit_fixture!(player_count),
    do: PaperRecoveryFixtures.setup_submit_fixture!(player_count)

  defp configure_single_group_mystery!(setup),
    do: PaperRecoveryFixtures.configure_single_group_mystery!(setup)

  defp setup_two_group_mystery_fixture!,
    do: PaperRecoveryFixtures.setup_two_group_mystery_fixture!()

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

  defp string_results_command(setup, round_hole_id, revision, invalid_outcome, entries) do
    [first | rest] = entries

    results =
      [
        %{
          "round_entry_id" => first.id,
          "outcome" => invalid_outcome,
          "gross_strokes" => 4
        }
        | Enum.map(rest, fn entry ->
            %{
              "round_entry_id" => entry.id,
              "outcome" => "holed_out",
              "gross_strokes" => 4
            }
          end)
      ]

    %{
      "client_submission_id" => Ecto.UUID.generate(),
      "playing_group_id" => setup.group.id,
      "round_hole_id" => round_hole_id,
      "expected_group_score_revision" => revision,
      "results" => results,
      "captured_at" => DateTime.utc_now()
    }
  end

  defp scorecard_facts_for_round!(round_id) do
    Scorecard
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn card ->
      %{id: card.id, round_entry_id: card.round_entry_id, state: card.state}
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp catalog_entity_exists?(table, id)
       when table in [:courses, :tee_sets, :tee_rating_profiles] do
    Repo.query!(
      "SELECT exists(SELECT 1 FROM #{table} WHERE id = $1::uuid)",
      [Ecto.UUID.dump!(id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp course_hole_count!(course_id) do
    Repo.query!(
      "SELECT count(*)::int FROM course_holes WHERE course_id = $1::uuid",
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp holed_out_results(entries, strokes, overrides \\ %{}) do
    Enum.map(entries, fn entry ->
      %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: strokes}
      |> Map.merge(Map.get(overrides, entry.id, %{}))
    end)
  end

  defp audit_count_for_round!(round_id) do
    round_id = to_string(round_id)

    Repo.query!(
      """
      SELECT count(*)::int FROM audit_events
      WHERE action = 'submit_group_hole' AND context->>'round_id' = $1
      """,
      [round_id]
    ).rows
    |> hd()
    |> hd()
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

  defp mystery_reveal_count_for_rule!(rule_id) do
    Repo.query!(
      "SELECT count(*)::int FROM mystery_reveals WHERE mystery_hole_rule_id = $1::uuid",
      [Ecto.UUID.dump!(rule_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp force_mystery_reveal_insert_failure! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls35_fail_mystery_reveal_insert()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      RAISE EXCEPTION 'GLS-35 forced late MysteryReveal insert failure';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls35_fail_mystery_reveal_insert_trigger
    BEFORE INSERT ON mystery_reveals
    FOR EACH ROW EXECUTE FUNCTION gls35_fail_mystery_reveal_insert()
    """)
  end

  defp hole_result_count_for_round!(round_id) do
    HoleResult
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end

  defp set_round_state!(round, state),
    do: PaperRecoveryFixtures.set_round_state!(round, state)

  defp create_event!, do: PaperRecoveryFixtures.create_event!()

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
end
