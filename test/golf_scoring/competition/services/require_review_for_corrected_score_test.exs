defmodule GolfScoring.Competition.Services.RequireReviewForCorrectedScoreTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Competition.Services.LoadSideReviewReason
  alias GolfScoring.Competition.Services.RequireReviewForCorrectedScore, as: Review
  alias GolfScoring.LockProtocol
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  @tag :cleanup_safety
  test "unboxed writes accept only the allocated local or trusted GitHub Actions identity" do
    local = %{"CI" => nil, "GITHUB_ACTIONS" => nil, "GITHUB_REPOSITORY" => nil}

    github = %{
      "CI" => "true",
      "GITHUB_ACTIONS" => "true",
      "GITHUB_REPOSITORY" => "JCSchoeman96/golf-scoring"
    }

    local_rows = [["golf_scoring_test", "golf_scoring_test"]]
    ci_rows = [["golf_scoring_test", "golf_scoring_ci"]]
    assert :ok = validate_test_identity!(:test, local_rows, local)
    assert :ok = validate_test_identity!(:test, ci_rows, github)

    for {environment, rows, runner} <- [
          {:dev, local_rows, local},
          {:prod, ci_rows, github},
          {:test, [["golf_scoring_dev", "golf_scoring_test"]], local},
          {:test, [["golf_scoring_test", "golf_scoring_dev"]], local},
          {:test, ci_rows, local},
          {:test, local_rows, github},
          {:test, [], local},
          {:test, ci_rows, Map.put(github, "GITHUB_REPOSITORY", "other/project")},
          {:test, ci_rows, Map.put(github, "GITHUB_ACTIONS", "false")},
          {:test, local_rows, Map.put(local, "GITHUB_REPOSITORY", "other/project")},
          {:test, local_rows, Map.put(local, "CI", "true")}
        ] do
      assert_raise RuntimeError,
                   "refusing unboxed writes outside the allocated test database and role",
                   fn ->
                     validate_test_identity!(environment, rows, runner)
                   end
    end
  end

  test "unboxed fixture setup rolls back all writes when setup fails" do
    parent = self()

    assert {:error, :setup_failed} =
             verified_unboxed_transaction(fn ->
               fixture = fixture!()
               send(parent, {:rolled_back_fixture, fixture.event.id})
               Repo.rollback(:setup_failed)
             end)

    assert_receive {:rolled_back_fixture, event_id}

    assert [[0]] =
             Repo.query!("SELECT count(*)::integer FROM events WHERE id = $1::uuid", [
               uuid(event_id)
             ]).rows
  end

  test "verified cleanup removes its committed fixture and preserves unrelated data" do
    unrelated = fixture!()
    {:ok, committed} = verified_unboxed_transaction(fn -> fixture!() end)

    try do
      assert {:ok, _} = cleanup!(committed)

      assert [[0]] =
               Repo.query!("SELECT count(*)::integer FROM events WHERE id = $1::uuid", [
                 uuid(committed.event.id)
               ]).rows

      assert [[1]] =
               Repo.query!("SELECT count(*)::integer FROM events WHERE id = $1::uuid", [
                 uuid(unrelated.event.id)
               ]).rows
    after
      cleanup!(committed)
    end
  end

  test "all affected competitions enter review, unrelated sides stay provisional and retries do not write" do
    f = fixture!()

    assert {:ok, {:ok, results}} =
             transact(f, fn review ->
               assert {:ok, first} = review.(f.revision_id, 2)
               assert {:ok, second} = review.(f.revision_id, 2)

               assert Enum.map(first, &{&1.id, &1.updated_at}) ==
                        Enum.map(second, &{&1.id, &1.updated_at})

               {:ok, second}
             end)

    assert Enum.sort(Enum.map(results, & &1.id)) == Enum.sort(f.affected_result_ids)
    assert Enum.all?(results, &(&1.state == :review_required))
    assert state(f.unrelated_result_id) == "provisional"

    for id <- f.affected_result_ids do
      assert {:ok, %{status: :corrected_score_awaiting_verification, blockers: [%{revision: 2}]}} =
               LoadSideReviewReason.run(f.admin, f.event.id, f.round.id, id)
    end
  end

  test "private action rejects absent, forged and cross-side context; generic transition remains blocked" do
    f = fixture!()
    result = Ash.get!(CompetitionSideResult, hd(f.affected_result_ids), authorize?: false)

    for context <- [
          %{},
          %{
            corrected_score_review: %{
              token: make_ref(),
              result_id: result.id,
              side_id: f.secondary_side.id,
              score_revision_id: f.revision_id,
              revision: 2
            }
          }
        ] do
      assert {:error, _} =
               result
               |> Changeset.for_update(:require_review_for_corrected_score_internal, %{})
               |> Changeset.set_context(context)
               |> Ash.update(authorize?: false)
    end

    assert {:error, _} =
             result
             |> Changeset.for_update(:mark_review_required, %{})
             |> Ash.update(authorize?: false)

    assert state(result.id) == "provisional"
  end

  test "an escaped review capability cannot be replayed after coordinator cleanup" do
    f = fixture!()
    assert {:ok, {:ok, escaped}} = transact(f, fn review -> {:ok, review} end)

    assert {:error, :invalid_review_scope} =
             Repo.transaction(fn -> escaped.(f.revision_id, 2) end)

    assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
  end

  test "wrong revisions, absent correction history and non-pending verification fail closed" do
    f = fixture!()

    for {revision_id, expected} <- [
          {f.revision_id, 1},
          {f.revision_id, 3},
          {Ecto.UUID.generate(), 2}
        ] do
      assert {:error, :correction_blocker_not_found} =
               transact(f, fn review -> review.(revision_id, expected) end)
    end

    assert {:error, :correction_blocker_not_found} =
             Repo.transaction(fn ->
               Repo.query!(
                 "UPDATE score_verifications SET status = 'overridden', overridden_by_staff_user_id = $2::uuid, override_reason = 'test' WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
                 [uuid(f.hole_id), uuid(f.admin.id)]
               )

               Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn review ->
                 review.(f.revision_id, 2)
               end)
             end)

    assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
  end

  test "missing membership and missing side results reject the entire operation" do
    f = fixture!()

    assert {:error, :affected_side_scope_changed} =
             transact(f, fn review ->
               Repo.query!(
                 "DELETE FROM competition_side_memberships WHERE competition_side_id = $1::uuid AND round_entry_id = $2::uuid",
                 [uuid(f.secondary_side.id), uuid(hd(f.entries).id)]
               )

               review.(f.revision_id, 2)
             end)

    assert {:error, :missing_side_result} =
             Repo.transaction(fn ->
               Repo.query!("DELETE FROM competition_side_results WHERE id = $1::uuid", [
                 uuid(hd(f.affected_result_ids))
               ])

               Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn review ->
                 review.(f.revision_id, 2)
               end)
             end)

    assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
  end

  test "ready, finalized and excluded side results reject review and do not change another side" do
    f = fixture!()

    for invalid <- ["ready_to_finalize", "finalized", "excluded"] do
      assert {:error, :unsupported_side_result_state} =
               Repo.transaction(fn ->
                 set_state!(f, hd(f.affected_result_ids), invalid)

                 Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn review ->
                   review.(f.revision_id, 2)
                 end)
               end)

      assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
    end
  end

  test "caller rollback removes review changes and all synthetic correction evidence together" do
    f = fixture!(false)

    assert {:error, :deliberate_failure} =
             transact(f, fn review ->
               revision = correction!(f)
               assert {:ok, results} = review.(revision, 2)
               assert Enum.all?(results, &(&1.state == :review_required))
               Repo.rollback(:deliberate_failure)
             end)

    assert [[1]] =
             Repo.query!("SELECT revision FROM hole_results WHERE id = $1::uuid", [
               uuid(f.hole_id)
             ]).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM score_revisions WHERE hole_result_id = $1::uuid",
               [uuid(f.hole_id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM score_verifications WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
               [uuid(f.hole_id)]
             ).rows

    assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
  end

  test "authorization, round scope and transaction ownership are enforced" do
    f = fixture!()

    assert {:error, :forbidden} =
             Repo.transaction(fn ->
               Review.with_locked_scope(
                 %{id: f.admin.id},
                 f.event.id,
                 f.round.id,
                 f.hole_id,
                 fn _ -> flunk("unauthenticated actor reached callback") end
               )
             end)

    assert {:error, :invalid_scope} =
             Repo.transaction(fn ->
               Review.with_locked_scope(
                 f.admin,
                 f.event.id,
                 Ecto.UUID.generate(),
                 f.hole_id,
                 fn _ -> flunk("wrong scope reached callback") end
               )
             end)

    assert {:error, :transaction_required} =
             Sandbox.unboxed_run(Repo, fn ->
               Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn _ ->
                 flunk("missing transaction reached callback")
               end)
             end)

    assert {:error, :nested_review_scope} =
             transact(f, fn _ ->
               Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn _ ->
                 flunk("nested lock acquisition reached callback")
               end)
             end)
  end

  @tag :real_concurrency
  test "two independent transactions serialize review and the second observes an unchanged review timestamp" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          transact(f, fn review ->
            assert {:ok, results} = review.(f.revision_id, 2)
            send(parent, {:review_held, backend_pid!()})

            receive do
              :release -> {:ok, results}
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    try do
      assert_receive {:review_held, holder_pid}, 10_000

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              send(parent, {:contender, backend_pid!()})

              Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fn review ->
                review.(f.revision_id, 2)
              end)
            end)
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, {:ok, first}} = Task.await(holder, 15_000)
        assert {:ok, {:ok, second}} = Task.await(contender, 15_000)

        assert Enum.map(first, &{&1.id, &1.updated_at}) ==
                 Enum.map(second, &{&1.id, &1.updated_at})
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
      cleanup!(f)
    end
  end

  @tag :real_concurrency
  test "membership replacement waits for the round lock then rechecks the scoring lifecycle" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    parent = self()

    holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _} = LockProtocol.acquire!(round: [f.round.id])
            send(parent, {:round_held, backend_pid!()})

            receive do
              :release -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)
      end)

    try do
      assert_receive {:round_held, holder_pid}, 10_000

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:membership, backend_pid!()})

            Competition.set_side_membership(
              f.admin,
              f.event.id,
              f.round.id,
              f.secondary_competition.id,
              f.secondary_side.id,
              Enum.map(Enum.take(f.entries, 2), & &1.id)
            )
          end)
        end)

      try do
        assert_receive {:membership, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, :ok} = Task.await(holder, 15_000)
        assert {:error, {:invalid_round_state, :scoring_open}} = Task.await(contender, 15_000)
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
      cleanup!(f)
    end
  end

  defp transact(f, fun) do
    Repo.transaction(fn ->
      Review.with_locked_scope(f.admin, f.event.id, f.round.id, f.hole_id, fun)
    end)
  end

  defp fixture!(corrected? \\ true) do
    f = Fixtures.setup_submit_fixture!(4)
    Fixtures.set_round_state!(f.round, :draft)

    secondary =
      RoundCompetition
      |> Changeset.for_create(:configure_internal, %{
        event_id: f.event.id,
        round_id: f.round.id,
        is_primary: false
      })
      |> Ash.create!(authorize?: false)

    sides =
      for {competition, entries} <- [
            {f.competition, Enum.take(f.entries, 2)},
            {secondary, Enum.take(f.entries, 2)},
            {f.competition, Enum.drop(f.entries, 2)}
          ] do
        {:ok, side} =
          Competition.create_competition_side(
            f.admin,
            f.event.id,
            f.round.id,
            competition.id,
            :partnership
          )

        {:ok, _} =
          Competition.set_side_membership(
            f.admin,
            f.event.id,
            f.round.id,
            competition.id,
            side.id,
            Enum.map(entries, & &1.id)
          )

        [[result_id]] =
          Repo.query!(
            "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
            [uuid(side.id)]
          ).rows

        {side, result_id}
      end

    [{_, first}, {secondary_side, second}, {_, unrelated}] = sides
    Fixtures.set_round_state!(f.round, :scoring_open)

    command = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: f.group.id,
      round_hole_id: f.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }

    assert {:ok, _} = Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, command)

    [[hole, card]] =
      Repo.query!(
        "SELECT hr.id::text, hr.scorecard_id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid AND hr.round_hole_id = $2::uuid",
        [uuid(hd(f.entries).id), uuid(f.start_hole.id)]
      ).rows

    f =
      Map.merge(f, %{
        affected_result_ids: [first, second],
        unrelated_result_id: unrelated,
        secondary_side: secondary_side,
        secondary_competition: secondary,
        hole_id: hole,
        card_id: card
      })

    Map.put(f, :revision_id, if(corrected?, do: correction!(f), else: nil))
  end

  # Synthetic evidence only; the correction writer is outside this task.
  defp correction!(f) do
    Repo.query!("UPDATE hole_results SET revision = 2, gross_strokes = 5 WHERE id = $1::uuid", [
      uuid(f.hole_id)
    ])

    [[revision]] =
      Repo.query!(
        "INSERT INTO score_revisions (hole_result_id, scorecard_id, round_id, actor_staff_user_id, original_revision, resulting_revision, original_outcome, original_gross_strokes, new_outcome, new_gross_strokes, reason) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, 2, 'holed_out', 4, 'holed_out', 5, 'test') RETURNING id::text",
        [uuid(f.hole_id), uuid(f.card_id), uuid(f.round.id), uuid(f.admin.id)]
      ).rows

    Repo.query!(
      "INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id) VALUES ($1::uuid, 2, $2::uuid, $3::uuid, $4::uuid, $5::uuid)",
      [
        uuid(f.hole_id),
        uuid(f.card_id),
        uuid(f.round.id),
        uuid(f.group.id),
        uuid(hd(f.entries).id)
      ]
    )

    revision
  end

  defp set_state!(f, id, "excluded") do
    Repo.query!(
      "UPDATE competition_side_results SET state = 'excluded', excluded_by_staff_user_id = $2::uuid, exclusion_reason = 'test', excluded_at = now(), excluded_playing_group_id = $3::uuid, excluded_effective_round_hole_id = $4::uuid, excluded_effective_play_index = 0, excluded_preplay_confirmed = true WHERE id = $1::uuid",
      [uuid(id), uuid(f.admin.id), uuid(f.group.id), uuid(f.start_hole.id)]
    )
  end

  defp set_state!(_, id, state),
    do:
      Repo.query!("UPDATE competition_side_results SET state = $2 WHERE id = $1::uuid", [
        uuid(id),
        state
      ])

  defp state(id),
    do:
      Repo.query!("SELECT state FROM competition_side_results WHERE id = $1::uuid", [uuid(id)]).rows
      |> hd()
      |> hd()

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp await_blocked!(waiting, blocker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000

    [[blocked?]] =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SELECT $1::integer = ANY(pg_blocking_pids($2::integer))", [blocker, waiting]).rows
      end)

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected independent PostgreSQL transactions to block")

      true ->
        Process.sleep(10)
        await_blocked!(waiting, blocker, deadline)
    end
  end

  defp validate_test_identity!(:test, [["golf_scoring_test", "golf_scoring_test"]], %{
         "CI" => nil,
         "GITHUB_ACTIONS" => nil,
         "GITHUB_REPOSITORY" => nil
       }),
       do: :ok

  defp validate_test_identity!(:test, [["golf_scoring_test", "golf_scoring_ci"]], %{
         "CI" => "true",
         "GITHUB_ACTIONS" => "true",
         "GITHUB_REPOSITORY" => "JCSchoeman96/golf-scoring"
       }),
       do: :ok

  defp validate_test_identity!(_environment, _rows, _runner),
    do: raise("refusing unboxed writes outside the allocated test database and role")

  defp verified_unboxed_transaction(callback) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        rows = Repo.query!("SELECT current_database(), current_user").rows
        runner = Map.new(["CI", "GITHUB_ACTIONS", "GITHUB_REPOSITORY"], &{&1, System.get_env(&1)})
        validate_test_identity!(Mix.env(), rows, runner)
        callback.()
      end)
    end)
  end

  defp cleanup!(f), do: verified_unboxed_transaction(fn -> delete_fixture_rows!(f) end)

  defp delete_fixture_rows!(f) do
    round = uuid(f.round.id)

    for {sql, params} <- [
          {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_revisions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM hole_results WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM hole_submissions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM audit_events WHERE context->>'round_id' = $1", [f.round.id]},
          {"DELETE FROM scorecards WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
           [round]},
          {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_sides WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM group_role_assignments WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_entries WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM playing_groups WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_competitions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
           [round]},
          {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_holes WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM rounds WHERE id = $1::uuid", [round]},
          {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid", [uuid(f.tee_profile.id)]},
          {"DELETE FROM tee_sets WHERE id = $1::uuid", [uuid(f.tee_set.id)]},
          {"DELETE FROM course_holes WHERE course_id = $1::uuid", [uuid(f.course.id)]},
          {"DELETE FROM courses WHERE id = $1::uuid", [uuid(f.course.id)]},
          {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [uuid(f.event.id)]},
          {"DELETE FROM events WHERE id = $1::uuid", [uuid(f.event.id)]},
          {"DELETE FROM staff_users WHERE id = $1::uuid", [uuid(f.admin.id)]}
        ],
        do: Repo.query!(sql, params)

    for entry <- f.entries,
        do: Repo.query!("DELETE FROM players WHERE id = $1::uuid", [uuid(entry.player_id)])
  end
end
