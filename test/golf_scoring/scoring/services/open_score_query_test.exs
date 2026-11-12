defmodule GolfScoring.Scoring.Services.OpenScoreQueryTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures
  alias GolfScoring.Scoring.Services.ScoreQueryNotifier

  test "staff query opens against current evidence and reviews every affected result atomically" do
    f = fixture!()
    before = score_evidence(f)
    assert {:ok, opened} = query(f)
    assert opened.score_query.status == :open
    assert opened.score_query.hole_result_revision == 1
    assert opened.score_query.requested_by_staff_user_id == f.admin.id
    assert opened.score_query.reason == "suspected error"
    assert opened.scorecard.state == :review_required
    assert Enum.sort(Enum.map(opened.side_results, & &1.id)) == Enum.sort(f.affected_result_ids)
    assert Enum.all?(opened.side_results, &(&1.state == :review_required))
    assert state(f.unrelated_result_id) == "provisional"
    assert opened.audit.action == "query_hole_result"
    assert score_evidence(f) == before
  end

  test "a noncompetitive result still reviews its scorecard" do
    f = fixture!()

    Repo.query!("DELETE FROM competition_side_memberships WHERE round_entry_id = $1::uuid", [
      uuid(hd(f.entries).id)
    ])

    assert {:ok, opened} = query(f)
    assert opened.side_results == []
    assert opened.scorecard.state == :review_required
    assert Enum.all?(f.affected_result_ids, &(state(&1) == "provisional"))
  end

  test "stale revisions and invalid reasons do not create disputes or change readiness" do
    f = fixture!()
    initial = snapshot(f)

    for command <- [
          %{expected_revision: 2},
          %{expected_revision: 0},
          %{reason: " "},
          %{reason: String.duplicate("x", 4097)},
          %{hole_result_id: "invalid"}
        ] do
      assert {:error, _} = query(f, command)
      assert snapshot(f) == initial
    end

    Repo.query!(
      "UPDATE hole_results SET outcome = 'picked_up', gross_strokes = NULL WHERE id = $1::uuid",
      [uuid(f.hole_id)]
    )

    assert {:ok, _} = query(f)
  end

  test "another unresolved query is an explicit conflict rather than an idempotent retry" do
    f = fixture!()
    assert {:ok, opened} = query(f)
    initial = snapshot(f)
    assert {:error, :unresolved_score_query} = query(f)
    assert snapshot(f) == initial

    Repo.query!("UPDATE score_queries SET status = 'escalated' WHERE id = $1::uuid", [
      uuid(opened.score_query.id)
    ])

    initial = snapshot(f)
    assert {:error, :unresolved_score_query} = query(f)
    assert snapshot(f) == initial
  end

  test "only live authenticated same-event admin or manager authority may open" do
    f = fixture!()
    other = fixture!()
    initial = snapshot(f)
    assert {:error, _} = query(f, %{}, %{id: f.admin.id})
    assert {:error, _} = query(f, %{}, other.admin)
    command = %{hole_result_id: f.hole_id, expected_revision: 1, reason: "test"}
    assert {:error, _} = Scoring.query_hole_result(f.admin, other.event.id, f.round.id, command)
    assert {:error, _} = Scoring.query_hole_result(f.admin, f.event.id, other.round.id, command)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    assert {:error, _} = query(f)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'active', role = 'scoring_support' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    assert {:error, _} = query(f)

    Repo.query!(
      "UPDATE event_staff_assignments SET role = 'competition_manager' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, _} = query(f)
    assert snapshot(f) == initial

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [uuid(f.admin.id)])

    assert {:ok, _} = query(f)
  end

  test "unsupported round, card and side states fail without partial dispute evidence" do
    f = fixture!()

    for round_state <- [:draft, :ready, :finalized, :cancelled] do
      Fixtures.set_round_state!(f.round, round_state)
      initial = snapshot(f)
      assert {:error, _} = query(f)
      assert snapshot(f) == initial
    end

    Fixtures.set_round_state!(f.round, :scoring_open)

    for card_state <- ["not_started", "review_required", "verified"] do
      Repo.query!("UPDATE scorecards SET state = $2 WHERE id = $1::uuid", [
        uuid(f.card_id),
        card_state
      ])

      initial = snapshot(f)
      assert {:error, _} = query(f)
      assert snapshot(f) == initial
    end

    Repo.query!("UPDATE scorecards SET state = 'in_progress' WHERE id = $1::uuid", [
      uuid(f.card_id)
    ])

    for side_state <- ["review_required", "ready_to_finalize", "finalized", "excluded"] do
      set_state!(f, hd(f.affected_result_ids), "provisional")
      set_state!(f, hd(f.affected_result_ids), side_state)
      initial = snapshot(f)
      assert {:error, _} = query(f)
      assert snapshot(f) == initial
    end
  end

  test "scoring-closed and complete card remain supported" do
    f = fixture!()
    Fixtures.set_round_state!(f.round, :scoring_closed)
    Repo.query!("UPDATE scorecards SET state = 'complete' WHERE id = $1::uuid", [uuid(f.card_id)])
    assert {:ok, opened} = query(f)
    assert opened.scorecard.state == :review_required
  end

  test "missing side results fail closed" do
    f = fixture!()

    Repo.query!("DELETE FROM competition_side_results WHERE id = $1::uuid", [
      uuid(hd(f.affected_result_ids))
    ])

    initial = snapshot(f)
    assert {:error, :invalid_side_membership} = query(f)
    assert snapshot(f) == initial
  end

  test "inconsistent peer group membership is not silently dropped" do
    f = fixture!()

    Repo.query!("UPDATE round_entries SET playing_group_id = NULL WHERE id = $1::uuid", [
      uuid(Enum.at(f.entries, 1).id)
    ])

    initial = snapshot(f)
    assert {:error, :invalid_side_membership} = query(f)
    assert snapshot(f) == initial
  end

  test "private actions and forged context cannot create query-only or review-only commits" do
    f = fixture!()
    initial = snapshot(f)

    attrs = %{
      hole_result_id: f.hole_id,
      scorecard_id: f.card_id,
      round_id: f.round.id,
      hole_result_revision: 1,
      requested_by_staff_user_id: f.admin.id,
      reason: "forged"
    }

    for context <- [
          %{},
          %{score_query_open: make_ref()},
          %{score_query_open: %{authorized: true}}
        ] do
      assert {:error, _} =
               Repo.transaction(fn ->
                 GolfScoring.Scoring.ScoreQuery
                 |> Changeset.for_create(:open_internal, attrs)
                 |> Changeset.set_context(context)
                 |> Ash.create(authorize?: false)
                 |> rollback_error!()
               end)

      for {resource, id} <- [
            {GolfScoring.Scoring.Scorecard, f.card_id},
            {GolfScoring.Competition.CompetitionSideResult, hd(f.affected_result_ids)}
          ] do
        assert {:error, _} =
                 Repo.transaction(fn ->
                   resource
                   |> Ash.get!(id, authorize?: false)
                   |> Changeset.for_update(:require_review_for_open_query_internal, %{})
                   |> Changeset.set_context(context)
                   |> Ash.update(authorize?: false)
                   |> rollback_error!()
                 end)
      end

      assert snapshot(f) == initial
    end

    assert {:error, _} =
             GolfScoring.Competition.CompetitionSideResult
             |> Ash.get!(hd(f.affected_result_ids), authorize?: false)
             |> Changeset.for_update(:mark_review_required, %{})
             |> Ash.update(authorize?: false)

    assert snapshot(f) == initial
  end

  test "audit rejection rolls back query, scorecard and every affected side with no notification" do
    f = fixture!()
    initial = snapshot(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_query_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_query_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action = 'query_hole_result') EXECUTE FUNCTION pg_temp.reject_query_audit()"
    )

    assert {:error, _} = query(f)
    assert snapshot(f) == initial
    refute_receive {:score_query_opened, _}
    assert is_nil(Process.get({GolfScoring.Scoring.Services.OpenScoreQuery, :open}))
  end

  test "last-side rejection rolls back the earlier side and scorecard transitions" do
    f = fixture!()
    initial = snapshot(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    [[last]] =
      Repo.query!(
        "SELECT csr.id::text FROM competition_side_results csr JOIN competition_sides cs ON cs.id = csr.competition_side_id WHERE csr.id = ANY($1::uuid[]) ORDER BY cs.id DESC LIMIT 1",
        [Enum.map(f.affected_result_ids, &uuid/1)]
      ).rows

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_query_side() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated side failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_query_side BEFORE UPDATE ON competition_side_results FOR EACH ROW WHEN (NEW.id = '#{last}'::uuid AND NEW.state = 'review_required') EXECUTE FUNCTION pg_temp.reject_query_side()"
    )

    assert {:error, _} = query(f)
    assert snapshot(f) == initial
    refute_receive {:score_query_opened, _}
  end

  test "outer transaction ownership and exact nonsensitive notification contract" do
    f = fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    assert {:ok, {:error, :outer_transaction_required}} = Repo.transaction(fn -> query(f) end)
    refute_receive {:score_query_opened, _}
    assert {:ok, opened} = query(f)
    assert opened.notification == :ok
    assert_receive {:score_query_opened, payload}

    assert payload == %{
             event_id: f.event.id,
             round_id: f.round.id,
             score_query_id: opened.score_query.id,
             hole_result_id: f.hole_id,
             scorecard_id: f.card_id,
             hole_result_revision: 1,
             affected_side_result_ids: Enum.map(opened.side_results, & &1.id)
           }

    refute_receive {:score_query_opened, _}
    assert {:error, :pubsub_unavailable} = ScoreQueryNotifier.publish(opened, GLS41MissingPubSub)
  end

  @tag :real_concurrency
  test "two queries serialize into one dispute and an explicit conflict" do
    competing!(:query, :query)
  end

  @tag :real_concurrency
  test "correction cannot pass a committed query blocker" do
    competing!(:query, :correction)
  end

  @tag :real_concurrency
  test "query cannot attach stale evidence after a competing correction" do
    competing!(:correction, :query)
  end

  defp competing!(first, second) do
    f = recorded_cleanup_fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    parent = self()

    holder =
      Task.async(fn ->
        receive do
          :start -> Sandbox.unboxed_run(Repo, fn -> operation(f, first) end)
        end
      end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:golf_scoring, :repo, :query], &__MODULE__.hold_write/4, %{
        owner: holder.pid,
        parent: parent,
        operation: first
      })

    send(holder.pid, :start)

    try do
      assert_receive {:write_held, holder_pid}, 10_000
      refute_receive {:score_query_opened, _}

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:contender, backend_pid!()})
            operation(f, second)
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, _} = Task.await(holder, 15_000)
        assert {:error, error} = Task.await(contender, 15_000)
        if first == :query and second == :query, do: assert(error == :unresolved_score_query)

        {:ok, rows} =
          verified_unboxed_transaction(fn ->
            Repo.query!(
              "SELECT hr.revision, count(q.id)::integer FROM hole_results hr LEFT JOIN score_queries q ON q.hole_result_id = hr.id WHERE hr.id = $1::uuid GROUP BY hr.revision",
              [uuid(f.hole_id)]
            ).rows
          end)

        if first == :query do
          assert rows == [[1, 1]]
          assert_receive {:score_query_opened, _}
        else
          assert rows == [[2, 0]]
        end

        refute_receive {:score_query_opened, _}
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      :telemetry.detach(handler)
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
      cleanup!(f)
    end
  end

  @doc false
  def hold_write(_event, _measurements, metadata, %{
        owner: owner,
        parent: parent,
        operation: operation
      }) do
    matches? =
      case operation do
        :query ->
          String.contains?(metadata.query, "INSERT INTO") and
            String.contains?(metadata.query, "\"score_queries\"")

        :correction ->
          String.contains?(metadata.query, "UPDATE") and
            String.contains?(metadata.query, "\"hole_results\"")
      end

    if self() == owner and matches? do
      send(parent, {:write_held, backend_pid!()})

      receive do
        :release -> :ok
      after
        10_000 -> raise "timed out holding query/correction transaction"
      end
    end
  end

  defp operation(f, :query), do: query(f)

  defp operation(f, :correction),
    do:
      Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        new_gross_strokes: 6,
        reason: "test correction"
      })

  defp rollback_error!({:error, error}), do: Repo.rollback(error)
  defp rollback_error!(_), do: flunk("private action bypassed coordinator proof")

  defp snapshot(f) do
    Map.merge(score_evidence(f), %{
      queries:
        Repo.query!(
          "SELECT id, status, reason FROM score_queries WHERE hole_result_id = $1::uuid ORDER BY id",
          [uuid(f.hole_id)]
        ).rows,
      card:
        Repo.query!("SELECT state, updated_at FROM scorecards WHERE id = $1::uuid", [
          uuid(f.card_id)
        ]).rows,
      sides:
        Repo.query!(
          "SELECT id, state, updated_at FROM competition_side_results WHERE id = ANY($1::uuid[]) ORDER BY id",
          [Enum.map(f.affected_result_ids ++ [f.unrelated_result_id], &uuid/1)]
        ).rows,
      audit:
        Repo.query!(
          "SELECT id FROM audit_events WHERE action = 'query_hole_result' AND context->>'hole_result_id' = $1 ORDER BY id",
          [f.hole_id]
        ).rows
    })
  end

  defp query(f, command \\ %{}, actor \\ nil) do
    Scoring.query_hole_result(
      actor || f.admin,
      f.event.id,
      f.round.id,
      Map.merge(
        %{hole_result_id: f.hole_id, expected_revision: 1, reason: "suspected error"},
        command
      )
    )
  end

  defp score_evidence(f) do
    %{
      result:
        Repo.query!(
          "SELECT revision, outcome, gross_strokes FROM hole_results WHERE id = $1::uuid",
          [uuid(f.hole_id)]
        ).rows,
      revisions:
        Repo.query!(
          "SELECT id FROM score_revisions WHERE hole_result_id = $1::uuid ORDER BY id",
          [uuid(f.hole_id)]
        ).rows,
      verifications:
        Repo.query!(
          "SELECT id, status, hole_result_revision FROM score_verifications WHERE hole_result_id = $1::uuid ORDER BY id",
          [uuid(f.hole_id)]
        ).rows,
      group:
        Repo.query!("SELECT scoring_revision, state FROM playing_groups WHERE id = $1::uuid", [
          uuid(f.group.id)
        ]).rows
    }
  end

  defp fixture! do
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

    {:ok, verifier_assignment} =
      Competition.assign_designated_verifier(
        f.admin,
        f.event.id,
        f.round.id,
        f.group.id,
        Enum.at(f.entries, 1).id
      )

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
        verifier_assignment: verifier_assignment,
        affected_result_ids: [first, second],
        unrelated_result_id: unrelated,
        secondary_side: secondary_side,
        secondary_competition: secondary,
        hole_id: hole,
        card_id: card
      })

    f
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
         "GITHUB_REPOSITORY" => "Carpe-Diem-Media/golf-scoring"
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

  defp recorded_cleanup_fixture! do
    {:ok, fixture} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit({:owned_cleanup_fixture, fixture.event.id}, fn -> cleanup!(fixture) end)

    IO.puts(
      "GLS-41 E1 owned fixture " <>
        inspect(%{
          event_id: fixture.event.id,
          round_id: fixture.round.id,
          hole_result_id: fixture.hole_id,
          scorecard_id: fixture.card_id,
          side_result_ids: fixture.affected_result_ids ++ [fixture.unrelated_result_id]
        })
    )

    fixture
  end

  defp cleanup!(f) do
    verified_unboxed_transaction(fn ->
      # Test-only DDL, after same-connection identity validation. The exclusive
      # lock is held until commit, so other sessions cannot use a disabled guard.
      Repo.query!("SET LOCAL lock_timeout = '5s'")
      Repo.query!("LOCK TABLE public.score_revisions IN ACCESS EXCLUSIVE MODE")

      Repo.query!(
        "ALTER TABLE public.score_revisions DISABLE TRIGGER score_revisions_immutable_rows"
      )

      try do
        delete_fixture_rows!(f)
      after
        Repo.query!(
          "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_rows"
        )
      end

      assert [["A"], ["A"]] =
               Repo.query!(
                 "SELECT tgenabled::text FROM pg_trigger WHERE tgrelid = 'public.score_revisions'::regclass AND tgname IN ('score_revisions_immutable_rows', 'score_revisions_immutable_truncate') ORDER BY tgname"
               ).rows
    end)
  end

  defp delete_fixture_rows!(f) do
    round = uuid(f.round.id)

    for {sql, params} <- [
          {"DELETE FROM score_queries WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [uuid(f.event.id)]},
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
