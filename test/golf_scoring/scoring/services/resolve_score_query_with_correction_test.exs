defmodule GolfScoring.Scoring.Services.ResolveScoreQueryWithCorrectionTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.ScoreQuery
  alias GolfScoring.Scoring.Services.CorrectionNotifier
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  test "authorized resolution with correction from open" do
    f = opened_fixture!()

    assert {:ok, result} =
             resolve(f, %{new_gross_strokes: 6, reason: "staff correction"})

    assert result.score_query.status == :resolved
    assert result.score_query.hole_result_revision == 1
    assert result.score_query.resolution_reason == "staff correction"
    assert result.hole_result.revision == 2
    assert result.hole_result.gross_strokes == 6
    assert result.score_revision.original_revision == 1
    assert result.score_revision.resulting_revision == 2
    assert result.score_revision.source_query_id == f.query_id
    assert result.audit.action == "correct_hole_result"
    assert result.query_audit.action == "resolve_score_query_with_correction"

    assert query_revision(f) == 1
    assert gross_strokes(f) == 6
  end

  test "authorized resolution with correction from escalated" do
    f = opened_fixture!() |> escalate!()

    assert {:ok, result} = resolve(f, %{reason: "correct after escalation"})

    assert result.score_query.status == :resolved

    assert result.query_audit.changes == %{
             "status" => %{"from" => "escalated", "to" => "resolved"}
           }
  end

  test "supersedes prior certification and creates pending verification for new revision" do
    f = fixture!() |> with_verifier!() |> open!()
    old = certification!(f, :verified)

    assert {:ok, result} = resolve(f, %{})

    historical = Ash.get!(GolfScoring.Scoring.ScoreVerification, old.id, authorize?: false)
    assert historical.status == :superseded
    assert result.verification.status == :pending
    assert result.verification.hole_result_revision == 2
    assert result.verification.id != old.id
  end

  test "scorecard and affected sides stay under review; unrelated sides unchanged" do
    f = opened_fixture!()

    assert {:ok, _} = resolve(f, %{})

    assert card_state(f) == "review_required"
    assert review_states(f) == [["review_required"], ["review_required"]]

    assert state(f.unrelated_result_id) == "provisional"
  end

  test "ordinary correction still rejects an unresolved query" do
    f = opened_fixture!()
    before = snapshot(f)
    assert {:error, _} = correct(f)
    assert snapshot(f) == before
  end

  test "event_admin and competition_manager only" do
    for role <- ["event_admin", "competition_manager"],
        f = opened_fixture!() do
      set_role!(f, role)
      assert {:ok, _} = resolve(f, %{reason: "ok"})
    end

    f = opened_fixture!()
    set_role!(f, "scoring_support")
    before = snapshot(f)
    assert {:error, _} = resolve(f, %{reason: "nope"})
    assert snapshot(f) == before
  end

  test "stale, terminal, wrong scope and cross-event rejected without mutation" do
    f = opened_fixture!()
    before_f = snapshot(f)

    other = opened_fixture!()

    assert {:error, :not_found_or_forbidden} =
             resolve(f, %{score_query_id: other.query_id, reason: "x"})

    assert {:error, :stale_revision} = resolve(f, %{expected_revision: 2, reason: "x"})
    assert snapshot(f) == before_f

    f2 = opened_fixture!()

    assert {:ok, _} =
             Scoring.dismiss_score_query(f2.admin, f2.event.id, f2.round.id, %{
               score_query_id: f2.query_id,
               expected_revision: 1,
               reason: "dismissed"
             })

    before_f2 = snapshot(f2)
    assert {:error, :terminal_query} = resolve(f2, %{reason: "again"})
    assert snapshot(f2) == before_f2

    other = opened_fixture!()

    assert {:error, _} =
             Scoring.resolve_score_query_with_correction(
               f.admin,
               other.event.id,
               f.round.id,
               command(f)
             )

    assert snapshot(f) == before_f
  end

  test "invalid inputs rejected" do
    f = opened_fixture!()
    before = snapshot(f)

    for attrs <- [
          %{reason: " "},
          %{expected_revision: 0},
          %{new_gross_strokes: 0},
          %{new_gross_strokes: 4},
          %{score_query_id: "bad"}
        ] do
      assert {:error, _} = resolve(f, attrs)
      assert snapshot(f) == before
    end
  end

  test "publishes correction notification only after commit" do
    f = opened_fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    assert {:ok, result} = resolve(f, %{new_gross_strokes: 6, reason: "notify"})

    assert result.notification == :ok
    assert_receive {:hole_result_corrected, payload}

    assert payload == %{
             event_id: f.event.id,
             round_id: f.round.id,
             playing_group_id: f.group.id,
             hole_result_id: f.hole_id,
             scorecard_id: f.card_id,
             resulting_revision: 2,
             affected_side_result_ids: Enum.map(result.side_results, & &1.id)
           }

    refute_receive {:hole_result_corrected, _}
    committed = snapshot(f)

    assert {:error, :pubsub_unavailable} =
             CorrectionNotifier.publish(result, GLS41MissingPubSub)

    assert snapshot(f) == committed
  end

  test "noncompetitive open dispute resolves with correction and no side reviews" do
    f = fixture!()

    Repo.query!("DELETE FROM competition_side_memberships WHERE round_entry_id = $1::uuid", [
      uuid(hd(f.entries).id)
    ])

    f = open!(f)

    assert {:ok, result} = resolve(f, %{reason: "noncompetitive correction"})

    assert result.score_query.status == :resolved
    assert result.side_results == []
    assert result.score_revision.source_query_id == f.query_id
    assert card_state(f) == "review_required"
  end

  test "ordinary correction still rejects entries without affected competition sides" do
    f = fixture!()

    Repo.query!("DELETE FROM competition_side_memberships WHERE round_entry_id = $1::uuid", [
      uuid(hd(f.entries).id)
    ])

    before = hole_snapshot(f)

    assert {:error, :no_affected_sides} =
             Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.hole_id,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "ordinary"
             })

    assert hole_snapshot(f) == before
  end

  test "query-resolution audit failure rolls back correction and verification work" do
    f = opened_fixture!()
    before = snapshot(f)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_query_resolve_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated query audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_query_resolve_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action = 'resolve_score_query_with_correction') EXECUTE FUNCTION pg_temp.reject_query_resolve_audit()"
    )

    assert {:error, _} = resolve(f, %{reason: "x"})
    assert snapshot(f) == before
    assert query_status(f) == "open"

    assert [["holed_out", 1, 4]] =
             Repo.query!(
               "SELECT outcome, revision, gross_strokes FROM hole_results WHERE id = $1::uuid",
               [uuid(f.hole_id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::integer FROM score_revisions WHERE hole_result_id = $1::uuid",
               [uuid(f.hole_id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::integer FROM score_verifications WHERE hole_result_id = $1::uuid",
               [uuid(f.hole_id)]
             ).rows

    assert [[0]] =
             Repo.query!(
               """
               SELECT count(*)::integer FROM audit_events
               WHERE action IN ('correct_hole_result', 'resolve_score_query_with_correction')
                 AND (target_id = $1::uuid OR target_id = $2::uuid)
               """,
               [uuid(f.query_id), uuid(f.hole_id)]
             ).rows
  end

  test "audit failure rolls back correction and query resolution" do
    f = opened_fixture!()
    before = snapshot(f)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_resolve_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_resolve_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action IN ('resolve_score_query_with_correction', 'correct_hole_result')) EXECUTE FUNCTION pg_temp.reject_resolve_audit()"
    )

    assert {:error, _} = resolve(f, %{reason: "x"})
    assert snapshot(f) == before
    assert query_status(f) in ["open", "escalated"]
  end

  test "outer transaction ownership enforced" do
    f = opened_fixture!()

    assert {:ok, {:error, :outer_transaction_required}} =
             Repo.transaction(fn -> resolve(f, %{reason: "nested"}) end)
  end

  test "public wrapper rejects non-map commands" do
    f = opened_fixture!()

    for bad <- [nil, [], "string", 1] do
      assert {:error, :invalid_input} =
               Scoring.resolve_score_query_with_correction(f.admin, f.event.id, f.round.id, bad)
    end
  end

  test "direct private action fails without coordinator capability" do
    f = opened_fixture!()
    before = snapshot(f)

    for context <- [%{}, %{score_query_resolution: make_ref()}] do
      assert {:error, _} = direct_action(f, context)
      assert snapshot(f) == before
    end
  end

  test "unrelated hole gross strokes are not rewritten" do
    f = opened_fixture!()

    [[other_hole, before_gross]] =
      Repo.query!(
        """
        SELECT hr.id::text, hr.gross_strokes
        FROM hole_results hr
        JOIN scorecards sc ON sc.id = hr.scorecard_id
        WHERE sc.round_id = $1::uuid AND hr.id <> $2::uuid
        LIMIT 1
        """,
        [uuid(f.round.id), uuid(f.hole_id)]
      ).rows

    assert {:ok, _} = resolve(f, %{})

    [[after_gross]] =
      Repo.query!("SELECT gross_strokes FROM hole_results WHERE id = $1::uuid", [
        uuid(other_hole)
      ]).rows

    assert after_gross == before_gross
  end

  @tag :real_concurrency
  test "two independent resolve-with-correction attempts commit one outcome" do
    competing!(:resolve)
  end

  @tag :real_concurrency
  test "resolve-with-correction blocks a concurrent terminal decision" do
    competing!(:decide)
  end

  defp fixture!, do: build_fixture!()

  defp build_fixture! do
    previous_prefix = Process.get(:gls34_prefix)
    Process.put(:gls34_prefix, "gls41-j4b2-" <> Ecto.UUID.generate())

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

      [{_, first}, {_, second}, {_, third}] = sides

      {:ok, verifier_assignment} =
        Competition.assign_designated_verifier(
          f.admin,
          f.event.id,
          f.round.id,
          f.group.id,
          Enum.at(f.entries, 1).id
        )

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

      Map.merge(f, %{
        affected_result_ids: [first, second],
        unrelated_result_id: third,
        verifier_assignment: verifier_assignment,
        hole_id: hole,
        card_id: card
      })
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
          new_gross_strokes: 6,
          reason: "staff correction"
        },
        attrs
      )

  defp resolve(f, attrs \\ %{}),
    do:
      Scoring.resolve_score_query_with_correction(
        f.admin,
        f.event.id,
        f.round.id,
        command(f, attrs)
      )

  defp correct(f),
    do:
      Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        new_gross_strokes: 7,
        reason: "ordinary correction"
      })

  defp set_role!(f, role),
    do:
      Repo.query!(
        "UPDATE event_staff_assignments SET role = $2 WHERE event_id = $1::uuid",
        [uuid(f.event.id), role]
      )

  defp snapshot(f) do
    {
      evidence(f),
      Repo.query!("SELECT to_jsonb(q) FROM score_queries q WHERE id = $1::uuid", [
        uuid(f.query_id)
      ]).rows
    }
  end

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

  defp direct_action(f, context) do
    Repo.transaction(fn ->
      ScoreQuery
      |> Ash.get!(f.query_id, authorize?: false)
      |> Changeset.for_update(:resolve_with_correction_internal, %{})
      |> Changeset.set_context(context)
      |> Ash.update(authorize?: false)
      |> then(fn
        {:error, error} -> Repo.rollback(error)
        _ -> flunk("private resolve bypassed its coordinator")
      end)
    end)
  end

  defp query_status(f),
    do:
      Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(f.query_id)]).rows
      |> hd()
      |> hd()

  defp query_revision(f),
    do:
      Repo.query!(
        "SELECT hole_result_revision FROM score_queries WHERE id = $1::uuid",
        [uuid(f.query_id)]
      ).rows
      |> hd()
      |> hd()

  defp gross_strokes(f),
    do:
      Repo.query!("SELECT gross_strokes FROM hole_results WHERE id = $1::uuid", [
        uuid(f.hole_id)
      ]).rows
      |> hd()
      |> hd()

  defp hole_snapshot(f) do
    %{
      hole:
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
          "SELECT id, hole_result_revision, status FROM score_verifications WHERE hole_result_id = $1::uuid ORDER BY id",
          [uuid(f.hole_id)]
        ).rows
    }
  end

  defmodule GLS41MissingPubSub do
    def broadcast(_server, _topic, _message), do: raise("pubsub unavailable")
  end

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

  defp state(id),
    do:
      Repo.query!("SELECT state FROM competition_side_results WHERE id = $1::uuid", [uuid(id)]).rows
      |> hd()
      |> hd()

  defp with_verifier!(f) do
    {:ok, %{grant: grant}} =
      GolfScoring.Accounts.issue_player_access(
        f.admin,
        f.event.id,
        Enum.at(f.entries, 1).player_id
      )

    Map.put(f, :verifier_grant, grant)
  end

  defp certification!(f, :verified) do
    {:ok, verification} = verify(f)
    verification
  end

  defp verify(f) do
    Scoring.verify_hole_result(f.verifier_grant, f.event.id, f.round.id, %{
      playing_group_id: f.group.id,
      hole_result_id: f.hole_id,
      hole_result_revision: 1,
      role_assignment_id: f.verifier_assignment.id,
      role_assignment_version: f.verifier_assignment.assignment_version
    })
  end

  defp competing!(operation) do
    {:ok, fixture} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit({:owned_j4b2_fixture, fixture.event.id}, fn -> cleanup!(fixture) end)

    f = verified_unboxed(fn -> open!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        receive do
          :start ->
            verified_unboxed(fn ->
              resolve(f, %{new_gross_strokes: 6, reason: "holder resolve"})
            end)
        end
      end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:golf_scoring, :repo, :query], &__MODULE__.observe_resolve/4, %{
        owner: holder.pid,
        parent: parent
      })

    send(holder.pid, :start)

    try do
      assert_receive {:write_held, holder_pid}, 10_000

      contender =
        Task.async(fn ->
          verified_unboxed(fn ->
            send(parent, {:contender, backend_pid!()})

            case operation do
              :resolve -> resolve(f, %{new_gross_strokes: 7, reason: "contender resolve"})
              :decide -> decide(f)
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

        successes = Enum.count([holder_outcome, contender_outcome], &match?({:ok, _}, &1))
        assert successes == 1
        assert query_status(f) == "resolved"

        verified_unboxed(fn ->
          assert [[1]] =
                   Repo.query!(
                     """
                     SELECT count(*)::integer FROM audit_events
                     WHERE action = 'resolve_score_query_with_correction' AND target_id = $1::uuid
                     """,
                     [uuid(f.query_id)]
                   ).rows
        end)
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

  defp decide(f),
    do:
      Scoring.decide_score_query(f.admin, f.event.id, f.round.id, %{
        score_query_id: f.query_id,
        expected_revision: 1,
        reason: "race decide",
        decision: :dismiss
      })

  @doc false
  def observe_resolve(_event, _measurements, metadata, %{owner: owner, parent: parent}) do
    if self() == owner and String.contains?(metadata.query, "UPDATE") and
         String.contains?(metadata.query, "\"score_queries\"") do
      send(parent, {:write_held, backend_pid!()})

      receive do
        :release -> :ok
      after
        15_000 -> raise "timed out holding resolve transaction"
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
    verified_unboxed_transaction(fn ->
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

      :ok
    end)
  end

  defp delete_fixture_rows!(f) do
    round = uuid(f.round.id)

    for {sql, params} <- [
          {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_revisions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_queries WHERE round_id = $1::uuid", [round]},
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
