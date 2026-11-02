defmodule GolfScoring.Competition.ReadinessAuditTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.RoundHole
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.AssignRoundTee
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.CreateCompetitionSide
  alias GolfScoring.Competition.Services.SetSideMembership
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoring.Scoring.HandicapSnapshot

  @password "GLS-77 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls77_email_prefix, "gls77-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls77_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "ready tee assignment audits actual changes and rolls back when the audit fails" do
    setup = setup_tee_fixture!()

    %{
      event: event,
      round: round,
      admin: admin,
      entry: entry,
      snapshot_a: snapshot_a,
      snapshot_b: snapshot_b
    } = setup

    assert {:ok, draft_entry} =
             AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot_a.id)

    assert draft_entry.round_tee_profile_snapshot_id == snapshot_a.id
    assert audit_events(round.id, "assign_round_tee") == []

    set_round_state!(round, :ready)

    assert {:ok, round_competition} =
             ConfigureRoundCompetition.run(admin, event.id, round.id, %{
               solo_sides_permitted: true
             })

    assert {:ok, _confirmed_snapshot} =
             Scoring.confirm_handicap_input(
               admin,
               event.id,
               round.id,
               entry.id,
               %{source_handicap_index: Decimal.new("10.0")}
             )

    assert {:ok, built_snapshot_a} =
             Scoring.build_handicap_snapshot(
               entry.id,
               course_handicap_attrs!(Decimal.new("10.0"), snapshot_a)
             )

    competition_handicap_attrs_a =
      playing_handicap_attrs!(built_snapshot_a, round_competition.handicap_allowance_percent)

    assert {:ok, competition_handicap_a} =
             Scoring.build_competition_handicap(
               entry.id,
               round_competition.id,
               competition_handicap_attrs_a
             )

    before_tee_change_snapshot = handicap_snapshot!(entry.id)

    before_tee_change_competition_handicaps =
      competition_handicap_facts(entry.id, round_competition.id)

    assert before_tee_change_snapshot.built_at

    assert before_tee_change_competition_handicaps == [
             {competition_handicap_a.id, competition_handicap_a.playing_handicap}
           ]

    assert {:ok, ready_entry} =
             AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot_b.id)

    assert ready_entry.round_tee_profile_snapshot_id == snapshot_b.id

    assert_readiness_audit!(setup, "assign_round_tee", %{
      "round_entry_id" => entry.id,
      "round_tee_profile_snapshot_id" => %{"from" => snapshot_a.id, "to" => snapshot_b.id}
    })

    invalidated_snapshot = handicap_snapshot!(entry.id)
    assert invalidated_snapshot.id == before_tee_change_snapshot.id
    assert invalidated_snapshot.round_tee_profile_snapshot_id == snapshot_b.id
    assert is_nil(invalidated_snapshot.built_at)
    assert is_nil(invalidated_snapshot.course_handicap_unrounded)
    assert is_nil(invalidated_snapshot.course_handicap_rounded)
    assert competition_handicap_facts(entry.id, round_competition.id) == []

    assert {:ok, built_snapshot_b} =
             Scoring.build_handicap_snapshot(
               entry.id,
               course_handicap_attrs!(Decimal.new("10.0"), snapshot_b)
             )

    competition_handicap_attrs_b =
      playing_handicap_attrs!(built_snapshot_b, round_competition.handicap_allowance_percent)

    assert {:ok, competition_handicap_b} =
             Scoring.build_competition_handicap(
               entry.id,
               round_competition.id,
               competition_handicap_attrs_b
             )

    before_entry = Ash.get!(GolfScoring.Competition.RoundEntry, entry.id, authorize?: false)
    before_snapshot = handicap_snapshot!(entry.id)
    before_competition_handicaps = competition_handicap_facts(entry.id, round_competition.id)
    before_audit_count = length(audit_events(round.id, "assign_round_tee"))

    assert before_snapshot.id == built_snapshot_b.id
    assert before_snapshot.round_tee_profile_snapshot_id == snapshot_b.id
    assert before_snapshot.confirmed_at
    assert before_snapshot.built_at
    assert before_snapshot.course_handicap_unrounded
    assert before_snapshot.course_handicap_rounded

    assert before_competition_handicaps == [
             {competition_handicap_b.id, competition_handicap_b.playing_handicap}
           ]

    assert {:ok, same_entry} =
             AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot_b.id)

    assert same_entry.round_tee_profile_snapshot_id == snapshot_b.id
    assert same_entry.updated_at == before_entry.updated_at

    after_snapshot = handicap_snapshot!(entry.id)

    assert Map.take(after_snapshot, handicap_snapshot_evidence()) ==
             Map.take(before_snapshot, handicap_snapshot_evidence())

    after_competition_handicaps = competition_handicap_facts(entry.id, round_competition.id)
    assert after_competition_handicaps == before_competition_handicaps
    assert length(audit_events(round.id, "assign_round_tee")) == before_audit_count

    with_rejected_audit("assign_round_tee", fn ->
      assert {:error, _reason} =
               AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot_a.id)

      assert tee_snapshot_id(entry.id) == snapshot_b.id

      assert Map.take(handicap_snapshot!(entry.id), handicap_snapshot_evidence()) ==
               Map.take(before_snapshot, handicap_snapshot_evidence())

      assert competition_handicap_facts(entry.id, round_competition.id) ==
               before_competition_handicaps

      assert length(audit_events(round.id, "assign_round_tee")) == before_audit_count
    end)

    set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, :scoring_open}} =
             AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot_a.id)

    assert tee_snapshot_id(entry.id) == snapshot_b.id

    assert Map.take(handicap_snapshot!(entry.id), handicap_snapshot_evidence()) ==
             Map.take(before_snapshot, handicap_snapshot_evidence())

    assert competition_handicap_facts(entry.id, round_competition.id) ==
             before_competition_handicaps
  end

  test "ready group moves audit actual changes and roll back when the audit fails" do
    setup = setup_round_with_groups!()

    %{event: event, round: round, admin: admin, entry: entry, group_a: group_a, group_b: group_b} =
      setup

    assert {:ok, draft_entry} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_a.id)

    assert draft_entry.playing_group_id == group_a.id
    assert audit_events(round.id, "assign_entry_to_group") == []

    set_round_state!(round, :ready)

    assert {:ok, ready_entry} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_b.id)

    assert ready_entry.playing_group_id == group_b.id

    assert_readiness_audit!(setup, "assign_entry_to_group", %{
      "round_entry_id" => entry.id,
      "playing_group_id" => %{"from" => group_a.id, "to" => group_b.id}
    })

    assert {:ok, same_entry} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_b.id)

    assert same_entry.playing_group_id == group_b.id
    assert length(audit_events(round.id, "assign_entry_to_group")) == 1

    with_rejected_audit("assign_entry_to_group", fn ->
      assert {:error, _reason} =
               AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_a.id)

      assert entry_group_id(entry.id) == group_b.id
      assert length(audit_events(round.id, "assign_entry_to_group")) == 1
    end)

    set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_a.id)

    assert entry_group_id(entry.id) == group_b.id
  end

  test "ready group starts audit actual changes and roll back when the audit fails" do
    setup = setup_round_with_group_and_holes!()

    %{event: event, round: round, admin: admin, group: group, hole_a: hole_a, hole_b: hole_b} =
      setup

    assert {:ok, draft_group} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole_a.id, 1)

    assert {draft_group.starting_round_hole_id, draft_group.starting_position} == {hole_a.id, 1}
    assert audit_events(round.id, "assign_playing_group_start") == []

    set_round_state!(round, :ready)

    assert {:ok, ready_group} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole_b.id, 2)

    assert {ready_group.starting_round_hole_id, ready_group.starting_position} == {hole_b.id, 2}

    assert_readiness_audit!(setup, "assign_playing_group_start", %{
      "playing_group_id" => group.id,
      "starting_round_hole_id" => %{"from" => hole_a.id, "to" => hole_b.id},
      "starting_position" => %{"from" => 1, "to" => 2}
    })

    assert {:ok, same_group} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole_b.id, 2)

    assert {same_group.starting_round_hole_id, same_group.starting_position} == {hole_b.id, 2}
    assert length(audit_events(round.id, "assign_playing_group_start")) == 1

    with_rejected_audit("assign_playing_group_start", fn ->
      assert {:error, _reason} =
               AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole_a.id, 1)

      assert group_start(group.id) == {hole_b.id, 2}
      assert length(audit_events(round.id, "assign_playing_group_start")) == 1
    end)

    set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole_a.id, 1)

    assert group_start(group.id) == {hole_b.id, 2}
  end

  test "ready PlayingGroup creation writes one audit and rolls back when the audit fails" do
    setup = setup_round!()
    %{event: event, round: round, admin: admin} = setup

    assert {:ok, draft_group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    assert draft_group.state == :not_started
    assert audit_events(round.id, "create_playing_group") == []

    set_round_state!(round, :ready)

    assert {:ok, ready_group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    assert ready_group.state == :not_started

    assert_readiness_audit!(setup, "create_playing_group", %{
      "playing_group_id" => ready_group.id,
      "state" => %{"from" => nil, "to" => "not_started"}
    })

    group_count = playing_group_count(round.id)

    with_rejected_audit("create_playing_group", fn ->
      assert {:error, _reason} =
               Competition.create_playing_group(event.id, round.id, actor: admin)

      assert playing_group_count(round.id) == group_count
      assert length(audit_events(round.id, "create_playing_group")) == 1
    end)

    set_round_state!(round, :scoring_open)

    assert {:error, %Ash.Error.Invalid{}} =
             Competition.create_playing_group(event.id, round.id, actor: admin)

    assert playing_group_count(round.id) == group_count
  end

  test "ready CompetitionSide creation writes one audit and rolls back when the audit fails" do
    setup = setup_round_with_competition!()
    %{event: event, round: round, admin: admin, competition: competition} = setup

    assert {:ok, draft_side} =
             CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

    assert draft_side.formation == :partnership
    assert audit_events(round.id, "create_competition_side") == []

    set_round_state!(round, :ready)

    assert {:ok, ready_side} =
             CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :solo)

    assert ready_side.formation == :solo

    assert_readiness_audit!(setup, "create_competition_side", %{
      "competition_side_id" => ready_side.id,
      "round_competition_id" => competition.id,
      "formation" => %{"from" => nil, "to" => "solo"}
    })

    before_counts = competition_side_counts(competition.id)

    with_rejected_audit("create_competition_side", fn ->
      assert {:error, _reason} =
               CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

      assert competition_side_counts(competition.id) == before_counts
      assert length(audit_events(round.id, "create_competition_side")) == 1
    end)

    set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

    assert competition_side_counts(competition.id) == before_counts
  end

  test "ready SetSideMembership audit remains transactional and identifies its actor and Round" do
    setup = setup_round_with_competition!()
    %{event: event, round: round, admin: admin, competition: competition} = setup

    {:ok, side} =
      CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

    entries = for _ <- 1..2, do: add_entry!(event, round, admin)
    set_round_state!(round, :ready)

    assert {:ok, %{memberships: memberships}} =
             SetSideMembership.run(
               admin,
               event.id,
               round.id,
               competition.id,
               side.id,
               Enum.map(entries, & &1.id)
             )

    assert length(memberships) == 2

    assert [event_audit] = audit_events(round.id, "set_side_membership")
    assert event_audit.actor_staff_user_id == admin.id
    assert event_audit.target_type == "Round"
    assert event_audit.target_id == round.id
    assert event_audit.context["round_id"] == round.id
  end

  defp setup_round! do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    %{event: event, round: round, admin: admin, course: course}
  end

  defp setup_tee_fixture! do
    setup = setup_round!()
    %{event: event, round: round, admin: admin, course: course} = setup

    holes = create_eighteen_holes!(event, admin, course)
    tee_set_a = create_tee_set!(event, admin, course, "White")
    tee_set_b = create_tee_set!(event, admin, course, "Red")
    profile_a = create_profile!(event, admin, tee_set_a, holes, "Men")
    profile_b = create_profile!(event, admin, tee_set_b, holes, "Men")

    {:ok, _round_holes} = ConfigureRoundLayout.run(admin, round.id, Enum.map(holes, & &1.id))

    {:ok, [snapshot_a, snapshot_b]} =
      SnapshotRoundTeeProfiles.run(admin, round.id, [profile_a.id, profile_b.id])

    entry = add_entry!(event, round, admin)

    Map.merge(setup, %{
      entry: entry,
      snapshot_a: snapshot_a,
      snapshot_b: snapshot_b
    })
  end

  defp setup_round_with_groups! do
    setup = setup_round!()
    %{event: event, round: round, admin: admin} = setup
    {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)

    Map.merge(setup, %{group_a: group_a, group_b: group_b, entry: entry})
  end

  defp setup_round_with_group_and_holes! do
    setup = setup_round!()
    %{event: event, round: round, admin: admin, course: course} = setup

    course_holes =
      for number <- 1..2 do
        {:ok, hole} =
          GolfCatalog.configure_course_hole(
            event.id,
            %{course_id: course.id, hole_number: number},
            actor: admin
          )

        hole
      end

    [hole_a, hole_b] =
      Enum.map(course_holes, fn course_hole ->
        RoundHole
        |> Changeset.for_create(:insert_layout_row, %{
          round_id: round.id,
          course_id: course.id,
          course_hole_id: course_hole.id,
          play_order: course_hole.hole_number,
          display_hole_number: 12 + course_hole.hole_number
        })
        |> Ash.create!(authorize?: false)
      end)

    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    Map.merge(setup, %{group: group, hole_a: hole_a, hole_b: hole_b})
  end

  defp setup_round_with_competition! do
    setup = setup_round!()
    %{event: event, round: round, admin: admin} = setup

    {:ok, competition} =
      ConfigureRoundCompetition.run(admin, event.id, round.id, %{solo_sides_permitted: true})

    Map.put(setup, :competition, competition)
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
    email =
      "#{Process.get(:gls77_email_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
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
        %{name: "GLS-77 #{System.unique_integer([:positive])}", location: "ZA"},
        actor: admin
      )

    course
  end

  defp create_eighteen_holes!(event, admin, course) do
    for number <- 1..18 do
      {:ok, hole} =
        GolfCatalog.configure_course_hole(
          event.id,
          %{course_id: course.id, hole_number: number},
          actor: admin
        )

      hole
    end
  end

  defp create_tee_set!(event, admin, course, name) do
    {:ok, tee_set} =
      GolfCatalog.configure_tee_set(
        event.id,
        %{course_id: course.id, name: name},
        actor: admin
      )

    tee_set
  end

  defp create_profile!(event, admin, tee_set, holes, label) do
    hole_ratings =
      Enum.map(holes, fn hole ->
        %{
          course_hole_id: hole.id,
          par: 4,
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
          course_rating: Decimal.new("72.0"),
          slope_rating: 113,
          total_par: 72,
          hole_ratings: hole_ratings
        },
        actor: admin
      )

    profile
  end

  defp add_entry!(event, round, admin) do
    player =
      GolfScoring.Competition.Player
      |> Changeset.for_create(:create_internal, %{
        first_name: "Pat",
        surname: "GLS77-#{System.unique_integer([:positive])}"
      })
      |> Ash.create!(authorize?: false)

    {:ok, entry} = Competition.add_round_entry(event.id, round.id, player.id, actor: admin)
    entry
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])
  end

  defp audit_events(round_id, action) do
    Repo.query!(
      """
      SELECT action, actor_staff_user_id::text, target_type, target_id::text, context, changes
      FROM audit_events
      WHERE target_id = $1::uuid AND action = $2
      ORDER BY occurred_at, id
      """,
      [Ecto.UUID.dump!(round_id), action]
    ).rows
    |> Enum.map(fn [action, actor_id, target_type, target_id, context, changes] ->
      %{
        action: action,
        actor_staff_user_id: Ecto.UUID.cast!(actor_id),
        target_type: target_type,
        target_id: Ecto.UUID.cast!(target_id),
        context: context,
        changes: changes
      }
    end)
  end

  defp assert_readiness_audit!(setup, action, expected_changes) do
    %{event: event, round: round, admin: admin} = setup
    assert [audit] = audit_events(round.id, action)
    assert audit.action == action
    assert audit.actor_staff_user_id == admin.id
    assert audit.target_type == "round"
    assert audit.target_id == round.id
    assert audit.context["event_id"] == event.id
    assert audit.context["round_id"] == round.id
    assert audit.changes == expected_changes
  end

  defp with_rejected_audit(action, fun) do
    Repo.query!("""
    CREATE FUNCTION gls77_reject_audit_insert() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      rejected_action text := current_setting('gls77.reject_audit_action', true);
    BEGIN
      IF NEW.action = rejected_action THEN
        RAISE EXCEPTION 'simulated GLS-77 audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls77_reject_audit_insert
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls77_reject_audit_insert()
    """)

    Repo.query!("SELECT set_config('gls77.reject_audit_action', $1, true)", [action])

    try do
      fun.()
    after
      Repo.query!("DROP TRIGGER gls77_reject_audit_insert ON audit_events")
      Repo.query!("DROP FUNCTION gls77_reject_audit_insert()")
    end
  end

  defp tee_snapshot_id(entry_id) do
    [[snapshot_id]] =
      Repo.query!(
        "SELECT round_tee_profile_snapshot_id::text FROM round_entries WHERE id = $1::uuid",
        [Ecto.UUID.dump!(entry_id)]
      ).rows

    Ecto.UUID.cast!(snapshot_id)
  end

  defp course_handicap_attrs!(handicap_index, tee) do
    {:ok, attrs} =
      CourseHandicap.calculate(
        handicap_index,
        tee.slope_rating,
        tee.course_rating,
        tee.applicable_par
      )

    attrs
  end

  defp playing_handicap_attrs!(snapshot, allowance_percent) do
    {:ok, attrs} =
      PlayingHandicap.calculate(snapshot.course_handicap_unrounded, allowance_percent)

    Map.merge(attrs, %{policy_identifier: "gls77_readiness_audit_test", allowance_applied: true})
  end

  defp handicap_snapshot!(entry_id) do
    HandicapSnapshot
    |> Ash.Query.filter(round_entry_id == ^entry_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp handicap_snapshot_evidence do
    [
      :id,
      :round_tee_profile_snapshot_id,
      :confirmed_at,
      :confirmed_by_staff_user_id,
      :built_at,
      :course_rating,
      :slope_rating,
      :applicable_par,
      :course_handicap_unrounded,
      :course_handicap_rounded,
      :updated_at
    ]
  end

  defp competition_handicap_facts(entry_id, round_competition_id) do
    Repo.query!(
      """
      SELECT id::text, playing_handicap
      FROM competition_handicaps
      WHERE round_entry_id = $1::uuid AND round_competition_id = $2::uuid
      ORDER BY id
      """,
      [Ecto.UUID.dump!(entry_id), Ecto.UUID.dump!(round_competition_id)]
    ).rows
    |> Enum.map(fn [id, playing_handicap] -> {Ecto.UUID.cast!(id), playing_handicap} end)
  end

  defp entry_group_id(entry_id) do
    [[group_id]] =
      Repo.query!("SELECT playing_group_id::text FROM round_entries WHERE id = $1::uuid", [
        Ecto.UUID.dump!(entry_id)
      ]).rows

    Ecto.UUID.cast!(group_id)
  end

  defp group_start(group_id) do
    [[hole_id, position]] =
      Repo.query!(
        "SELECT starting_round_hole_id::text, starting_position FROM playing_groups WHERE id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    {Ecto.UUID.cast!(hole_id), position}
  end

  defp playing_group_count(round_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM playing_groups WHERE round_id = $1::uuid", [
        Ecto.UUID.dump!(round_id)
      ]).rows

    count
  end

  defp competition_side_counts(round_competition_id) do
    [[side_count, result_count]] =
      Repo.query!(
        """
        SELECT count(DISTINCT side.id), count(result.id)
        FROM competition_sides AS side
        LEFT JOIN competition_side_results AS result
          ON result.competition_side_id = side.id
        WHERE side.round_competition_id = $1::uuid
        """,
        [Ecto.UUID.dump!(round_competition_id)]
      ).rows

    {side_count, result_count}
  end
end
