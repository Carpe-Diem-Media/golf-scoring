defmodule GolfScoring.Competition.GroupRoleAssignmentTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignGroupRole
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Competition.Services.SetSideMembership
  alias GolfScoring.Repo

  @password "GLS-20 synthetic staff passphrase 2026"
  @active_role_index "group_role_assignments_one_active_per_group_role_index"
  @active_entry_index "group_role_assignments_one_active_entry_per_group_index"

  setup do
    Process.put(:gls20_email_prefix, "gls20-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls20_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "GroupRoleAssignment is registered without generic public CRUD" do
    assert GroupRoleAssignment in Ash.Domain.Info.resources(Competition)
    refute Info.action(GroupRoleAssignment, :create)
    refute Info.action(GroupRoleAssignment, :update)
    refute Info.action(GroupRoleAssignment, :destroy)
    assert Info.action(GroupRoleAssignment, :create_internal)
    assert Info.action(GroupRoleAssignment, :mark_handed_over_internal)
    assert Info.action(GroupRoleAssignment, :mark_revoked_internal)
    refute function_exported?(Competition, :create_internal, 1)
  end

  test "valid primary scorer and designated verifier assignments for different entries" do
    setup = setup_group_with_entries!(2)
    [scorer_entry, verifier_entry] = setup.entries

    assert {:ok, scorer} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer_entry.id
             )

    assert scorer.role == :primary_scorer
    assert scorer.state == :active
    assert scorer.assignment_version == 1

    assert {:ok, verifier} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier_entry.id
             )

    assert verifier.role == :designated_verifier
    assert verifier.state == :active
    assert verifier.round_entry_id != scorer.round_entry_id
  end

  test "same RoundEntry cannot actively hold both roles" do
    setup = setup_group_with_entries!(1)
    entry = hd(setup.entries)

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )

    assert {:error, :round_entry_already_holds_other_active_role} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )
  end

  test "only one active holder per group and role" do
    setup = setup_group_with_entries!(2)
    [first, second] = setup.entries

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               first.id
             )

    assert {:error, :active_role_already_assigned} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               second.id
             )
  end

  test "PostgreSQL partial unique indexes enforce active role and entry distinctness" do
    setup = setup_group_with_entries!(2)
    [first, second] = setup.entries

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               first.id
             )

    duplicate_role =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO group_role_assignments
            (round_id, playing_group_id, round_entry_id, role, state, assignment_version)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'primary_scorer', 'active', 99)
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.group.id),
            Ecto.UUID.dump!(second.id)
          ]
        )
      end

    assert duplicate_role.postgres.code == :unique_violation
    assert duplicate_role.postgres.constraint == @active_role_index

    assert {:ok, verifier} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               second.id
             )

    duplicate_entry =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO group_role_assignments
            (round_id, playing_group_id, round_entry_id, role, state, assignment_version)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'designated_verifier', 'active', 99)
          """,
          [
            Ecto.UUID.dump!(setup.round.id),
            Ecto.UUID.dump!(setup.group.id),
            Ecto.UUID.dump!(first.id)
          ]
        )
      end

    assert duplicate_entry.postgres.code == :unique_violation
    assert duplicate_entry.postgres.constraint == @active_entry_index
    assert verifier.state == :active
  end

  test "cross-round and cross-group assignment references are rejected" do
    setup_a = setup_group_with_entries!(1)
    setup_b = setup_group_with_entries!(1)
    entry = hd(setup_a.entries)

    assert {:error, :playing_group_mismatch} =
             AssignGroupRole.run(
               setup_a.admin,
               setup_a.event.id,
               setup_a.round.id,
               setup_b.group.id,
               entry.id,
               :primary_scorer
             )

    assert {:error, :round_entry_mismatch} =
             AssignGroupRole.run(
               setup_a.admin,
               setup_a.event.id,
               setup_a.round.id,
               setup_a.group.id,
               hd(setup_b.entries).id,
               :primary_scorer
             )
  end

  test "RoundEntry from another PlayingGroup is rejected" do
    setup = setup_group_with_entries!(2)
    [in_group, unassigned] = setup.entries
    other_group = create_second_group!(setup)

    assert {:ok, _} =
             AssignEntryToGroup.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               unassigned.id,
               other_group.id
             )

    assert {:error, :round_entry_not_in_playing_group} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               unassigned.id
             )

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               in_group.id
             )
  end

  test "non-current starters cannot receive group roles" do
    setup = setup_group_with_entries!(1)
    entry = hd(setup.entries)

    {:ok, _} = Competition.mark_no_show(entry, actor: setup.admin)

    assert {:error, :not_current_starting_participant} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )
  end

  test "Event Admin and Competition Manager may assign; unauthorized staff may not" do
    setup = setup_group_with_entries!(2)
    entry = hd(setup.entries)
    manager = create_manager!(setup.event, setup.admin)
    outsider = create_staff_user!()

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               manager,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )

    other_entry = List.last(setup.entries)

    assert {:error, :forbidden} =
             Competition.assign_designated_verifier(
               outsider,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               other_entry.id
             )
  end

  test "no player self-selection API exists" do
    refute function_exported?(Competition, :self_select_primary_scorer, 5)
    refute function_exported?(Competition, :self_select_designated_verifier, 5)

    lib_dir = Path.expand("../../../lib", __DIR__)

    matches =
      lib_dir
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        content = File.read!(path)
        Regex.match?(~r/self_select.*group_role|player.*assign.*primary_scorer/i, content)
      end)

    assert matches == []
  end

  test "assignment after scoring opens is rejected" do
    setup = setup_group_with_entries!(1)
    entry = hd(setup.entries)
    scoring_open = set_round_state!(setup.round, :scoring_open)

    assert scoring_open.state == :scoring_open

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )
  end

  test "pre-open handover preserves history and increments assignment_version" do
    setup = setup_group_with_entries!(3)
    [holder, replacement, _] = setup.entries
    scoring_support = create_scoring_support!(setup.event, setup.admin)

    assert {:ok, original} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    assert {:ok, successor} =
             Competition.handover_primary_scorer(
               scoring_support,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    reloaded_original = Ash.get!(GroupRoleAssignment, original.id, authorize?: false)
    assert reloaded_original.state == :handed_over
    assert successor.state == :active
    assert successor.assignment_version == original.assignment_version + 1
    assert successor.round_entry_id == replacement.id

    assert {:ok, audit} =
             AuditEvent
             |> Ash.Query.filter(action == "handover_group_role")
             |> Ash.read(authorize?: false)

    assert length(audit) == 1
  end

  test "primary scorer handover is allowed during scoring_open and writes one atomic audit" do
    setup = setup_group_with_entries!(2)
    [holder, replacement] = setup.entries

    assert {:ok, original} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    set_round_state!(setup.round, :scoring_open)
    audits_before = handover_audit_count(setup.group.id)

    assert {:ok, successor} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert Ash.get!(GroupRoleAssignment, original.id, authorize?: false).state == :handed_over
    assert successor.state == :active
    assert successor.round_entry_id == replacement.id
    assert successor.assignment_version == original.assignment_version + 1
    assert handover_audit_count(setup.group.id) == audits_before + 1
  end

  test "designated verifier handover is allowed during scoring_open and preserves role separation" do
    setup = setup_group_with_entries!(3)
    [scorer_entry, verifier_entry, replacement] = setup.entries

    assert {:ok, scorer} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer_entry.id
             )

    assert {:ok, original} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier_entry.id
             )

    set_round_state!(setup.round, :scoring_open)
    audits_before = handover_audit_count(setup.group.id)

    assert {:ok, successor} =
             Competition.handover_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert Ash.get!(GroupRoleAssignment, original.id, authorize?: false).state == :handed_over
    assert successor.state == :active
    assert successor.round_entry_id == replacement.id
    assert successor.assignment_version == original.assignment_version + 1
    assert handover_audit_count(setup.group.id) == audits_before + 1

    active_assignments = active_group_assignments(setup.group.id)
    active_scorer = Enum.find(active_assignments, &(&1.role == :primary_scorer))
    active_verifier = Enum.find(active_assignments, &(&1.role == :designated_verifier))

    assert active_scorer.round_entry_id == scorer.round_entry_id
    assert active_verifier.round_entry_id == replacement.id
    refute active_scorer.round_entry_id == active_verifier.round_entry_id
  end

  test "an active participant can receive an in-play handover" do
    setup = setup_group_with_entries!(2)
    [holder, replacement] = setup.entries

    assert {:ok, _original} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    set_round_state!(setup.round, :scoring_open)
    set_participation_status!(replacement.id, :active)

    assert {:ok, successor} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert successor.round_entry_id == replacement.id
    assert successor.state == :active
  end

  test "completed, withdrawn, and disqualified participants cannot receive an in-play handover" do
    for participation_status <- [:completed, :withdrawn, :disqualified] do
      setup = setup_group_with_entries!(2)
      [holder, replacement] = setup.entries

      assert {:ok, original} =
               Competition.assign_primary_scorer(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 setup.group.id,
                 holder.id
               )

      set_round_state!(setup.round, :scoring_open)
      set_participation_status!(replacement.id, participation_status)

      assert {:error, :ineligible_handover_replacement} =
               Competition.handover_primary_scorer(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 setup.group.id,
                 replacement.id
               )

      assert Ash.get!(GroupRoleAssignment, original.id, authorize?: false).state == :active
      assert active_group_assignments(setup.group.id) |> length() == 1
      assert handover_audit_count(setup.group.id) == 0
    end
  end

  test "handover validates replacement eligibility and distinct active roles" do
    setup = setup_group_with_entries!(3)
    [scorer, verifier, third] = setup.entries

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer.id
             )

    assert {:ok, _} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier.id
             )

    assert {:error, :round_entry_already_holds_other_active_role} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier.id
             )

    assert {:error, :handover_requires_different_entry} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer.id
             )

    assert {:ok, _} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               third.id
             )
  end

  test "handover rejects scoring_closed, finalized, and cancelled rounds" do
    for round_state <- [:scoring_closed, :finalized, :cancelled] do
      setup = setup_group_with_entries!(2)
      [holder, replacement] = setup.entries

      assert {:ok, original} =
               Competition.assign_primary_scorer(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 setup.group.id,
                 holder.id
               )

      set_round_state!(setup.round, round_state)
      expected_state = Atom.to_string(round_state)

      assert {:error, {:invalid_round_state, ^expected_state}} =
               Competition.handover_primary_scorer(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 setup.group.id,
                 replacement.id
               )

      assert Ash.get!(GroupRoleAssignment, original.id, authorize?: false).state == :active
      assert active_group_assignments(setup.group.id) |> length() == 1
      assert handover_audit_count(setup.group.id) == 0
    end
  end

  test "handover in scoring_open rejects the current holder and the other active role holder" do
    setup = setup_group_with_entries!(3)
    [scorer_entry, verifier_entry, replacement] = setup.entries

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer_entry.id
             )

    assert {:ok, _} =
             Competition.assign_designated_verifier(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier_entry.id
             )

    set_round_state!(setup.round, :scoring_open)

    assert {:error, :handover_requires_different_entry} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               scorer_entry.id
             )

    assert {:error, :round_entry_already_holds_other_active_role} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               verifier_entry.id
             )

    assert {:ok, successor} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert successor.state == :active
    assert successor.round_entry_id == replacement.id
  end

  test "ready round handover remains supported" do
    setup = setup_group_with_entries!(2)
    [holder, replacement] = setup.entries

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    set_round_state!(setup.round, :ready)

    assert {:ok, successor} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert successor.round_entry_id == replacement.id
    assert successor.assignment_version == 2
  end

  test "simulated handover audit failure rolls back assignment changes" do
    setup = setup_group_with_entries!(2)
    [holder, replacement] = setup.entries

    assert {:ok, original} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    install_handover_audit_failure_trigger!()

    assert {:error, _} =
             HandoverGroupRole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id,
               :primary_scorer
             )

    drop_handover_audit_failure_trigger!()

    reloaded = Ash.get!(GroupRoleAssignment, original.id, authorize?: false)
    assert reloaded.state == :active

    active_count =
      GroupRoleAssignment
      |> Ash.Query.filter(
        playing_group_id == ^setup.group.id and role == :primary_scorer and state == :active
      )
      |> Ash.read!(authorize?: false)
      |> length()

    assert active_count == 1
    assert handover_audit_count(setup.group.id) == 0
  end

  test "revoke requires reason and preserves revoked history" do
    setup = setup_group_with_entries!(1)
    entry = hd(setup.entries)

    assert {:ok, active} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               entry.id
             )

    assert {:error, :revoke_reason_required} =
             Competition.revoke_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               "   "
             )

    assert {:ok, revoked} =
             Competition.revoke_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               "pre-open reset"
             )

    assert revoked.id == active.id
    assert revoked.state == :revoked

    assert [] =
             GroupRoleAssignment
             |> Ash.Query.filter(playing_group_id == ^setup.group.id and state == :active)
             |> Ash.read!(authorize?: false)
  end

  test "reassignment after revoke uses next assignment_version" do
    setup = setup_group_with_entries!(2)
    [first, second] = setup.entries

    assert {:ok, first_assignment} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               first.id
             )

    assert {:ok, _} =
             Competition.revoke_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               "rotate"
             )

    assert {:ok, second_assignment} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               second.id
             )

    assert second_assignment.assignment_version == first_assignment.assignment_version + 1
  end

  @tag :real_concurrency
  test "concurrent assignments cannot leave duplicate active holders" do
    email_prefix = Process.get(:gls20_email_prefix)

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_role_race_fixture!(email_prefix)
      end)

    try do
      parent = self()

      task_one =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls20_ready, :one, pg_backend_pid!()})

            receive do
              :gls20_go ->
                AssignGroupRole.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.group_id,
                  fixture.entry_one_id,
                  :primary_scorer
                )
            after
              10_000 -> flunk("GLS-20 concurrency worker one did not receive go")
            end
          end)
        end)

      task_two =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls20_ready, :two, pg_backend_pid!()})

            receive do
              :gls20_go ->
                AssignGroupRole.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.group_id,
                  fixture.entry_two_id,
                  :primary_scorer
                )
            after
              10_000 -> flunk("GLS-20 concurrency worker two did not receive go")
            end
          end)
        end)

      assert_receive {:gls20_ready, :one, pid_one}, 10_000
      assert_receive {:gls20_ready, :two, pid_two}, 10_000
      assert pid_one != pid_two

      send(task_one.pid, :gls20_go)
      send(task_two.pid, :gls20_go)

      results = [Task.await(task_one, 30_000), Task.await(task_two, 30_000)]
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, _}, &1)) == 1

      active_count =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!(
            """
            SELECT count(*)::int FROM group_role_assignments
            WHERE playing_group_id = $1::uuid AND role = 'primary_scorer' AND state = 'active'
            """,
            [Ecto.UUID.dump!(fixture.group_id)]
          ).rows
          |> hd()
          |> hd()
        end)

      assert active_count == 1
    after
      cleanup_committed_role_race_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "an old-authority consumer that locks first commits before the handover" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_handover_fixture!(Process.get(:gls20_email_prefix))
      end)

    try do
      parent = self()

      consumer =
        Task.async(fn ->
          consume_captured_authority(fixture, parent, :case_a, true)
        end)

      assert_receive {:authority_consumer_ready, :case_a, consumer_pid,
                      %{status: :current} = observation},
                     10_000

      assert observation.captured_assignment_state == "active"
      assert observation.current_assignment_id == fixture.assignment_id

      handover =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handover_pid = pg_backend_pid!()
            send(parent, {:handover_started, :case_a, handover_pid})

            HandoverGroupRole.run(
              fixture.admin,
              fixture.event_id,
              fixture.round_id,
              fixture.group_id,
              fixture.entry_two_id,
              :primary_scorer
            )
          end)
        end)

      assert_receive {:handover_started, :case_a, handover_pid}, 10_000
      refute handover_pid == consumer_pid

      try do
        await_blocked_by!(
          handover_pid,
          consumer_pid,
          System.monotonic_time(:millisecond) + 10_000
        )

        [[waiting_query]] =
          Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [handover_pid]).rows

        assert waiting_query =~ "FROM rounds"
      after
        send(consumer.pid, :release_authority_locks)
      end

      assert :current = Task.await(consumer, 15_000)
      assert {:ok, successor} = Task.await(handover, 15_000)
      assert successor.assignment_version == fixture.assignment_version + 1
      assert successor.round_entry_id == fixture.entry_two_id
    after
      cleanup_committed_role_race_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "a nested command rejects before waiting for its Round lock" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_handover_fixture!(Process.get(:gls20_email_prefix))
      end)

    parent = self()

    blocker =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT id FROM rounds WHERE id = $1::uuid FOR UPDATE", [
              Ecto.UUID.dump!(fixture.round_id)
            ])

            send(parent, :gls42a_round_locked)

            receive do
              :gls42a_release_round_lock -> :released
            after
              15_000 -> Repo.rollback(:round_lock_timeout)
            end
          end)
        end)
      end)

    assert_receive :gls42a_round_locked, 5_000

    nested_command =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            send(parent, :gls42a_nested_command_started)

            AssignPlayingGroupStart.run(
              fixture.admin,
              fixture.event_id,
              fixture.round_id,
              fixture.group_id,
              Ecto.UUID.generate(),
              1
            )
          end)
        end)
      end)

    try do
      assert_receive :gls42a_nested_command_started, 5_000

      command_result = Task.yield(nested_command, 500)

      send(blocker.pid, :gls42a_release_round_lock)
      assert {:ok, :released} = Task.await(blocker, 15_000)

      if is_nil(command_result) do
        assert {:ok, _result} = Task.yield(nested_command, 15_000)
      end

      assert {:ok, {:ok, {:error, :transaction_already_open}}} = command_result
    after
      send(blocker.pid, :gls42a_release_round_lock)
      Task.shutdown(blocker, 15_000)
      Task.shutdown(nested_command, 15_000)
      cleanup_committed_role_race_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "a consumer with old authority sees it as stale after the handover commits" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_handover_fixture!(Process.get(:gls20_email_prefix))
      end)

    try do
      parent = self()

      handover =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            handover_pid = pg_backend_pid!()

            result =
              HandoverGroupRole.run(
                fixture.admin,
                fixture.event_id,
                fixture.round_id,
                fixture.group_id,
                fixture.entry_two_id,
                :primary_scorer
              )

            send(parent, {:handover_committed, :case_b, handover_pid, result})

            receive do
              :release_handover_connection -> :ok
            after
              15_000 -> flunk("GLS-33 case B handover did not release its database connection")
            end

            result
          end)
        end)

      assert_receive {:handover_committed, :case_b, handover_pid, handover_result}, 15_000

      successor =
        try do
          assert {:ok, successor} = handover_result
          assert successor.assignment_version == fixture.assignment_version + 1

          consumer =
            Task.async(fn ->
              consume_captured_authority(fixture, parent, :case_b, false)
            end)

          assert_receive {:authority_consumer_ready, :case_b, consumer_pid,
                          %{status: :stale} = observation},
                         10_000

          refute handover_pid == consumer_pid
          assert observation.captured_assignment_state == "handed_over"
          assert observation.current_assignment_id == successor.id
          assert :stale = Task.await(consumer, 10_000)

          successor
        after
          send(handover.pid, :release_handover_connection)
        end

      assert {:ok, ^successor} = Task.await(handover, 15_000)
    after
      cleanup_committed_role_race_fixture!(fixture)
    end
  end

  test "handover and revoke do not alter competition side membership" do
    setup = setup_group_with_side!(2)
    [holder, replacement] = setup.entries
    side_id = setup.side.id

    membership_before =
      CompetitionSideMembership
      |> Ash.Query.filter(competition_side_id == ^side_id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.round_entry_id)
      |> Enum.sort()

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               holder.id
             )

    assert {:ok, _} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               replacement.id
             )

    assert {:ok, _} =
             Competition.revoke_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               "done"
             )

    membership_after =
      CompetitionSideMembership
      |> Ash.Query.filter(competition_side_id == ^side_id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.round_entry_id)
      |> Enum.sort()

    assert membership_after == membership_before
  end

  defp setup_group_with_entries!(count) do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entries =
      for _ <- 1..count do
        player = create_player!()

        {:ok, entry} =
          Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

        assert {:ok, _} =
                 AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

        entry
      end

    %{event: event, round: round, admin: admin, group: group, entries: entries}
  end

  defp create_second_group!(%{event: event, round: round, admin: admin}) do
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    group
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  defp set_participation_status!(round_entry_id, status) do
    Repo.query!("UPDATE round_entries SET participation_status = $1 WHERE id = $2::uuid", [
      Atom.to_string(status),
      Ecto.UUID.dump!(round_entry_id)
    ])
  end

  defp handover_audit_count(group_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM audit_events WHERE action = 'handover_group_role' AND target_type = 'PlayingGroup' AND target_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp active_group_assignments(group_id) do
    GroupRoleAssignment
    |> Ash.Query.filter(playing_group_id == ^group_id and state == :active)
    |> Ash.read!(authorize?: false)
  end

  defp setup_group_with_side!(count) do
    base = setup_group_with_entries!(count)

    {:ok, competition} =
      Competition.configure_round_competition(
        base.admin,
        base.event.id,
        base.round.id,
        %{solo_sides_permitted: true}
      )

    {:ok, side} =
      Competition.create_competition_side(
        base.admin,
        base.event.id,
        base.round.id,
        competition.id,
        :partnership
      )

    assert {:ok, _} =
             SetSideMembership.run(
               base.admin,
               base.event.id,
               base.round.id,
               competition.id,
               side.id,
               Enum.map(base.entries, & &1.id)
             )

    base
    |> Map.put(:side, side)
    |> Map.put(:competition, competition)
  end

  defp setup_committed_role_race_fixture!(email_prefix) do
    event = create_event!()
    admin = create_staff_user_for_prefix!(email_prefix)

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(admin.id)]
    )

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entry_one = add_entry!(event, round, admin, group.id)
    entry_two = add_entry!(event, round, admin, group.id)

    %{
      event_id: event.id,
      round_id: round.id,
      group_id: group.id,
      entry_one_id: entry_one.id,
      entry_two_id: entry_two.id,
      admin: admin
    }
  end

  defp setup_committed_handover_fixture!(email_prefix) do
    fixture = setup_committed_role_race_fixture!(email_prefix)

    {:ok, assignment} =
      AssignGroupRole.run(
        fixture.admin,
        fixture.event_id,
        fixture.round_id,
        fixture.group_id,
        fixture.entry_one_id,
        :primary_scorer
      )

    Repo.query!("UPDATE rounds SET state = 'scoring_open' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.round_id)
    ])

    Map.merge(fixture, %{
      assignment_id: assignment.id,
      assignment_version: assignment.assignment_version
    })
  end

  defp consume_captured_authority(fixture, parent, test_case, hold_locks?) do
    Sandbox.unboxed_run(Repo, fn ->
      consume_authority_transaction(fixture, parent, test_case, hold_locks?, pg_backend_pid!())
    end)
  end

  defp consume_authority_transaction(fixture, parent, test_case, hold_locks?, backend_pid) do
    Repo.transaction(fn ->
      observation = captured_authority_observation!(fixture)
      send(parent, {:authority_consumer_ready, test_case, backend_pid, observation})
      maybe_hold_authority_locks(hold_locks?, observation.status)
      observation
    end)
    |> case do
      {:ok, observation} -> observation.status
      {:error, reason} -> {:error, reason}
    end
  end

  defp captured_authority_observation!(fixture) do
    {:ok, %{acquired: shared_rows}} =
      GolfScoring.LockProtocol.acquire!(
        round: [fixture.round_id],
        playing_group: [fixture.group_id]
      )

    round = Enum.find(shared_rows, &(&1.class == :round))
    group = Enum.find(shared_rows, &(&1.class == :playing_group))

    {:ok, %{acquired: assignment_rows}} =
      GolfScoring.LockProtocol.acquire!(
        group_role_assignment: [fixture.assignment_id | active_assignment_ids!(fixture.group_id)]
      )

    assignments = Enum.map(assignment_rows, & &1.row)
    captured = Enum.find(assignments, &(&1.id == fixture.assignment_id))
    current = Enum.find(assignments, &(&1.role == "primary_scorer" and &1.state == "active"))

    %{
      status:
        if(current_authority?(round, group, captured, current, fixture),
          do: :current,
          else: :stale
        ),
      captured_assignment_state: captured && captured.state,
      current_assignment_id: current && current.id
    }
  end

  defp active_assignment_ids!(playing_group_id) do
    Repo.query!(
      "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY id",
      [Ecto.UUID.dump!(playing_group_id)]
    ).rows
    |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)
  end

  defp current_authority?(round, group, captured, current, fixture) do
    round_group_matches?(round, group, fixture) and
      captured_assignment_matches?(captured, fixture) and
      current_assignment_matches?(current, captured)
  end

  defp round_group_matches?(
         %{row: %{state: "scoring_open"}},
         %{row: %{round_id: round_id}},
         fixture
       ),
       do: round_id == fixture.round_id

  defp round_group_matches?(_, _, _), do: false

  defp captured_assignment_matches?(
         %{id: id, state: "active", assignment_version: version},
         fixture
       ),
       do: id == fixture.assignment_id and version == fixture.assignment_version

  defp captured_assignment_matches?(_, _), do: false

  defp current_assignment_matches?(
         %{id: id, role: "primary_scorer", state: "active", assignment_version: version},
         %{id: captured_id, assignment_version: captured_version}
       ),
       do: id == captured_id and version == captured_version

  defp current_assignment_matches?(_, _), do: false

  defp maybe_hold_authority_locks(true, :current) do
    receive do
      :release_authority_locks -> :ok
    after
      15_000 -> Repo.rollback(:authority_consumer_timeout)
    end
  end

  defp maybe_hold_authority_locks(_hold_locks?, _status), do: :ok

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
        flunk("PostgreSQL did not report the handover waiting on the authority consumer")

      true ->
        # The database lock graph decides success; this short pause only backs off polling.
        Process.sleep(5)
        await_blocked_by!(waiting_pid, blocking_pid, deadline)
    end
  end

  defp cleanup_committed_role_race_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      dumped_round = Ecto.UUID.dump!(fixture.round_id)
      dumped_event = Ecto.UUID.dump!(fixture.event_id)
      dumped_staff = Ecto.UUID.dump!(fixture.admin.id)
      dumped_group = Ecto.UUID.dump!(fixture.group_id)

      Repo.query!(
        "DELETE FROM audit_events WHERE target_type = 'PlayingGroup' AND target_id = $1::uuid AND action = 'handover_group_role'",
        [dumped_group]
      )

      Repo.query!("DELETE FROM group_role_assignments WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM round_entries WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM playing_groups WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [dumped_staff])
    end)
  end

  defp add_entry!(event, round, admin, group_id) do
    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_id)
    entry
  end

  defp install_handover_audit_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls20_reject_handover_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'handover_group_role' THEN
        RAISE EXCEPTION 'simulated GLS-20 handover audit failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls20_reject_handover_audit
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls20_reject_handover_audit()
    """)
  end

  defp drop_handover_audit_failure_trigger! do
    Repo.query!("DROP TRIGGER IF EXISTS gls20_reject_handover_audit ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls20_reject_handover_audit()")
  end

  defp pg_backend_pid! do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp create_manager!(event, admin) do
    staff = create_staff_user!()

    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: :competition_manager},
        actor: admin
      )

    staff
  end

  defp create_scoring_support!(event, admin) do
    staff = create_staff_user!()

    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: :scoring_support},
        actor: admin
      )

    staff
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "GLS-20 Course", location: "Test"},
        actor: admin
      )

    course
  end

  defp create_player! do
    GolfScoring.Competition.Player
    |> Changeset.for_create(:create_internal, %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    })
    |> Ash.create!(authorize?: false)
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
      "#{Process.get(:gls20_email_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_user_for_prefix!(prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end
end
