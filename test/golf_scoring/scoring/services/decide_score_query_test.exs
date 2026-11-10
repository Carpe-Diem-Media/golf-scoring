defmodule GolfScoring.Scoring.Services.DecideScoreQueryTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.ScoreQuery
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  test "authorized no-change resolution from open" do
    f = opened_fixture!()
    before = evidence(f)

    assert {:ok, result} =
             decide(f, %{reason: "accept current score", decision: :resolve_no_change})

    assert result.score_query.status == :resolved
    assert result.score_query.reason == "original dispute"
    assert result.audit.action == "resolve_score_query_no_change"
    assert result.audit.changes == %{"status" => %{"from" => "open", "to" => "resolved"}}
    assert evidence(f) == before
  end

  test "authorized no-change resolution from escalated" do
    f = opened_fixture!() |> escalate!()

    assert {:ok, result} =
             decide(f, %{reason: "accept after review", decision: :resolve_no_change})

    assert result.score_query.status == :resolved
    assert result.audit.changes == %{"status" => %{"from" => "escalated", "to" => "resolved"}}
  end

  test "authorized dismissal from open and escalated" do
    f = opened_fixture!()

    assert {:ok, dismissed} =
             decide(f, %{reason: "withdrawn dispute", decision: :dismiss})

    assert dismissed.score_query.status == :dismissed
    assert dismissed.audit.action == "dismiss_score_query"

    f = opened_fixture!() |> escalate!()

    assert {:ok, dismissed2} =
             decide(f, %{reason: "staff dismissal", decision: :dismiss})

    assert dismissed2.score_query.status == :dismissed

    assert dismissed2.audit.changes == %{
             "status" => %{"from" => "escalated", "to" => "dismissed"}
           }
  end

  test "event_admin and competition_manager only; scoring_support denied" do
    for role <- ["event_admin", "competition_manager"],
        f = opened_fixture!() do
      set_role!(f, role)
      assert {:ok, _} = decide(f, %{decision: :dismiss, reason: "ok"})
    end

    f = opened_fixture!()
    set_role!(f, "scoring_support")
    before = snapshot(f)
    assert {:error, :not_found_or_forbidden} = decide(f, %{decision: :dismiss, reason: "nope"})
    assert snapshot(f) == before
  end

  test "revoked, inactive, cross-event and insufficient-role staff rejected" do
    f = opened_fixture!()
    before = snapshot(f)

    set_role!(f, "registration_staff")
    assert {:error, :not_found_or_forbidden} = decide(f, %{decision: :dismiss, reason: "x"})
    set_role!(f, "event_admin")

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, :not_found_or_forbidden} = decide(f, %{decision: :dismiss, reason: "x"})

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [uuid(f.admin.id)])

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    assert {:error, :not_found_or_forbidden} = decide(f, %{decision: :dismiss, reason: "x"})

    other = opened_fixture!()

    assert {:error, :not_found_or_forbidden} =
             Scoring.decide_score_query(f.admin, other.event.id, f.round.id, command(f))

    assert snapshot(f) == before
  end

  test "wrong scope and stale revision rejected" do
    f = opened_fixture!()
    before = snapshot(f)

    other = opened_fixture!()

    assert {:error, :not_found_or_forbidden} =
             decide(f, %{score_query_id: other.query_id, decision: :dismiss, reason: "x"})

    assert {:error, _} = decide(f, %{expected_revision: 2, decision: :dismiss, reason: "x"})
    assert snapshot(f) == before

    Repo.query!("UPDATE hole_results SET revision = 2 WHERE id = $1::uuid", [uuid(f.hole_id)])
    before = snapshot(f)
    assert {:error, :stale_revision} = decide(f, %{decision: :dismiss, reason: "x"})
    assert snapshot(f) == before
  end

  test "invalid inputs and unsupported correction decision rejected" do
    f = opened_fixture!()
    before = snapshot(f)

    for attrs <- [
          %{reason: " "},
          %{reason: <<255>>},
          %{reason: String.duplicate("x", 4097)},
          %{expected_revision: 0},
          %{score_query_id: "bad"},
          %{decision: :resolve_with_correction, reason: "correction path"},
          %{decision: :bad, reason: "x"}
        ] do
      assert {:error, _} = decide(f, attrs)
      assert snapshot(f) == before
    end

    assert {:error, :unsupported_decision} =
             decide(f, %{decision: :resolve_with_correction, reason: "correction"})

    assert {:error, :invalid_decision} = decide(f, %{decision: :bogus, reason: "x"})
  end

  test "terminal queries cannot transition again" do
    f = opened_fixture!()
    assert {:ok, _} = decide(f, %{decision: :resolve_no_change, reason: "done"})
    before = snapshot(f)
    assert {:error, :terminal_query} = decide(f, %{decision: :dismiss, reason: "again"})
    assert snapshot(f) == before
  end

  test "direct private Ash actions fail without coordinator capability" do
    f = opened_fixture!()
    before = snapshot(f)

    for action <- [:resolve_no_change_internal, :dismiss_internal] do
      for context <- [%{}, %{score_query_decision: make_ref()}] do
        assert {:error, _} = direct_action(f, action, context)
        assert snapshot(f) == before
      end
    end
  end

  test "audit failure rolls back the terminal update" do
    f = opened_fixture!()
    before = snapshot(f)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_decide_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_decide_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action IN ('resolve_score_query_no_change', 'dismiss_score_query')) EXECUTE FUNCTION pg_temp.reject_decide_audit()"
    )

    assert {:error, _} = decide(f, %{decision: :dismiss, reason: "x"})
    assert snapshot(f) == before
  end

  test "outer transaction ownership enforced" do
    f = opened_fixture!()

    assert {:ok, {:error, :outer_transaction_required}} =
             Repo.transaction(fn ->
               decide(f, %{decision: :dismiss, reason: "nested"})
             end)
  end

  test "public wrappers reject non-map commands" do
    f = opened_fixture!()

    for bad <- [nil, [], "string", 1] do
      assert {:error, :invalid_input} =
               Scoring.resolve_score_query_no_change(f.admin, f.event.id, f.round.id, bad)

      assert {:error, :invalid_input} =
               Scoring.dismiss_score_query(f.admin, f.event.id, f.round.id, bad)
    end
  end

  test "wrapper entrypoints set decision" do
    f = opened_fixture!()

    assert {:ok, r1} =
             Scoring.resolve_score_query_no_change(f.admin, f.event.id, f.round.id, %{
               score_query_id: f.query_id,
               expected_revision: 1,
               reason: "accept"
             })

    assert r1.score_query.status == :resolved

    f = opened_fixture!()

    assert {:ok, r2} =
             Scoring.dismiss_score_query(f.admin, f.event.id, f.round.id, %{
               score_query_id: f.query_id,
               expected_revision: 1,
               reason: "dismiss"
             })

    assert r2.score_query.status == :dismissed
  end

  test "no-change resolution leaves scoring and review evidence unchanged" do
    f = opened_fixture!()
    before = evidence(f)

    assert {:ok, _} = decide(f, %{decision: :resolve_no_change, reason: "unchanged"})

    assert evidence(f) == before
    assert review_states(f) == [["review_required"], ["review_required"]]
    assert card_state(f) == "review_required"
    assert {:error, _} = correct(f)
  end

  @tag :real_concurrency
  test "two independent decisions commit one transition, audit and terminal status" do
    competing!(:decisions)
  end

  @tag :real_concurrency
  test "concurrent escalation remains safe against an in-flight decision" do
    competing!(:escalation)
  end

  defp fixture!, do: build_fixture!()

  defp build_fixture! do
    previous_prefix = Process.get(:gls34_prefix)
    Process.put(:gls34_prefix, "gls41-j4b1-" <> Ecto.UUID.generate())

    try do
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

      [{_, first}, {_, second}, _] = sides

      Fixtures.set_round_state!(f.round, :scoring_open)

      submit = %{
        client_submission_id: Ecto.UUID.generate(),
        playing_group_id: f.group.id,
        round_hole_id: f.start_hole.id,
        expected_group_score_revision: 0,
        captured_at: DateTime.utc_now(),
        results:
          Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
      }

      assert {:ok, _} = Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, submit)

      [[hole, card]] =
        Repo.query!(
          "SELECT hr.id::text, hr.scorecard_id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid AND hr.round_hole_id = $2::uuid",
          [uuid(hd(f.entries).id), uuid(f.start_hole.id)]
        ).rows

      Map.merge(f, %{affected_result_ids: [first, second], hole_id: hole, card_id: card})
    after
      if is_nil(previous_prefix),
        do: Process.delete(:gls34_prefix),
        else: Process.put(:gls34_prefix, previous_prefix)
    end
  end

  defp opened_fixture!, do: fixture!() |> open!()

  defp open!(f) do
    {:ok, opened} =
      Scoring.query_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        reason: "original dispute"
      })

    Map.put(f, :query_id, opened.score_query.id)
  end

  defp escalate!(f) do
    assert {:ok, _} =
             Scoring.escalate_score_query(f.admin, f.event.id, f.round.id, %{
               score_query_id: f.query_id,
               expected_revision: 1,
               reason: "escalated"
             })

    f
  end

  defp command(f, attrs \\ %{}),
    do:
      Map.merge(
        %{
          score_query_id: f.query_id,
          expected_revision: 1,
          reason: "staff decision",
          decision: :dismiss
        },
        attrs
      )

  defp decide(f, attrs \\ %{}),
    do: Scoring.decide_score_query(f.admin, f.event.id, f.round.id, command(f, attrs))

  defp set_role!(f, role),
    do:
      Repo.query!(
        "UPDATE event_staff_assignments SET role = $2 WHERE event_id = $1::uuid",
        [uuid(f.event.id), role]
      )

  defp snapshot(f),
    do: %{
      evidence: evidence(f),
      query:
        Repo.query!("SELECT to_jsonb(q) FROM score_queries q WHERE id = $1::uuid", [
          uuid(f.query_id)
        ]).rows
    }

  defp evidence(f) do
    %{
      query:
        Repo.query!(
          "SELECT to_jsonb(q) - 'status' - 'updated_at' - 'resolved_at' - 'resolution_reason' - 'resolved_by_staff_user_id' FROM score_queries q WHERE id = $1::uuid",
          [uuid(f.query_id)]
        ).rows,
      cards:
        Repo.query!(
          "SELECT to_jsonb(sc) FROM scorecards sc WHERE round_id = $1::uuid ORDER BY id",
          [uuid(f.round.id)]
        ).rows,
      sides:
        Repo.query!(
          "SELECT to_jsonb(csr) FROM competition_side_results csr JOIN competition_sides cs ON cs.id = csr.competition_side_id WHERE cs.round_id = $1::uuid ORDER BY csr.id",
          [uuid(f.round.id)]
        ).rows,
      holes:
        Repo.query!(
          "SELECT to_jsonb(hr) FROM hole_results hr WHERE round_id = $1::uuid ORDER BY id",
          [uuid(f.round.id)]
        ).rows,
      revisions:
        Repo.query!(
          "SELECT to_jsonb(sr) FROM score_revisions sr WHERE round_id = $1::uuid ORDER BY id",
          [uuid(f.round.id)]
        ).rows,
      verifications:
        Repo.query!(
          "SELECT to_jsonb(sv) FROM score_verifications sv WHERE round_id = $1::uuid ORDER BY id",
          [uuid(f.round.id)]
        ).rows
    }
  end

  defp direct_action(f, action, context) do
    Repo.transaction(fn ->
      ScoreQuery
      |> Ash.get!(f.query_id, authorize?: false)
      |> Changeset.for_update(action, %{})
      |> Changeset.set_context(context)
      |> Ash.update(authorize?: false)
      |> then(fn
        {:error, error} -> Repo.rollback(error)
        _ -> flunk("private decision bypassed its coordinator")
      end)
    end)
  end

  defp status(f),
    do:
      Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(f.query_id)]).rows
      |> hd()
      |> hd()

  defp card_state(f),
    do:
      Repo.query!("SELECT state FROM scorecards WHERE id = $1::uuid", [uuid(f.card_id)]).rows
      |> hd()
      |> hd()

  defp review_states(f),
    do:
      Repo.query!(
        "SELECT state FROM competition_side_results WHERE id = ANY($1::uuid[]) ORDER BY id",
        [Enum.map(f.affected_result_ids, &uuid/1)]
      ).rows

  defp correct(f),
    do:
      Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        new_gross_strokes: 6,
        reason: "correction"
      })

  defp escalate(f),
    do:
      Scoring.escalate_score_query(f.admin, f.event.id, f.round.id, %{
        score_query_id: f.query_id,
        expected_revision: 1,
        reason: "race escalation"
      })

  defp competing!(operation) do
    {:ok, fixture} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit({:owned_j4b1_decide_fixture, fixture.event.id}, fn -> cleanup!(fixture) end)

    f = verified_unboxed(fn -> open!(fixture) end)

    IO.puts(
      "GLS-41 J4B1 owned fixture " <>
        inspect(%{event_id: f.event.id, round_id: f.round.id, query_id: f.query_id})
    )

    parent = self()

    holder =
      Task.async(fn ->
        receive do
          :start ->
            verified_unboxed(fn ->
              decide(f, %{decision: :resolve_no_change, reason: "holder resolve"})
            end)
        end
      end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:golf_scoring, :repo, :query], &__MODULE__.observe_decide/4, %{
        owner: holder.pid,
        parent: parent,
        mode: :hold
      })

    send(holder.pid, :start)

    try do
      assert_receive {:write_held, holder_pid}, 10_000

      contender =
        Task.async(fn ->
          verified_unboxed(fn ->
            send(parent, {:contender, backend_pid!()})

            case operation do
              :decisions ->
                decide(f, %{decision: :dismiss, reason: "contender dismiss"})

              :escalation ->
                escalate(f)
            end
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        holder_outcome = Task.await(holder, 15_000)
        contender_outcome = Task.await(contender, 15_000)

        case operation do
          :decisions ->
            assert Enum.count([holder_outcome, contender_outcome], &match?({:ok, _}, &1)) == 1
            assert status(f) in ["resolved", "dismissed"]

            verified_unboxed(fn ->
              assert [[1]] =
                       Repo.query!(
                         "SELECT count(*)::integer FROM audit_events WHERE target_id = $1::uuid AND action IN ('resolve_score_query_no_change', 'dismiss_score_query')",
                         [uuid(f.query_id)]
                       ).rows
            end)

          :escalation ->
            successes = Enum.count([holder_outcome, contender_outcome], &match?({:ok, _}, &1))
            assert successes == 1
            assert status(f) in ["resolved", "escalated"]

            verified_unboxed(fn ->
              audit_actions =
                Repo.query!(
                  "SELECT action FROM audit_events WHERE target_id = $1::uuid AND action IN ('resolve_score_query_no_change', 'dismiss_score_query', 'escalate_score_query') ORDER BY action",
                  [uuid(f.query_id)]
                ).rows
                |> List.flatten()

              assert length(audit_actions) == 1
            end)
        end
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      :telemetry.detach(handler)
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
    end
  end

  @doc false
  def observe_decide(_event, _measurements, metadata, %{owner: owner, parent: parent, mode: mode}) do
    if self() == owner and String.contains?(metadata.query, "UPDATE") and
         String.contains?(metadata.query, "\"score_queries\"") and
         Process.get({GolfScoring.Scoring.Services.DecideScoreQuery, :decide}) do
      if mode == :hold do
        send(parent, {:write_held, backend_pid!()})

        receive do
          :release -> :ok
        after
          15_000 -> raise "timed out holding decide transaction"
        end
      end
    end
  end

  defp backend_pid!, do: Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()

  defp await_blocked!(waiting, blocker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

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

  defp verified_unboxed(callback) do
    Sandbox.unboxed_run(Repo, fn ->
      rows = Repo.query!("SELECT current_database(), current_user").rows
      runner = Map.new(["CI", "GITHUB_ACTIONS", "GITHUB_REPOSITORY"], &{&1, System.get_env(&1)})
      validate_test_identity!(Mix.env(), rows, runner)
      callback.()
    end)
  end

  defp verified_unboxed_transaction(callback),
    do: verified_unboxed(fn -> Repo.transaction(callback) end)

  defp cleanup!(f) do
    {:ok, :ok} =
      verified_unboxed_transaction(fn ->
        [[0]] =
          Repo.query!("SELECT count(*)::integer FROM score_revisions WHERE round_id = $1::uuid", [
            uuid(f.round.id)
          ]).rows

        delete_fixture_rows!(f)
        :ok
      end)
  end

  defp delete_fixture_rows!(f) do
    round = uuid(f.round.id)

    for {sql, params} <- [
          {"DELETE FROM score_queries WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [uuid(f.event.id)]},
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

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
