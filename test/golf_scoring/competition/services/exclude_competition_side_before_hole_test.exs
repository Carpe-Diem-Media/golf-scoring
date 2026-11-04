defmodule GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHoleTest do
  use ExUnit.Case, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole
  alias GolfScoring.Competition.Services.MysteryRevealCoordinator
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @password "GLS-80 synthetic staff passphrase 2026"
  @reason "organizer confirmed the side had not started this hole"
  @submit_audit_barrier 9_038_080

  setup do
    Process.put(:gls34_prefix, "gls80-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "an active Event Admin records immutable, audited pre-play evidence and reveals after commit" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    memberships_before = membership_count_for_round(setup.round.id)
    subscribe_to_round(setup.round.id)

    assert {:ok, %{side_result_id: result_id, mystery_reveal_created?: true}} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)

    assert [
             ["excluded", actor_id, reason, excluded_at, true, group_id, hole_id, 0]
           ] =
             Repo.query!(
               """
               SELECT state, excluded_by_staff_user_id::text, exclusion_reason, excluded_at,
                      excluded_preplay_confirmed, excluded_playing_group_id::text,
                      excluded_effective_round_hole_id::text, excluded_effective_play_index
               FROM competition_side_results
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(result_id)]
             ).rows

    assert Ecto.UUID.cast!(actor_id) == setup.admin.id
    assert reason == @reason
    assert %NaiveDateTime{} = excluded_at
    assert Ecto.UUID.cast!(group_id) == setup.group.id
    assert Ecto.UUID.cast!(hole_id) == mystery.rule.round_hole_id
    assert count_for_rule("mystery_reveals", mystery.rule.id) == 1
    assert count_audits_for_result(result_id) == 1
    assert membership_count_for_round(setup.round.id) == memberships_before
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert Ecto.UUID.cast!(round_id) == setup.round.id
  end

  test "an active Competition Manager can record a pre-play exclusion" do
    {setup, mystery} = single_group_mystery!()
    manager = create_staff_user!()

    assert {:ok, _assignment} =
             Accounts.assign_event_staff_role(
               %{event_id: setup.event.id, staff_user_id: manager.id, role: :competition_manager},
               actor: setup.admin
             )

    assert {:ok, %{mystery_reveal_created?: true}} =
             exclude(
               setup,
               side_id_for_entries(setup.entries),
               setup.group.id,
               mystery.rule.round_hole_id,
               %{
                 actor: manager
               }
             )
  end

  test "inactive or unauthorized staff, missing attestation, blank reason, and mismatched scope fail closed" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    mystery = setup.mystery
    side_id = side_id_for_entries(setup.entries)
    subscribe_to_round(setup.round.id)

    assert {:error, :forbidden} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               actor: %{id: hd(setup.entries).id}
             })

    inactive_manager = create_staff_user!()

    assert {:ok, _assignment} =
             Accounts.assign_event_staff_role(
               %{
                 event_id: setup.event.id,
                 staff_user_id: inactive_manager.id,
                 role: :competition_manager
               },
               actor: setup.admin
             )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(inactive_manager.id)
    ])

    assert {:error, :forbidden} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               actor: inactive_manager
             })

    assert {:error, :exclusion_reason_required} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{reason: "  "})

    assert {:error, :preplay_attestation_required} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               confirm_hole_unplayed?: false
             })

    assert {:error, :preplay_attestation_required} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               confirm_hole_unplayed?: nil
             })

    assert {:error, :competition_mismatch} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               competition_id: Ecto.UUID.generate()
             })

    assert {:error, :playing_group_not_found} =
             exclude(setup, side_id, Ecto.UUID.generate(), mystery.rule.round_hole_id)

    assert {:error, :competition_side_group_mismatch} =
             exclude(setup, side_id, setup.group_b.id, mystery.rule.round_hole_id)

    other_event = PaperRecoveryFixtures.create_event!()

    assert {:error, :forbidden} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id, %{
               event_id: other_event.id
             })

    assert side_result_state(side_id) == "provisional"
    assert count_audits_for_action(setup.event.id) == 0
    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "shotgun wrapping stores the physical hole's rotated play index" do
    setup = PaperRecoveryFixtures.setup_shotgun_fixture!(18)
    mystery = PaperRecoveryFixtures.configure_single_group_mystery!(setup)
    side_id = side_id_for_entries(setup.entries)
    hole_after_wrap = Enum.find(setup.route, &(&1.play_order == 1))

    assert {:ok, %{side_result_id: result_id, mystery_reveal_created?: false}} =
             exclude(setup, side_id, setup.group.id, hole_after_wrap.id)

    assert [[1, hole_id]] =
             Repo.query!(
               """
               SELECT excluded_effective_play_index, excluded_effective_round_hole_id::text
               FROM competition_side_results
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(result_id)]
             ).rows

    assert Ecto.UUID.cast!(hole_id) == hole_after_wrap.id
    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
  end

  test "a partial side exclusion stays unresolved until every side in the group is excluded" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(4)

    mystery =
      PaperRecoveryFixtures.configure_mystery_for_groups!(setup, [
        {setup.group, Enum.take(setup.entries, 2)},
        {setup.group, Enum.drop(setup.entries, 2)}
      ])

    [first_side, second_side] =
      Enum.map([Enum.take(setup.entries, 2), Enum.drop(setup.entries, 2)], &side_id_for_entries/1)

    subscribe_to_round(setup.round.id)

    assert {:ok, %{mystery_reveal_created?: false}} =
             exclude(setup, first_side, setup.group.id, mystery.rule.round_hole_id)

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
    refute_receive {:mystery_reveal_changed, _}, 50

    assert {:ok, %{mystery_reveal_created?: true}} =
             exclude(setup, second_side, setup.group.id, mystery.rule.round_hole_id)

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 1
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert Ecto.UUID.cast!(round_id) == setup.round.id
  end

  test "one exclusion rechecks every affected Mystery rule in canonical order" do
    {setup, mystery} = single_group_mystery!()
    second_hole = Enum.find(setup.route, &(&1.play_order == 2))

    PaperRecoveryFixtures.set_round_state!(setup.round, :draft)

    assert {:ok, second_rule} =
             Competition.configure_mystery_hole_rule(
               setup.admin,
               setup.event.id,
               setup.round.id,
               mystery.track.id,
               second_hole.id,
               :worst
             )

    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_open)
    subscribe_to_round(setup.round.id)

    assert {:ok, %{mystery_reveal_created?: true}} =
             exclude(
               setup,
               side_id_for_entries(setup.entries),
               setup.group.id,
               setup.start_hole.id
             )

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 1
    assert count_for_rule("mystery_reveals", second_rule.id) == 1
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert Ecto.UUID.cast!(round_id) == setup.round.id
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "an accepted group submission remains submitted when another required group is excluded" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    subscribe_to_round(setup.round.id)

    assert {:ok, _receipt} =
             submit_first_hole(setup, setup.group, setup.entries, setup.start_hole.id)

    assert_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}, 50

    side_b = side_id_for_entries(setup.entries_b)

    assert {:ok, %{mystery_reveal_created?: true}} =
             exclude(setup, side_b, setup.group_b.id, setup.mystery.rule.round_hole_id)

    assert count_for_rule("mystery_reveals", setup.mystery.rule.id) == 1
    assert_receive {:mystery_reveal_changed, %{round_id: round_id}}
    assert Ecto.UUID.cast!(round_id) == setup.round.id
  end

  test "disqualification alone does not resolve a Mystery group" do
    {setup, mystery} = single_group_mystery!()

    Repo.query!(
      "UPDATE round_entries SET participation_status = 'disqualified' WHERE playing_group_id = $1::uuid",
      [Ecto.UUID.dump!(setup.group.id)]
    )

    assert {:ok, {:ok, %{created?: false}}} =
             Repo.transaction(fn ->
               MysteryRevealCoordinator.recheck(setup.round.id, mystery.rule.round_hole_id)
             end)

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
  end

  test "prior accepted play can precede an exclusion, but the exclusion cannot backdate to it" do
    {setup, mystery} = single_group_mystery!()
    second_hole = Enum.find(setup.route, &(&1.play_order == 2))
    side_id = side_id_for_entries(setup.entries)

    Repo.query!(
      "UPDATE mystery_hole_rules SET round_hole_id = $1::uuid WHERE id = $2::uuid",
      [Ecto.UUID.dump!(second_hole.id), Ecto.UUID.dump!(mystery.rule.id)]
    )

    assert {:ok, _receipt} =
             submit_first_hole(setup, setup.group, setup.entries, setup.start_hole.id)

    assert {:error, :preplay_checkpoint_already_passed} =
             exclude(setup, side_id, setup.group.id, setup.start_hole.id)

    assert {:ok, %{mystery_reveal_created?: true}} =
             exclude(setup, side_id, setup.group.id, second_hole.id)

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 1
  end

  test "a result without a submission makes physical play ambiguous" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    entry = hd(setup.entries)

    [[scorecard_id]] =
      Repo.query!(
        """
        INSERT INTO scorecards (round_id, round_entry_id, state)
        VALUES ($1::uuid, $2::uuid, 'not_started')
        RETURNING id::text
        """,
        [Ecto.UUID.dump!(setup.round.id), Ecto.UUID.dump!(entry.id)]
      ).rows

    Repo.query!(
      """
      INSERT INTO hole_results (round_id, scorecard_id, round_hole_id, outcome, gross_strokes)
      VALUES ($1::uuid, $2::uuid, $3::uuid, 'holed_out', 5)
      """,
      [
        Ecto.UUID.dump!(setup.round.id),
        Ecto.UUID.dump!(Ecto.UUID.cast!(scorecard_id)),
        Ecto.UUID.dump!(mystery.rule.round_hole_id)
      ]
    )

    assert {:error, :preplay_checkpoint_already_passed} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)

    assert side_result_state(side_id) == "provisional"
    assert count_audits_for_action(setup.event.id) == 0
  end

  test "review, generic exclusion, finalization, and reopen paths remain fail closed" do
    {setup, _mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)

    result = provisional_result_for_side!(side_id)

    for action <- [:mark_review_required, :exclude, :mark_ready_to_finalize, :finalize, :reopen] do
      changeset = Changeset.for_update(result, action, %{})
      assert {:error, _error} = Ash.update(changeset, authorize?: false)
    end
  end

  test "terminal side results cannot be excluded" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)

    result = provisional_result_for_side!(side_id)

    Repo.query!("UPDATE competition_side_results SET state = 'finalized' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(result.id)
    ])

    assert {:error, :competition_side_result_terminal} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)
  end

  test "an enclosing transaction is rejected so no reveal is broadcast before its commit" do
    {setup, mystery} = single_group_mystery!()
    subscribe_to_round(setup.round.id)
    side_id = side_id_for_entries(setup.entries)

    assert {:ok, :outer_transaction_committed} =
             Repo.transaction(fn ->
               assert {:error, :transaction_already_open} =
                        exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)

               :outer_transaction_committed
             end)

    assert side_result_state(side_id) == "provisional"
    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
    assert count_audits_for_action(setup.event.id) == 0
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "a failed reveal insert rolls back exclusion and audit without publishing" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    subscribe_to_round(setup.round.id)
    function_name = "gls80_reject_reveal_#{System.unique_integer([:positive])}"
    trigger_name = "gls80_reject_reveal_trigger_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'GLS-80 test reveal failure' USING ERRCODE = '23514';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON mystery_reveals
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    assert {:error, _error} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)

    assert side_result_state(side_id) == "provisional"
    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
    assert count_audits_for_action(setup.event.id) == 0
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "a failed audit insert rolls back exclusion provenance and reveal without publishing" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)
    subscribe_to_round(setup.round.id)
    function_name = "gls80_reject_audit_#{System.unique_integer([:positive])}"
    trigger_name = "gls80_reject_audit_trigger_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'exclude_competition_side_before_hole' THEN
        RAISE EXCEPTION 'GLS-80 test audit failure' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    assert {:error, _error} =
             exclude(setup, side_id, setup.group.id, mystery.rule.round_hole_id)

    assert side_result_state(side_id) == "provisional"

    assert [[nil, nil, nil, nil, nil, nil, nil]] =
             Repo.query!(
               """
               SELECT excluded_by_staff_user_id, exclusion_reason, excluded_at,
                      excluded_playing_group_id, excluded_effective_round_hole_id,
                      excluded_effective_play_index, excluded_preplay_confirmed
               FROM competition_side_results
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(result.id)]
             ).rows

    assert count_for_rule("mystery_reveals", mystery.rule.id) == 0
    assert count_audits_for_action(setup.event.id) == 0
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  @tag :real_concurrency
  test "last-group scoring serializes against exclusion without a premature or duplicate reveal" do
    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
        first_side_id = side_id_for_entries(setup.entries)

        assert {:ok, %{mystery_reveal_created?: false}} =
                 exclude(setup, first_side_id, setup.group.id, setup.mystery.rule.round_hole_id)

        setup
      end)

    parent = self()
    Process.delete(:gls80_last_group_barrier_task)
    Process.delete(:gls80_last_group_race_tasks)

    try do
      Sandbox.unboxed_run(Repo, fn -> install_submit_audit_barrier!() end)
      Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{fixture.round.id}")

      barrier_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [@submit_audit_barrier])
              send(parent, {:gls80_submit_audit_barrier_held, pg_backend_pid!()})

              receive do
                :gls80_release_submit_audit_barrier -> :released
              after
                15_000 -> Repo.rollback(:gls80_submit_audit_barrier_timeout)
              end
            end)
          end)
        end)

      Process.put(:gls80_last_group_barrier_task, barrier_task)
      assert_receive {:gls80_submit_audit_barrier_held, barrier_pid}, 5_000

      scoring_setup = Map.merge(fixture, %{group: fixture.group_b, entries: fixture.entries_b})

      scoring_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls80_last_group_scoring_started, pg_backend_pid!()})

            submit_first_hole(
              scoring_setup,
              fixture.group_b,
              fixture.entries_b,
              fixture.mystery.rule.round_hole_id
            )
          end)
        end)

      Process.put(:gls80_last_group_race_tasks, [scoring_task])
      assert_receive {:gls80_last_group_scoring_started, scoring_pid}, 10_000
      await_blocked_by!(scoring_pid, barrier_pid, System.monotonic_time(:millisecond) + 10_000)
      refute_receive {:group_hole_submitted, _}, 50
      refute_receive {:mystery_reveal_changed, _}, 50

      exclusion_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls80_last_group_exclusion_started, pg_backend_pid!()})

            exclude(
              fixture,
              side_id_for_entries(fixture.entries_b),
              fixture.group_b.id,
              fixture.mystery.rule.round_hole_id
            )
          end)
        end)

      Process.put(:gls80_last_group_race_tasks, [scoring_task, exclusion_task])
      assert_receive {:gls80_last_group_exclusion_started, exclusion_pid}, 10_000
      refute scoring_pid == exclusion_pid
      await_blocked_by!(exclusion_pid, scoring_pid, System.monotonic_time(:millisecond) + 10_000)
      refute_receive {:group_hole_submitted, _}, 50
      refute_receive {:mystery_reveal_changed, _}, 50

      send(barrier_task.pid, :gls80_release_submit_audit_barrier)

      assert {:ok, _receipt} = Task.await(scoring_task, 20_000)
      Process.put(:gls80_last_group_race_tasks, [exclusion_task])

      assert {:error, :preplay_checkpoint_already_passed} = Task.await(exclusion_task, 20_000)
      assert {:ok, _} = Task.await(barrier_task, 10_000)
      Process.delete(:gls80_last_group_race_tasks)
      Process.delete(:gls80_last_group_barrier_task)

      Sandbox.unboxed_run(Repo, fn -> remove_submit_audit_barrier!() end)

      assert count_for_rule("mystery_reveals", fixture.mystery.rule.id) == 1

      assert [[1]] =
               Repo.query!(
                 "SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid",
                 [
                   Ecto.UUID.dump!(fixture.round.id),
                   Ecto.UUID.dump!(fixture.group_b.id),
                   Ecto.UUID.dump!(fixture.mystery.rule.round_hole_id)
                 ]
               ).rows

      assert side_result_state(side_id_for_entries(fixture.entries_b)) == "provisional"
      assert_receive {:group_hole_submitted, %{playing_group_id: group_id}}, 5_000
      assert Ecto.UUID.cast!(group_id) == fixture.group_b.id
      assert_receive {:mystery_reveal_changed, %{round_id: round_id}}, 5_000
      assert Ecto.UUID.cast!(round_id) == fixture.round.id
      refute_receive {:mystery_reveal_changed, _}, 50
      refute_receive {:group_hole_submitted, _}, 50
    after
      if barrier = Process.delete(:gls80_last_group_barrier_task) do
        send(barrier.pid, :gls80_release_submit_audit_barrier)
        Task.shutdown(barrier, 10_000)
      end

      for task <- Process.delete(:gls80_last_group_race_tasks) || [] do
        try do
          Task.shutdown(task, 10_000)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end

      Sandbox.unboxed_run(Repo, fn -> remove_submit_audit_barrier!() end)
      cleanup_committed_fixture!(fixture)
    end
  end

  test "database constraints reject incomplete and generic excluded provenance" do
    {setup, _mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO competition_side_results (competition_side_id, state) VALUES ($1::uuid, 'excluded')",
          [Ecto.UUID.dump!(side_id)]
        )
      end

    assert error.postgres.constraint ==
             "competition_side_results_exclusion_transition_guard"
  end

  defp install_submit_audit_barrier! do
    remove_submit_audit_barrier!()

    Repo.query!("""
    CREATE FUNCTION gls80_wait_for_submit_audit() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'submit_group_hole' THEN
        PERFORM pg_advisory_xact_lock(#{@submit_audit_barrier});
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls80_wait_for_submit_audit_trigger
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls80_wait_for_submit_audit()
    """)
  end

  defp remove_submit_audit_barrier! do
    Repo.query!("DROP TRIGGER IF EXISTS gls80_wait_for_submit_audit_trigger ON audit_events")
    Repo.query!("DROP FUNCTION IF EXISTS gls80_wait_for_submit_audit()")
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      round = Ecto.UUID.dump!(fixture.round.id)
      event = Ecto.UUID.dump!(fixture.event.id)
      staff = Ecto.UUID.dump!(fixture.admin.id)

      player_ids =
        Repo.query!("SELECT player_id::text FROM round_entries WHERE round_id = $1::uuid", [round]).rows
        |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

      for {sql, args} <- [
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

  test "database check constraints reject provenance on a provisional result" do
    {setup, _mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE competition_side_results SET excluded_preplay_confirmed = TRUE WHERE competition_side_id = $1::uuid",
          [Ecto.UUID.dump!(side_id)]
        )
      end

    assert error.postgres.constraint ==
             "competition_side_results_exclusion_provenance_consistent"
  end

  test "database constraint rejects noncanonical exclusion reasons" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)

    update_sql = """
    UPDATE competition_side_results
    SET state = 'excluded', excluded_by_staff_user_id = $2::uuid,
        exclusion_reason = $3, excluded_playing_group_id = $4::uuid,
        excluded_effective_round_hole_id = $5::uuid,
        excluded_effective_play_index = 0, excluded_preplay_confirmed = TRUE
    WHERE id = $1::uuid
    """

    for invalid_reason <- [
          "\t",
          "\n",
          "\u00A0\u202F",
          " #{@reason} ",
          "\t#{@reason}\n"
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(update_sql, [
            Ecto.UUID.dump!(result.id),
            Ecto.UUID.dump!(setup.admin.id),
            invalid_reason,
            Ecto.UUID.dump!(setup.group.id),
            Ecto.UUID.dump!(mystery.rule.round_hole_id)
          ])
        end

      assert error.postgres.constraint ==
               "competition_side_results_exclusion_provenance_consistent"
    end

    assert %{num_rows: 1} =
             Repo.query!(update_sql, [
               Ecto.UUID.dump!(result.id),
               Ecto.UUID.dump!(setup.admin.id),
               @reason,
               Ecto.UUID.dump!(setup.group.id),
               Ecto.UUID.dump!(mystery.rule.round_hole_id)
             ])

    assert [[@reason]] =
             Repo.query!(
               "SELECT exclusion_reason FROM competition_side_results WHERE id = $1::uuid",
               [Ecto.UUID.dump!(result.id)]
             ).rows
  end

  test "database trigger rejects a forged route index on provisional to excluded" do
    {setup, mystery} = single_group_mystery!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE competition_side_results
          SET state = 'excluded', excluded_by_staff_user_id = $2::uuid,
              exclusion_reason = $3, excluded_playing_group_id = $4::uuid,
              excluded_effective_round_hole_id = $5::uuid,
              excluded_effective_play_index = 1, excluded_preplay_confirmed = TRUE
          WHERE id = $1::uuid
          """,
          [
            Ecto.UUID.dump!(result.id),
            Ecto.UUID.dump!(setup.admin.id),
            @reason,
            Ecto.UUID.dump!(setup.group.id),
            Ecto.UUID.dump!(mystery.rule.round_hole_id)
          ]
        )
      end

    assert error.postgres.constraint ==
             "competition_side_results_exclusion_scope_consistent"
  end

  defp single_group_mystery! do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    {setup, PaperRecoveryFixtures.configure_single_group_mystery!(setup)}
  end

  defp exclude(setup, side_id, playing_group_id, effective_hole_id, opts \\ %{}) do
    ExcludeCompetitionSideBeforeHole.run(
      Map.get(opts, :actor, setup.admin),
      Map.get(opts, :event_id, setup.event.id),
      setup.round.id,
      Map.get(opts, :competition_id, setup.competition.id),
      side_id,
      playing_group_id,
      effective_hole_id,
      %{
        reason: Map.get(opts, :reason, @reason),
        confirm_hole_unplayed?: Map.get(opts, :confirm_hole_unplayed?, true)
      }
    )
  end

  defp side_id_for_entries(entries) do
    entry_ids = Enum.map(entries, &Ecto.UUID.dump!(&1.id))

    case Repo.query!(
           """
           SELECT DISTINCT competition_side_id::text
           FROM competition_side_memberships
           WHERE round_entry_id = ANY($1::uuid[])
           ORDER BY competition_side_id
           """,
           [entry_ids]
         ).rows do
      [[side_id]] -> Ecto.UUID.cast!(side_id)
    end
  end

  defp submit_first_hole(setup, group, entries, hole_id) do
    SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: group.id,
      round_hole_id: hole_id,
      expected_group_score_revision: 0,
      results:
        Enum.map(entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now()
    })
  end

  defp provisional_result_for_side!(side_id) do
    case Repo.query!(
           "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[id]] -> Ash.get!(CompetitionSideResult, Ecto.UUID.cast!(id), authorize?: false)
    end
  end

  defp create_staff_user! do
    StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: "#{Process.get(:gls34_prefix)}-manager@example.com",
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp subscribe_to_round(round_id),
    do: Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{round_id}")

  defp count_for_rule(table, id, column \\ "mystery_hole_rule_id") do
    Repo.query!("SELECT count(*)::int FROM #{table} WHERE #{column} = $1::uuid", [
      Ecto.UUID.dump!(id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp count_audits_for_result(result_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'exclude_competition_side_before_hole' AND target_id = $1::uuid",
      [Ecto.UUID.dump!(result_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp count_audits_for_action(event_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'exclude_competition_side_before_hole' AND context->>'event_id' = $1",
      [to_string(event_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp side_result_state(side_id) do
    Repo.query!(
      "SELECT state FROM competition_side_results WHERE competition_side_id = $1::uuid",
      [Ecto.UUID.dump!(side_id)]
    ).rows
    |> case do
      [[state]] -> state
    end
  end

  defp membership_count_for_round(round_id) do
    Repo.query!(
      "SELECT count(*)::int FROM competition_side_memberships WHERE round_id = $1::uuid",
      [Ecto.UUID.dump!(round_id)]
    ).rows
  end
end
