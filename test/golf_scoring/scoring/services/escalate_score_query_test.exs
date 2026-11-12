defmodule GolfScoring.Scoring.Services.EscalateScoreQueryTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.ScoreQuery
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures
  alias GolfScoring.Scoring.Services.ScoreQueryNotifier

  test "staff escalation preserves the dispute and all review evidence" do
    f = fixture!()

    {:ok, opened} =
      Scoring.query_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        reason: "original dispute"
      })

    assert {:ok, escalated} =
             Scoring.escalate_score_query(f.admin, f.event.id, f.round.id, %{
               score_query_id: opened.score_query.id,
               expected_revision: 1,
               reason: "manager attention needed"
             })

    assert escalated.score_query.status == :escalated
    assert escalated.score_query.reason == "original dispute"
    assert escalated.score_query.hole_result_revision == 1
    assert escalated.audit.action == "escalate_score_query"
  end

  test "each approved staff role can escalate with exact audit and unchanged evidence" do
    for role <- ["event_admin", "competition_manager", "scoring_support"] do
      f = opened_fixture!()
      set_role!(f, role)
      before = evidence(f)
      assert {:ok, result} = escalate(f, %{reason: "  manager attention  "})
      assert result.score_query.status == :escalated
      assert evidence(f) == before
      assert result.audit.actor_staff_user_id == f.admin.id
      assert result.audit.target_id == f.query_id
      assert result.audit.target_type == "ScoreQuery"
      assert result.audit.reason == "manager attention"

      assert result.audit.context == %{
               "event_id" => f.event.id,
               "round_id" => f.round.id,
               "hole_result_id" => f.hole_id,
               "scorecard_id" => f.card_id,
               "hole_result_revision" => 1
             }

      assert result.audit.changes == %{"status" => %{"from" => "open", "to" => "escalated"}}
      assert result.audit.occurred_at
    end
  end

  test "zero competitive sides still permits escalation of the reviewed card" do
    f = fixture!()

    Repo.query!("DELETE FROM competition_side_memberships WHERE round_entry_id = $1::uuid", [
      uuid(hd(f.entries).id)
    ])

    f = open!(f)
    before = evidence(f)
    assert {:ok, result} = escalate(f)
    assert result.side_results == []
    assert evidence(f) == before
  end

  test "scoring-closed rounds remain supported" do
    f = opened_fixture!()
    Fixtures.set_round_state!(f.round, :scoring_closed)
    assert {:ok, _} = escalate(f)
  end

  test "missing and unauthorized tenant scope do not reveal query existence" do
    f = opened_fixture!()
    other = opened_fixture!()
    before = snapshot(f)
    assert {:error, _} = escalate(f, %{}, %{id: f.admin.id})
    assert {:error, :not_found_or_forbidden} = escalate(f, %{}, other.admin)

    assert {:error, :not_found_or_forbidden} =
             Scoring.escalate_score_query(f.admin, other.event.id, f.round.id, command(f))

    assert {:error, :not_found_or_forbidden} =
             Scoring.escalate_score_query(f.admin, f.event.id, other.round.id, command(f))

    assert {:error, :not_found_or_forbidden} =
             escalate(f, %{score_query_id: Ecto.UUID.generate()})

    assert snapshot(f) == before
  end

  test "registration staff, suspended and revoked authority and player grants are denied" do
    f = opened_fixture!() |> with_verifier!()
    before = snapshot(f)
    assert {:error, _} = escalate(f, %{}, f.verifier_grant)
    set_role!(f, "registration_staff")
    assert {:error, :not_found_or_forbidden} = escalate(f)
    set_role!(f, "scoring_support")

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, :not_found_or_forbidden} = escalate(f)

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [uuid(f.admin.id)])

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    assert {:error, :not_found_or_forbidden} = escalate(f)
    assert snapshot(f) == before
  end

  test "invalid inputs and stale current or requested revisions cannot escalate" do
    f = opened_fixture!()
    before = snapshot(f)

    for attrs <- [
          %{reason: " "},
          %{reason: <<255>>},
          %{reason: String.duplicate("x", 4097)},
          %{expected_revision: 0},
          %{expected_revision: 2},
          %{score_query_id: "bad"}
        ] do
      assert {:error, _} = escalate(f, attrs)
      assert snapshot(f) == before
    end

    Repo.query!("UPDATE hole_results SET revision = 2 WHERE id = $1::uuid", [uuid(f.hole_id)])
    before = snapshot(f)
    assert {:error, :stale_revision} = escalate(f)
    assert snapshot(f) == before
  end

  test "repeated escalation conflicts and terminal queries cannot reopen" do
    f = opened_fixture!()
    assert {:ok, _} = escalate(f)
    before = snapshot(f)
    assert {:error, :already_escalated} = escalate(f)
    assert snapshot(f) == before

    for status <- ["resolved", "dismissed"] do
      Repo.query!(
        "UPDATE score_queries SET status = $2, resolved_by_staff_user_id = $3::uuid, resolution_reason = 'decision', resolved_at = now() WHERE id = $1::uuid",
        [uuid(f.query_id), status, uuid(f.admin.id)]
      )

      before = snapshot(f)
      assert {:error, :terminal_query} = escalate(f)
      assert snapshot(f) == before
    end
  end

  test "unsupported Round or missing card review rejects without writing" do
    f = opened_fixture!()

    for state <- [:draft, :ready, :finalized, :cancelled] do
      Fixtures.set_round_state!(f.round, state)
      before = snapshot(f)
      assert {:error, _} = escalate(f)
      assert snapshot(f) == before
    end

    Fixtures.set_round_state!(f.round, :scoring_open)

    for state <- ["not_started", "in_progress", "complete", "verified"] do
      Repo.query!("UPDATE scorecards SET state = $2 WHERE id = $1::uuid", [uuid(f.card_id), state])

      before = snapshot(f)
      assert {:error, :unsupported_scorecard_state} = escalate(f)
      assert snapshot(f) == before
    end
  end

  test "every affected side must retain review and consistent membership" do
    f = opened_fixture!()

    for state <- ["provisional", "ready_to_finalize", "finalized"] do
      set_state!(f, hd(f.affected_result_ids), state)
      before = snapshot(f)
      assert {:error, :unsupported_side_result_state} = escalate(f)
      assert snapshot(f) == before
    end

    set_state!(f, hd(f.affected_result_ids), "review_required")

    Repo.query!("UPDATE round_entries SET playing_group_id = NULL WHERE id = $1::uuid", [
      uuid(Enum.at(f.entries, 1).id)
    ])

    before = snapshot(f)
    assert {:error, :invalid_side_membership} = escalate(f)
    assert snapshot(f) == before

    # Synthetic inconsistent-state coverage: E1 would reject an excluded side.
    # Construct exclusion through GLS-80 first, then insert only test query/review
    # evidence. This is not a production query-opening or review-clearance path.
    excluded = fixture!() |> synthetic_query_after_valid_exclusion!()
    before = snapshot(excluded)
    assert {:error, :unsupported_side_result_state} = escalate(excluded)
    assert snapshot(excluded) == before
  end

  test "missing affected SideResult is rejected rather than silently omitted" do
    f = opened_fixture!()

    Repo.query!("DELETE FROM competition_side_results WHERE id = $1::uuid", [
      uuid(hd(f.affected_result_ids))
    ])

    before = snapshot(f)
    assert {:error, :invalid_side_membership} = escalate(f)
    assert snapshot(f) == before
  end

  test "direct and forged private actions cannot commit escalation" do
    f = opened_fixture!()
    before = snapshot(f)

    for context <- [
          %{},
          %{score_query_escalation: make_ref()},
          %{score_query_escalation: %{authorized: true}}
        ] do
      assert {:error, _} = direct_action(f, context)
      assert snapshot(f) == before
    end
  end

  test "captured proof is single use and cannot cross a completed transaction" do
    f = opened_fixture!()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:golf_scoring, :repo, :query], &__MODULE__.observe_update/4, %{
        owner: self(),
        parent: self(),
        mode: :capture
      })

    try do
      assert {:ok, _} = escalate(f)
      assert_receive {:captured_gate, gate}
      before = snapshot(f)
      assert {:error, _} = direct_action(f, %{score_query_escalation: gate.token})

      assert {:error, _} =
               Repo.transaction(fn ->
                 Process.put({GolfScoring.Scoring.Services.EscalateScoreQuery, :escalate}, %{
                   gate
                   | phase: :ready
                 })

                 try do
                   private_update(f, %{score_query_escalation: gate.token})
                 after
                   Process.delete({GolfScoring.Scoring.Services.EscalateScoreQuery, :escalate})
                 end
               end)

      assert snapshot(f) == before
    after
      :telemetry.detach(handler)
    end
  end

  test "audit failure rolls back status and timestamp and publishes nothing" do
    f = opened_fixture!()
    before = snapshot(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_escalation_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_escalation_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action = 'escalate_score_query') EXECUTE FUNCTION pg_temp.reject_escalation_audit()"
    )

    assert {:error, _} = escalate(f)
    assert snapshot(f) == before
    refute_receive {:score_query_escalated, _}
    assert is_nil(Process.get({GolfScoring.Scoring.Services.EscalateScoreQuery, :escalate}))
  end

  test "owns outer transaction and broadcasts exactly once with nonsensitive committed IDs" do
    f = opened_fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    assert {:ok, {:error, :outer_transaction_required}} = Repo.transaction(fn -> escalate(f) end)
    refute_receive {:score_query_escalated, _}
    assert {:ok, result} = escalate(f)
    assert result.notification == :ok
    assert_receive {:score_query_escalated, payload}

    assert payload == %{
             event_id: f.event.id,
             round_id: f.round.id,
             score_query_id: f.query_id,
             hole_result_id: f.hole_id,
             scorecard_id: f.card_id,
             hole_result_revision: 1,
             affected_side_result_ids: Enum.map(result.side_results, & &1.id)
           }

    assert {:error, :already_escalated} = escalate(f)
    refute_receive {:score_query_escalated, _}

    assert {:error, :pubsub_unavailable} =
             ScoreQueryNotifier.publish_escalated(result, GLS41MissingPubSub)
  end

  test "certification cannot clear an escalated dispute or competitive review" do
    f = opened_fixture!() |> with_verifier!()
    assert {:ok, _} = escalate(f)
    assert {:ok, verification} = verify(f)
    assert verification.status == :verified
    assert status(f) == "escalated"
    assert review_states(f) == [["review_required"], ["review_required"]]
    assert {:error, _} = correct(f)
    assert status(f) == "escalated"
  end

  @tag :real_concurrency
  test "two independent escalations commit one transition, audit and notification" do
    competing!(:escalation)
  end

  @tag :real_concurrency
  test "concurrent correction remains blocked by the unresolved escalation" do
    competing!(:correction)
  end

  @tag :real_concurrency
  test "concurrent verification cannot clear escalation review" do
    competing!(:verification)
  end

  defp fixture! do
    fixture_prerequisites!() |> submit_fixture!()
  end

  defp fixture_prerequisites! do
    previous_prefix = Process.get(:gls34_prefix)
    Process.put(:gls34_prefix, "gls41-e2-" <> Ecto.UUID.generate())

    try do
      build_fixture!()
    after
      if is_nil(previous_prefix),
        do: Process.delete(:gls34_prefix),
        else: Process.put(:gls34_prefix, previous_prefix)
    end
  end

  defp build_fixture! do
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

    Map.merge(f, %{
      verifier_assignment: verifier_assignment,
      affected_result_ids: [first, second],
      unrelated_result_id: unrelated,
      secondary_side: secondary_side,
      secondary_competition: secondary
    })
  end

  defp submit_fixture!(f) do
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

    Map.merge(f, %{hole_id: hole, card_id: card})
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

  defp command(f, attrs \\ %{}),
    do:
      Map.merge(
        %{score_query_id: f.query_id, expected_revision: 1, reason: "manager attention needed"},
        attrs
      )

  defp escalate(f, attrs \\ %{}, actor \\ nil),
    do: Scoring.escalate_score_query(actor || f.admin, f.event.id, f.round.id, command(f, attrs))

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
        ]).rows,
      audit:
        Repo.query!(
          "SELECT id FROM audit_events WHERE target_id = $1::uuid AND action = 'escalate_score_query'",
          [uuid(f.query_id)]
        ).rows
    }

  defp evidence(f) do
    %{
      query:
        Repo.query!(
          "SELECT to_jsonb(q) - 'status' - 'updated_at' FROM score_queries q WHERE id = $1::uuid",
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
        ).rows,
      group:
        Repo.query!("SELECT to_jsonb(pg) FROM playing_groups pg WHERE id = $1::uuid", [
          uuid(f.group.id)
        ]).rows
    }
  end

  defp private_update(f, context) do
    ScoreQuery
    |> Ash.get!(f.query_id, authorize?: false)
    |> Changeset.for_update(:escalate_internal, %{})
    |> Changeset.set_context(context)
    |> Ash.update(authorize?: false)
    |> then(fn
      {:error, error} -> Repo.rollback(error)
      _ -> flunk("private escalation bypassed its coordinator")
    end)
  end

  defp direct_action(f, context), do: Repo.transaction(fn -> private_update(f, context) end)

  defp status(f),
    do:
      Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(f.query_id)]).rows
      |> hd()
      |> hd()

  defp review_states(f),
    do:
      Repo.query!(
        "SELECT state FROM competition_side_results WHERE id = ANY($1::uuid[]) ORDER BY id",
        [Enum.map(f.affected_result_ids, &uuid/1)]
      ).rows

  defp with_verifier!(f) do
    {:ok, %{grant: grant}} =
      GolfScoring.Accounts.issue_player_access(
        f.admin,
        f.event.id,
        Enum.at(f.entries, 1).player_id
      )

    Map.put(f, :verifier_grant, grant)
  end

  defp verify(f),
    do:
      Scoring.verify_hole_result(f.verifier_grant, f.event.id, f.round.id, %{
        playing_group_id: f.group.id,
        hole_result_id: f.hole_id,
        hole_result_revision: 1,
        role_assignment_id: f.verifier_assignment.id,
        role_assignment_version: f.verifier_assignment.assignment_version
      })

  defp correct(f),
    do:
      Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: f.hole_id,
        expected_revision: 1,
        new_gross_strokes: 6,
        reason: "correction"
      })

  defp competing!(operation) do
    {:ok, fixture} =
      verified_unboxed_transaction(fn -> fixture_prerequisites!() |> with_verifier!() end)

    on_exit({:owned_e2_fixture, fixture.event.id}, fn -> cleanup!(fixture) end)

    fixture =
      verified_unboxed(fn ->
        refute Repo.in_transaction?()
        submit_fixture!(fixture)
      end)

    IO.puts(
      "GLS-41 E2 owned fixture " <>
        inspect(%{event_id: fixture.event.id, round_id: fixture.round.id})
    )

    f = verified_unboxed(fn -> open!(fixture) end)
    parent = self()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    holder =
      Task.async(fn ->
        receive do
          :start -> verified_unboxed(fn -> escalate(f) end)
        end
      end)

    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:golf_scoring, :repo, :query], &__MODULE__.observe_update/4, %{
        owner: holder.pid,
        parent: parent,
        mode: :hold
      })

    send(holder.pid, :start)

    try do
      assert_receive {:write_held, holder_pid}, 10_000
      refute_receive {:score_query_escalated, _}

      contender =
        Task.async(fn ->
          verified_unboxed(fn ->
            send(parent, {:contender, backend_pid!()})

            case operation do
              :escalation -> escalate(f)
              :correction -> correct(f)
              :verification -> verify(f)
            end
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, _} = Task.await(holder, 15_000)
        outcome = Task.await(contender, 15_000)

        case operation do
          :escalation -> assert outcome == {:error, :already_escalated}
          :correction -> assert {:error, _} = outcome
          :verification -> assert {:ok, %{status: :verified}} = outcome
        end

        assert_receive {:score_query_escalated, _}
        refute_receive {:score_query_escalated, _}

        verified_unboxed(fn ->
          assert status(f) == "escalated"
          assert review_states(f) == [["review_required"], ["review_required"]]

          assert [[1]] =
                   Repo.query!(
                     "SELECT count(*)::integer FROM audit_events WHERE target_id = $1::uuid AND action = 'escalate_score_query'",
                     [uuid(f.query_id)]
                   ).rows

          assert [[1]] =
                   Repo.query!("SELECT revision FROM hole_results WHERE id = $1::uuid", [
                     uuid(f.hole_id)
                   ]).rows
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

  @doc false
  def observe_update(_event, _measurements, metadata, %{owner: owner, parent: parent, mode: mode}) do
    if self() == owner and String.contains?(metadata.query, "UPDATE") and
         String.contains?(metadata.query, "\"score_queries\"") do
      gate = Process.get({GolfScoring.Scoring.Services.EscalateScoreQuery, :escalate})
      send(parent, {:captured_gate, gate})

      if mode == :hold do
        send(parent, {:write_held, backend_pid!()})

        receive do
          :release -> :ok
        after
          10_000 -> raise "timed out holding escalation transaction"
        end
      end
    end
  end

  defp synthetic_query_after_valid_exclusion!(f) do
    [[next_hole]] =
      Repo.query!(
        "SELECT id::text FROM round_holes WHERE round_id = $1::uuid AND play_order = (SELECT mod(play_order, 18) + 1 FROM round_holes WHERE id = $2::uuid)",
        [uuid(f.round.id), uuid(f.start_hole.id)]
      ).rows

    assert {:ok, _} =
             ExcludeCompetitionSideBeforeHole.run(
               f.admin,
               f.event.id,
               f.round.id,
               f.secondary_competition.id,
               f.secondary_side.id,
               f.group.id,
               next_hole,
               %{reason: "synthetic escalation rejection fixture", confirm_hole_unplayed?: true}
             )

    [[query_id]] =
      Repo.query!(
        "INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, hole_result_revision, requested_by_staff_user_id, reason) VALUES ($1::uuid, $2::uuid, $3::uuid, 1, $4::uuid, 'synthetic dispute') RETURNING id::text",
        [uuid(f.hole_id), uuid(f.card_id), uuid(f.round.id), uuid(f.admin.id)]
      ).rows

    Repo.query!("UPDATE scorecards SET state = 'review_required' WHERE id = $1::uuid", [
      uuid(f.card_id)
    ])

    Repo.query!(
      "UPDATE competition_side_results SET state = 'review_required' WHERE id = $1::uuid",
      [uuid(hd(f.affected_result_ids))]
    )

    Map.put(f, :query_id, query_id)
  end

  defp set_state!(_, id, state),
    do:
      Repo.query!("UPDATE competition_side_results SET state = $2 WHERE id = $1::uuid", [
        uuid(id),
        state
      ])

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
