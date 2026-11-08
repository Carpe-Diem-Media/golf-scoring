defmodule GolfScoring.Scoring.Services.CorrectHoleResultTest do
  use GolfScoring.DataCase, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.CorrectionNotifier
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  test "staff correction advances once and preserves exact history across competitions" do
    f = fixture!()
    assert {:ok, result} = correct(f)
    assert result.hole_result.revision == 2
    assert result.hole_result.gross_strokes == 6
    assert result.score_revision.original_revision == 1
    assert result.score_revision.resulting_revision == 2
    assert result.score_revision.original_gross_strokes == 4
    assert result.score_revision.new_gross_strokes == 6
    assert result.score_revision.actor_staff_user_id == f.admin.id
    assert result.score_revision.reason == "counting correction"
    assert Enum.sort(Enum.map(result.side_results, & &1.id)) == Enum.sort(f.affected_result_ids)
    assert Enum.all?(result.side_results, &(&1.state == :review_required))
    assert state(f.unrelated_result_id) == "provisional"
    assert result.verification.status == :pending
    assert result.verification.hole_result_revision == 2
    assert result.audit.action == "correct_hole_result"
  end

  test "pending history stays pending while each kind of certification is superseded" do
    for kind <- [:pending, :verified, :overridden] do
      f = fixture!() |> with_verifier!()
      old = certification!(f, kind)
      assert {:ok, result} = correct(f)
      historical = Ash.get!(GolfScoring.Scoring.ScoreVerification, old.id, authorize?: false)
      assert historical.status == if(kind == :pending, do: :pending, else: :superseded)
      assert historical.hole_result_revision == 1
      assert historical.verifier_round_entry_id == old.verifier_round_entry_id
      assert historical.overridden_by_staff_user_id == old.overridden_by_staff_user_id
      assert result.verification.status == :pending
      assert result.verification.hole_result_revision == 2
      assert result.verification.id != old.id
    end
  end

  test "invalid gross values, no-op and stale commands leave every artifact unchanged" do
    f = fixture!()
    initial = snapshot(f)

    for attrs <- [
          %{expected_revision: 2},
          %{new_gross_strokes: 4},
          %{new_gross_strokes: 0},
          %{new_gross_strokes: -1},
          %{new_gross_strokes: 2_147_483_648},
          %{new_gross_strokes: "6"},
          %{reason: "  "}
        ] do
      assert {:error, _} = correct(f, attrs)
      assert snapshot(f) == initial
    end

    assert {:ok, _} = correct(f)
    committed = snapshot(f)
    assert {:error, _} = correct(f)
    assert snapshot(f) == committed
  end

  test "trusted StaffUser boundary and live same-event roles are required" do
    f = fixture!()
    initial = snapshot(f)
    assert {:error, :forbidden} = correct(f, %{}, %{id: f.admin.id})

    assert {:error, _} =
             correct(f, %{}, %GolfScoring.Accounts.StaffUser{id: Ecto.UUID.generate()})

    for status <- ["revoked", "active"] do
      Repo.query!(
        "UPDATE event_staff_assignments SET status = $2, role = 'scoring_support' WHERE event_id = $1::uuid",
        [uuid(f.event.id), status]
      )

      assert {:error, _} = correct(f)
      assert snapshot(f) == initial
    end

    Repo.query!(
      "UPDATE event_staff_assignments SET role = 'competition_manager', status = 'active' WHERE event_id = $1::uuid",
      [uuid(f.event.id)]
    )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, _} = correct(f)
    assert snapshot(f) == initial

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [uuid(f.admin.id)])

    assert {:ok, _} = correct(f)
  end

  test "cross-event and wrong-round identifiers are rejected" do
    f = fixture!()
    other = fixture!()
    initial = snapshot(f)

    command = %{
      hole_result_id: f.hole_id,
      expected_revision: 1,
      new_gross_strokes: 6,
      reason: "test"
    }

    assert {:error, _} = Scoring.correct_hole_result(other.admin, f.event.id, f.round.id, command)
    assert {:error, _} = Scoring.correct_hole_result(f.admin, other.event.id, f.round.id, command)
    assert {:error, _} = Scoring.correct_hole_result(f.admin, f.event.id, other.round.id, command)
    assert snapshot(f) == initial
  end

  test "unsupported scorecards, outcomes, rounds and side states fail closed" do
    f = fixture!()

    for card_state <- ["not_started", "review_required", "verified"] do
      Repo.query!("UPDATE scorecards SET state = $2 WHERE id = $1::uuid", [
        uuid(f.card_id),
        card_state
      ])

      initial = snapshot(f)
      assert {:error, _} = correct(f)
      assert snapshot(f) == initial
    end

    Repo.query!("UPDATE scorecards SET state = 'in_progress' WHERE id = $1::uuid", [
      uuid(f.card_id)
    ])

    Repo.query!(
      "UPDATE hole_results SET outcome = 'picked_up', gross_strokes = NULL WHERE id = $1::uuid",
      [uuid(f.hole_id)]
    )

    initial = snapshot(f)
    assert {:error, :unsupported_outcome} = correct(f)
    assert snapshot(f) == initial

    Repo.query!(
      "UPDATE hole_results SET outcome = 'holed_out', gross_strokes = 4 WHERE id = $1::uuid",
      [uuid(f.hole_id)]
    )

    for round_state <- [:draft, :ready, :finalized, :cancelled] do
      Fixtures.set_round_state!(f.round, round_state)
      initial = snapshot(f)
      assert {:error, _} = correct(f)
      assert snapshot(f) == initial
    end

    Fixtures.set_round_state!(f.round, :scoring_open)

    for side_state <- ["review_required", "ready_to_finalize", "finalized", "excluded"] do
      set_state!(f, hd(f.affected_result_ids), "provisional")
      set_state!(f, hd(f.affected_result_ids), side_state)
      initial = snapshot(f)
      assert {:error, _} = correct(f)
      assert snapshot(f) == initial
    end
  end

  test "scoring-closed rounds and complete scorecards accept this supported correction" do
    f = fixture!()
    Fixtures.set_round_state!(f.round, :scoring_closed)
    Repo.query!("UPDATE scorecards SET state = 'complete' WHERE id = $1::uuid", [uuid(f.card_id)])
    assert {:ok, _} = correct(f)

    assert [["complete"]] =
             Repo.query!("SELECT state FROM scorecards WHERE id = $1::uuid", [uuid(f.card_id)]).rows
  end

  test "unresolved queries prevent correction without touching evidence" do
    f = fixture!()

    for status <- ["open", "escalated"] do
      Repo.query!(
        "INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, hole_result_revision, requested_by_staff_user_id, reason, status) VALUES ($1::uuid, $2::uuid, $3::uuid, 1, $4::uuid, 'dispute', $5)",
        [uuid(f.hole_id), uuid(f.card_id), uuid(f.round.id), uuid(f.admin.id), status]
      )

      initial = snapshot(f)
      assert {:error, :unresolved_score_query} = correct(f)
      assert snapshot(f) == initial
      Repo.query!("DELETE FROM score_queries WHERE hole_result_id = $1::uuid", [uuid(f.hole_id)])
    end
  end

  test "direct private actions and forged context cannot commit isolated score or revision writes" do
    f = fixture!()
    initial = snapshot(f)

    for context <- [
          %{},
          %{score_correction: make_ref()},
          %{score_correction: %{authorized: true}}
        ] do
      assert {:error, _} =
               Repo.transaction(fn ->
                 GolfScoring.Scoring.HoleResult
                 |> Ash.get!(f.hole_id, authorize?: false)
                 |> Changeset.for_update(:correct_gross_internal, %{
                   gross_strokes: 6,
                   expected_revision: 1
                 })
                 |> Changeset.set_context(context)
                 |> Ash.update(authorize?: false)
                 |> case do
                   {:error, reason} -> Repo.rollback(reason)
                   _ -> flunk("isolated update succeeded")
                 end
               end)

      assert {:error, _} =
               Repo.transaction(fn ->
                 GolfScoring.Scoring.ScoreRevision
                 |> Changeset.for_create(:record_correction_internal, %{
                   hole_result_id: f.hole_id,
                   scorecard_id: f.card_id,
                   round_id: f.round.id,
                   actor_staff_user_id: f.admin.id,
                   original_revision: 1,
                   resulting_revision: 2,
                   original_outcome: :holed_out,
                   new_outcome: :holed_out,
                   original_gross_strokes: 4,
                   new_gross_strokes: 6,
                   reason: "forged"
                 })
                 |> Changeset.set_context(context)
                 |> Ash.create(authorize?: false)
                 |> case do
                   {:error, reason} -> Repo.rollback(reason)
                   _ -> flunk("isolated revision succeeded")
                 end
               end)

      assert snapshot(f) == initial
    end

    assert is_nil(Process.get({GolfScoring.Scoring.Services.CorrectHoleResult, :write}))
  end

  test "nested service calls reject before writes or notifications" do
    f = fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    initial = snapshot(f)
    assert {:ok, {:error, :outer_transaction_required}} = Repo.transaction(fn -> correct(f) end)
    assert snapshot(f) == initial
    refute_receive {:hole_result_corrected, _}
  end

  test "audit insertion failure rolls back result, revision, certification and every side" do
    f = fixture!() |> with_verifier!()
    certification!(f, :overridden)
    initial = snapshot(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_correction_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated audit failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_reject_audit BEFORE INSERT ON audit_events FOR EACH ROW WHEN (NEW.action = 'correct_hole_result') EXECUTE FUNCTION pg_temp.reject_correction_audit()"
    )

    assert {:error, _} = correct(f)
    assert snapshot(f) == initial
    refute_receive {:hole_result_corrected, _}
    assert is_nil(Process.get({GolfScoring.Scoring.Services.CorrectHoleResult, :write}))
  end

  test "notification contains only approved invalidation identifiers and delivery failure is separate" do
    f = fixture!()
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    assert {:ok, correction} = correct(f)
    assert correction.notification == :ok
    assert_receive {:hole_result_corrected, payload}

    assert payload == %{
             event_id: f.event.id,
             round_id: f.round.id,
             playing_group_id: f.group.id,
             hole_result_id: f.hole_id,
             scorecard_id: f.card_id,
             resulting_revision: 2,
             affected_side_result_ids: Enum.map(correction.side_results, & &1.id)
           }

    refute_receive {:hole_result_corrected, _}
    committed = snapshot(f)

    assert {:error, :pubsub_unavailable} =
             CorrectionNotifier.publish(
               correction,
               GLS41MissingPubSub
             )

    assert snapshot(f) == committed
  end

  @tag :real_concurrency
  test "competing corrections serialize and only one exact revision commits" do
    with_competing_correction(:correction)
  end

  @tag :real_concurrency
  test "verification waiting behind correction cannot certify the old revision" do
    with_competing_correction(:verification)
  end

  test "failure on the last affected side rolls back audit and earlier side changes" do
    f = fixture!()
    initial = snapshot(f)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")

    [[last_side]] =
      Repo.query!(
        "SELECT csr.id::text FROM competition_side_results csr JOIN competition_sides cs ON cs.id = csr.competition_side_id WHERE csr.id = ANY($1::uuid[]) ORDER BY cs.id DESC LIMIT 1",
        [Enum.map(f.affected_result_ids, &uuid/1)]
      ).rows

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_last_side_review() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated side failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER gls41_test_reject_side BEFORE UPDATE ON competition_side_results FOR EACH ROW WHEN (NEW.id = '#{last_side}'::uuid AND NEW.state = 'review_required') EXECUTE FUNCTION pg_temp.reject_last_side_review()"
    )

    assert {:error, _} = correct(f)
    assert snapshot(f) == initial
    refute_receive {:hole_result_corrected, _}
  end

  @tag :real_concurrency
  test "correction waiting behind verification supersedes the newly committed certification" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() |> with_verifier!() end)
    parent = self()

    holder =
      Task.async(fn ->
        receive do
          :start -> Sandbox.unboxed_run(Repo, fn -> verify(f) end)
        end
      end)

    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler_id, [:golf_scoring, :repo, :query], &__MODULE__.hold_update/4, %{
        owner: holder.pid,
        parent: parent,
        table: "score_verifications"
      })

    send(holder.pid, :start)

    try do
      assert_receive {:correction_held, holder_pid}, 10_000

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:contender, backend_pid!()})
            correct(f)
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, old} = Task.await(holder, 15_000)
        assert {:ok, correction} = Task.await(contender, 15_000)

        {:ok, historical} =
          verified_unboxed_transaction(fn ->
            Ash.get!(GolfScoring.Scoring.ScoreVerification, old.id, authorize?: false)
          end)

        assert historical.status == :superseded
        assert historical.verifier_round_entry_id == old.verifier_round_entry_id
        assert correction.verification.status == :pending
        assert correction.hole_result.revision == 2
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      :telemetry.detach(handler_id)
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
      cleanup!(f)
    end
  end

  defp with_competing_correction(operation) do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() |> with_verifier!() end)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{f.round.id}")
    parent = self()

    holder =
      Task.async(fn ->
        receive do
          :start -> Sandbox.unboxed_run(Repo, fn -> correct(f) end)
        end
      end)

    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler_id, [:golf_scoring, :repo, :query], &__MODULE__.hold_update/4, %{
        owner: holder.pid,
        parent: parent
      })

    send(holder.pid, :start)

    try do
      assert_receive {:correction_held, holder_pid}, 10_000
      refute_receive {:hole_result_corrected, _}

      contender =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:contender, backend_pid!()})

            case operation do
              :correction -> correct(f, %{new_gross_strokes: 7})
              :verification -> verify(f)
            end
          end)
        end)

      try do
        assert_receive {:contender, contender_pid}, 10_000
        assert holder_pid != contender_pid
        await_blocked!(contender_pid, holder_pid)
        send(holder.pid, :release)
        assert {:ok, correction} = Task.await(holder, 15_000)
        assert {:error, _} = Task.await(contender, 15_000)
        assert_receive {:hole_result_corrected, %{resulting_revision: 2}}, 5_000
        refute_receive {:hole_result_corrected, _}
        {:ok, persisted} = verified_unboxed_transaction(fn -> snapshot(f) end)
        assert persisted.hole == [[2, "holed_out", 6]]
        assert length(persisted.revisions) == 1
        assert Enum.all?(correction.side_results, &(&1.state == :review_required))
      after
        send(holder.pid, :release)
        Task.shutdown(contender, 15_000)
      end
    after
      :telemetry.detach(handler_id)
      send(holder.pid, :release)
      Task.shutdown(holder, 15_000)
      cleanup!(f)
    end
  end

  @doc false
  def hold_update(_event, _measurements, metadata, %{owner: owner, parent: parent} = config) do
    if self() == owner and String.contains?(metadata.query, "UPDATE") and
         String.contains?(metadata.query, "\"#{Map.get(config, :table, "hole_results")}\"") do
      send(parent, {:correction_held, backend_pid!()})

      receive do
        :release -> :ok
      after
        10_000 -> raise "timed out holding correction transaction"
      end
    end
  end

  defp with_verifier!(f) do
    {:ok, %{grant: grant}} =
      GolfScoring.Accounts.issue_player_access(
        f.admin,
        f.event.id,
        Enum.at(f.entries, 1).player_id
      )

    Map.put(f, :verifier_grant, grant)
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

  defp certification!(f, :verified) do
    {:ok, verification} = verify(f)
    verification
  end

  defp certification!(f, :overridden) do
    {:ok, verification} =
      Scoring.override_hole_verification(f.admin, f.event.id, f.round.id, %{
        playing_group_id: f.group.id,
        hole_result_id: f.hole_id,
        hole_result_revision: 1,
        reason: "exception"
      })

    verification
  end

  defp certification!(f, :pending) do
    GolfScoring.Scoring.ScoreVerification
    |> Changeset.for_create(:create_pending_internal, %{
      hole_result_id: f.hole_id,
      hole_result_revision: 1,
      scorecard_id: f.card_id,
      round_id: f.round.id,
      playing_group_id: f.group.id,
      subject_round_entry_id: hd(f.entries).id
    })
    |> Ash.create!(authorize?: false)
  end

  defp snapshot(f) do
    %{
      hole:
        Repo.query!(
          "SELECT revision, outcome, gross_strokes FROM hole_results WHERE id = $1::uuid",
          [uuid(f.hole_id)]
        ).rows,
      revisions:
        Repo.query!(
          "SELECT id, original_revision, resulting_revision, original_gross_strokes, new_gross_strokes FROM score_revisions WHERE hole_result_id = $1::uuid ORDER BY resulting_revision",
          [uuid(f.hole_id)]
        ).rows,
      verifications:
        Repo.query!(
          "SELECT id, hole_result_revision, status FROM score_verifications WHERE hole_result_id = $1::uuid ORDER BY hole_result_revision",
          [uuid(f.hole_id)]
        ).rows,
      sides:
        Repo.query!(
          "SELECT id, state, updated_at FROM competition_side_results WHERE id = ANY($1::uuid[]) ORDER BY id",
          [Enum.map(f.affected_result_ids ++ [f.unrelated_result_id], &uuid/1)]
        ).rows,
      audits:
        Repo.query!(
          "SELECT id, changes FROM audit_events WHERE target_id = $1::uuid AND action = 'correct_hole_result' ORDER BY id",
          [uuid(f.hole_id)]
        ).rows
    }
  end

  defp correct(f, attrs \\ %{}, actor \\ nil) do
    Scoring.correct_hole_result(
      actor || f.admin,
      f.event.id,
      f.round.id,
      Map.merge(
        %{
          hole_result_id: f.hole_id,
          expected_revision: 1,
          new_gross_strokes: 6,
          reason: "counting correction"
        },
        attrs
      )
    )
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
