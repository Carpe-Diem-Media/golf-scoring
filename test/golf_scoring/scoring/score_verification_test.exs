defmodule GolfScoring.Scoring.ScoreVerificationTest do
  use GolfScoring.DataCase, async: false

  require Ash.Query
  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.LockProtocol
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "designated verifier certifies another player's current revision" do
    f = fixture!(3)

    assert {:ok, verification} =
             verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)

    assert verification.status == :verified
    assert verification.verifier_round_entry_id == Enum.at(f.entries, 1).id
    assert verification.hole_result_revision == f.scorer_result.revision
    assert Ash.get!(HoleResult, f.scorer_result.id, authorize?: false) == f.scorer_result
  end

  test "two-person exception permits scorer to certify the verifier, but neither can self-verify" do
    f = fixture!(2)
    assert {:ok, verified} = verify(f, f.scorer_grant, f.verifier_result, f.scorer_assignment)
    assert verified.verifier_round_entry_id == hd(f.entries).id

    assert {:error, :ineligible_verifier} =
             verify(f, f.verifier_grant, f.verifier_result, f.verifier_assignment)

    assert {:error, :ineligible_verifier} =
             verify(f, f.scorer_grant, f.scorer_result, f.scorer_assignment)
  end

  test "rejects stale revisions and conflicting duplicates while identical retries are idempotent" do
    f = fixture!(2)

    assert {:error, :stale_revision} =
             Scoring.verify_hole_result(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               Map.put(
                 command(f, f.scorer_result, f.verifier_assignment),
                 :hole_result_revision,
                 2
               )
             )

    assert {:ok, first} = verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
    assert {:ok, second} = verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
    assert first.id == second.id

    assert {:error, :conflicting_certification} =
             Scoring.override_hole_verification(
               f.admin,
               f.event.id,
               f.round.id,
               Map.put(command(f, f.scorer_result, f.verifier_assignment), :reason, "exception")
             )
  end

  test "handover rejects the previous assignment and accepts the new verifier" do
    f = fixture!(3)
    replacement = Enum.at(f.entries, 2)

    assert {:ok, assignment} =
             Competition.handover_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               replacement.id
             )

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, replacement.player_id)

    assert {:error, :ineligible_verifier} =
             verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)

    assert {:ok, verified} = verify(f, grant, f.scorer_result, assignment)
    assert verified.role_assignment_id == assignment.id
  end

  test "a revoked grant and a stale assignment version cannot certify" do
    f = fixture!(2)
    command = command(f, f.scorer_result, f.verifier_assignment)

    assert {:error, :ineligible_verifier} =
             Scoring.verify_hole_result(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               Map.update!(command, :role_assignment_version, &(&1 + 1))
             )

    assert {:ok, _} =
             Accounts.revoke_player_access(f.admin, f.event.id, Enum.at(f.entries, 1).player_id)

    assert {:error, :invalid_player_session} =
             Scoring.verify_hole_result(f.verifier_grant, f.event.id, f.round.id, command)
  end

  test "database constraints reject forged subjects, assignment versions and duplicate revisions" do
    f = fixture!(2)
    assert {:ok, verified} = verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
    id = Ecto.UUID.dump!(verified.id)
    options = [mode: :savepoint]

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_verifications SET subject_round_entry_id = verifier_round_entry_id WHERE id = $1::uuid",
               [id],
               options
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_verifications SET role_assignment_version = role_assignment_version + 1 WHERE id = $1::uuid",
               [id],
               options
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(
               """
               INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id)
               SELECT hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id
               FROM score_verifications WHERE id = $1::uuid
               """,
               [id],
               options
             )
  end

  test "a map containing an authorized admin ID cannot override or write audit evidence" do
    f = fixture!(2)
    command = Map.put(command(f, f.scorer_result, f.verifier_assignment), :reason, "exception")

    assert {:error, :invalid_actor} =
             Scoring.override_hole_verification(
               %{id: f.admin.id},
               f.event.id,
               f.round.id,
               command
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM score_verifications WHERE hole_result_id = $1::uuid",
               [
                 Ecto.UUID.dump!(f.scorer_result.id)
               ]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM audit_events WHERE action = 'override_hole_verification' AND context->>'round_id' = $1",
               [f.round.id]
             )
  end

  test "staff override requires a reason and records a single audit without impersonating a player" do
    f = fixture!(2)
    command = command(f, f.scorer_result, f.verifier_assignment)

    assert {:error, :forbidden} =
             Scoring.override_hole_verification(
               %StaffUser{id: Ecto.UUID.generate()},
               f.event.id,
               f.round.id,
               Map.put(command, :reason, "exception")
             )

    assert {:error, :reason_required} =
             Scoring.override_hole_verification(
               f.admin,
               f.event.id,
               f.round.id,
               Map.put(command, :reason, " ")
             )

    command = Map.put(command, :reason, "marker unavailable")

    assert {:ok, first} =
             Scoring.override_hole_verification(f.admin, f.event.id, f.round.id, command)

    assert {:ok, again} =
             Scoring.override_hole_verification(f.admin, f.event.id, f.round.id, command)

    assert first.id == again.id
    assert first.status == :overridden
    assert first.verifier_round_entry_id == nil
    assert first.overridden_by_staff_user_id == f.admin.id

    events =
      AuditEvent
      |> Ash.Query.filter(target_id == ^first.id and action == "override_hole_verification")
      |> Ash.read!(authorize?: false)

    assert [%{reason: "marker unavailable"}] = events
  end

  test "only authorized correction supersedes certified evidence and requires fresh verification" do
    f = fixture!(2, true)
    assert {:ok, verified} = verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)

    assert {:error, _} =
             verified
             |> Changeset.for_update(:supersede_internal, %{})
             |> Ash.update(authorize?: false)

    assert {:ok, correction} =
             Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result.id,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "correct counted strokes"
             })

    superseded = Ash.get!(GolfScoring.Scoring.ScoreVerification, verified.id, authorize?: false)
    assert superseded.status == :superseded
    assert correction.verification.status == :pending

    assert {:error, :stale_revision} =
             verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)

    assert {:ok, newer} =
             verify(f, f.verifier_grant, %{f.scorer_result | revision: 2}, f.verifier_assignment)

    assert newer.id != superseded.id
    assert newer.hole_result_revision == 2
  end

  @tag :real_concurrency
  test "simultaneous identical certifications produce one record" do
    f = Sandbox.unboxed_run(Repo, fn -> fixture!(2) end)
    parent = self()

    try do
      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Sandbox.unboxed_run(Repo, fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
              after
                10_000 -> raise "verification test timed out"
              end
            end)
          end)
        end

      assert_receive {:ready, first}, 10_000
      assert_receive {:ready, second}, 10_000
      send(first, :go)
      send(second, :go)
      assert [{:ok, one}, {:ok, two}] = Enum.map(tasks, &Task.await(&1, 15_000))
      assert one.id == two.id

      assert [[1]] =
               Sandbox.unboxed_run(Repo, fn ->
                 Repo.query!(
                   "SELECT count(*)::int FROM score_verifications WHERE hole_result_id = $1::uuid",
                   [Ecto.UUID.dump!(f.scorer_result.id)]
                 ).rows
               end)
    after
      cleanup!(f)
    end
  end

  @tag :real_concurrency
  test "verification waits for the scorecard lock boundary" do
    f = Sandbox.unboxed_run(Repo, fn -> fixture!(2) end)
    parent = self()

    try do
      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, _} = LockProtocol.acquire!(score_row: [f.scorer_result.scorecard_id])
              [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:score_locked, pid})

              receive do
                :release -> :ok
              after
                10_000 -> raise "score lock test timed out"
              end
            end)
          end)
        end)

      assert_receive {:score_locked, holder_pid}, 10_000

      verifier =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:score_verifier, pid})
            verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
          end)
        end)

      assert_receive {:score_verifier, verifier_pid}, 10_000
      await_blocked!(verifier_pid, holder_pid, System.monotonic_time(:millisecond) + 10_000)
      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 15_000)
      assert {:ok, %{status: :verified}} = Task.await(verifier, 15_000)
    after
      cleanup!(f)
    end
  end

  @tag :real_concurrency
  test "verification waits for handover and rejects the former assignment" do
    f = Sandbox.unboxed_run(Repo, fn -> fixture!(3) end)
    parent = self()

    try do
      holder =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert [[_assignment_id]] =
                       Repo.query!(
                         "SELECT id::text FROM group_role_assignments WHERE id = $1::uuid FOR UPDATE",
                         [Ecto.UUID.dump!(f.verifier_assignment.id)]
                       ).rows

              [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:held, pid})

              receive do
                :release -> :released
              after
                10_000 -> raise "verification test timed out"
              end
            end)
          end)
        end)

      assert_receive {:held, holder_pid}, 10_000

      handover =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:handing_over, pid})

            Competition.handover_designated_verifier(
              f.admin,
              f.event.id,
              f.round.id,
              f.group.id,
              Enum.at(f.entries, 2).id
            )
          end)
        end)

      assert_receive {:handing_over, handover_pid}, 10_000
      await_blocked!(handover_pid, holder_pid, System.monotonic_time(:millisecond) + 10_000)

      verifier =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:verifying, pid})
            verify(f, f.verifier_grant, f.scorer_result, f.verifier_assignment)
          end)
        end)

      assert_receive {:verifying, verifier_pid}, 10_000
      await_blocked!(verifier_pid, handover_pid, System.monotonic_time(:millisecond) + 10_000)
      send(holder.pid, :release)
      assert {:ok, _} = Task.await(holder, 15_000)
      assert {:ok, _} = Task.await(handover, 15_000)
      assert {:error, :ineligible_verifier} = Task.await(verifier, 15_000)
    after
      cleanup!(f)
    end
  end

  defp verify(f, grant, result, assignment),
    do: Scoring.verify_hole_result(grant, f.event.id, f.round.id, command(f, result, assignment))

  defp command(f, result, assignment),
    do: %{
      playing_group_id: f.group.id,
      hole_result_id: result.id,
      hole_result_revision: result.revision,
      role_assignment_id: assignment.id,
      role_assignment_version: assignment.assignment_version
    }

  defp fixture!(count, with_side? \\ false) do
    f = PaperRecoveryFixtures.setup_submit_fixture!(count)
    [scorer, verifier | _] = f.entries
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)

    if with_side? do
      assert {:ok, side} =
               Competition.create_competition_side(
                 f.admin,
                 f.event.id,
                 f.round.id,
                 f.competition.id,
                 :partnership
               )

      assert {:ok, _} =
               Competition.set_side_membership(
                 f.admin,
                 f.event.id,
                 f.round.id,
                 f.competition.id,
                 side.id,
                 Enum.map(f.entries, & &1.id)
               )
    end

    assert {:ok, verifier_assignment} =
             Competition.assign_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               verifier.id
             )

    scorer_assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(
        playing_group_id == ^f.group.id and role == :primary_scorer and state == :active
      )
      |> Ash.read_one!(authorize?: false)

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, %{grant: scorer_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, scorer.player_id)

    assert {:ok, %{grant: verifier_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, verifier.player_id)

    submission = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: f.group.id,
      round_hole_id: f.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }

    assert {:ok, _} = Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, submission)
    scorer_result = result!(scorer.id)
    verifier_result = result!(verifier.id)

    Map.merge(f, %{
      scorer_result: scorer_result,
      verifier_result: verifier_result,
      scorer_grant: scorer_grant,
      verifier_grant: verifier_grant,
      scorer_assignment: scorer_assignment,
      verifier_assignment: verifier_assignment
    })
  end

  defp result!(entry_id) do
    card =
      Scorecard
      |> Ash.Query.filter(round_entry_id == ^entry_id)
      |> Ash.read_one!(authorize?: false)

    HoleResult |> Ash.Query.filter(scorecard_id == ^card.id) |> Ash.read_one!(authorize?: false)
  end

  defp await_blocked!(waiting, blocker, deadline) do
    [[blocked]] =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [blocker, waiting]).rows
      end)

    cond do
      blocked ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("backend did not wait on the expected lock")

      true ->
        Process.sleep(10)
        await_blocked!(waiting, blocker, deadline)
    end
  end

  defp cleanup!(f) do
    Sandbox.unboxed_run(Repo, fn ->
      round = Ecto.UUID.dump!(f.round.id)
      event = Ecto.UUID.dump!(f.event.id)
      staff = Ecto.UUID.dump!(f.admin.id)
      players = Enum.map(f.entries, &Ecto.UUID.dump!(&1.player_id))

      for {sql, args} <- [
            {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM hole_results WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM hole_submissions WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM audit_events WHERE context->>'round_id' = $1", [f.round.id]},
            {"DELETE FROM scorecards WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM group_role_assignments WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_entries WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM playing_groups WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_competitions WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
             [round]},
            {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM round_holes WHERE round_id = $1::uuid", [round]},
            {"DELETE FROM rounds WHERE id = $1::uuid", [round]},
            {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid",
             [Ecto.UUID.dump!(f.tee_profile.id)]},
            {"DELETE FROM tee_sets WHERE id = $1::uuid", [Ecto.UUID.dump!(f.tee_set.id)]},
            {"DELETE FROM course_holes WHERE course_id = $1::uuid",
             [Ecto.UUID.dump!(f.course.id)]},
            {"DELETE FROM courses WHERE id = $1::uuid", [Ecto.UUID.dump!(f.course.id)]},
            {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [event]},
            {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [event]},
            {"DELETE FROM events WHERE id = $1::uuid", [event]},
            {"DELETE FROM staff_users WHERE id = $1::uuid", [staff]}
          ],
          do: Repo.query!(sql, args)

      for player <- players, do: Repo.query!("DELETE FROM players WHERE id = $1::uuid", [player])
    end)
  end
end
