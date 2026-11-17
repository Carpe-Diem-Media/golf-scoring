defmodule GolfScoring.Scoring.Services.LoadSideHolePointsTest do
  use GolfScoring.DataCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.LoadSideHolePoints
  alias GolfScoring.Scoring.Services.LoadStandardSideHoles
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  test "repeatable read keeps applicability and score revision on one snapshot during correction" do
    {:ok, f} =
      verified_unboxed_transaction(fn ->
        f = Fixtures.setup_submit_fixture!(2)
        Fixtures.set_round_state!(f.round, :draft)

        {:ok, side} =
          Competition.create_competition_side(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            :partnership
          )

        {:ok, _} =
          Fixtures.set_side_membership_for_fixture(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            side.id,
            Enum.map(f.entries, & &1.id)
          )

        start_hole = List.last(f.route)

        Repo.query!(
          "UPDATE playing_groups SET starting_round_hole_id = $2::uuid WHERE id = $1::uuid",
          [uuid(f.group.id), uuid(start_hole.id)]
        )

        Fixtures.set_round_state!(f.round, :scoring_open)
        Map.merge(f, %{side: side, start_hole: start_hole})
      end)

    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      {:ok, _} =
        Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
          client_submission_id: Ecto.UUID.generate(),
          playing_group_id: f.group.id,
          round_hole_id: f.start_hole.id,
          expected_group_score_revision: 0,
          captured_at: DateTime.utc_now(),
          results:
            Enum.map(f.entries, fn entry ->
              if entry.id == List.last(f.entries).id,
                do: %{
                  round_entry_id: entry.id,
                  outcome: :picked_up,
                  gross_strokes: nil,
                  strokes_taken: 10
                },
                else: %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 4}
            end)
        })
    end)

    initial =
      verified_unboxed(fn ->
        handler = {__MODULE__, make_ref()}
        Process.put(:gls90_queries, [])

        :ok =
          :telemetry.attach(
            handler,
            [:golf_scoring, :repo, :query],
            &__MODULE__.capture_query/4,
            self()
          )

        result =
          try do
            LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
          after
            :telemetry.detach(handler)
          end

        reads =
          Process.get(:gls90_queries)
          |> Enum.filter(
            &(String.starts_with?(&1, "WITH ") or String.starts_with?(&1, "SELECT "))
          )

        assert length(reads) == 2
        assert {:ok, holes} = result
        refute inspect(holes) =~ "mystery"
        assert length(holes) == 18
        assert hd(holes).round_hole_id == List.last(f.route).id
        assert Enum.map(holes, & &1.play_index) == Enum.to_list(0..17)
        assert Enum.count(hd(holes).members, &(&1.status == :recorded)) == 2
        pickup = Enum.find(hd(holes).members, &(&1.round_entry_id == List.last(f.entries).id))
        assert pickup.points == 0
        assert pickup.hole_result_id != nil and pickup.revision == 1

        assert Enum.all?(
                 Enum.flat_map(tl(holes), & &1.members),
                 &(&1.status == :pending and is_nil(&1.points))
               )

        Process.put(:gls90_queries, [])

        :ok =
          :telemetry.attach(
            handler,
            [:golf_scoring, :repo, :query],
            &__MODULE__.capture_query/4,
            self()
          )

        standard =
          try do
            LoadStandardSideHoles.run(
              f.event.id,
              f.round.id,
              f.side.id
            )
          after
            :telemetry.detach(handler)
          end

        queries = Process.get(:gls90_queries)
        reads = Enum.filter(queries, &String.starts_with?(&1, ["WITH ", "SELECT "]))
        assert length(reads) == 2
        assert Enum.count(reads, &String.starts_with?(&1, "WITH scope AS")) == 1
        assert Enum.count(reads, &String.starts_with?(&1, "SELECT e.id::text")) == 1

        assert Enum.all?(
                 queries,
                 fn sql ->
                   String.upcase(String.trim(sql)) in [
                     "BEGIN",
                     "COMMIT",
                     "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"
                   ] or sql in reads
                 end
               )

        assert {:ok, standard_holes} = standard

        assert Enum.map(standard_holes, & &1.round_hole_id) ==
                 [List.last(f.route).id | Enum.map(Enum.drop(f.route, -1), & &1.id)]

        assert Enum.map(standard_holes, & &1.play_index) == Enum.to_list(0..17)
        assert Enum.map(standard_holes, & &1.members) == Enum.map(holes, & &1.members)
        assert %{status: :computed, points: best} = hd(standard_holes)
        assert best == Enum.max(Enum.map(hd(holes).members, & &1.points))

        assert Enum.any?(
                 hd(standard_holes).members,
                 &(&1.status == :recorded and &1.points == 0 and &1.hole_result_id != nil)
               )

        assert Enum.all?(tl(standard_holes), &(&1.status == :pending and is_nil(&1.points)))

        assert {:ok, {:error, :outer_transaction_required}} =
                 Repo.transaction(fn ->
                   LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
                 end)

        Enum.find(hd(holes).members, &(&1.round_entry_id == hd(f.entries).id))
      end)

    parent = self()

    reader =
      Task.async(fn ->
        verified_unboxed(fn ->
          [[db_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          handler = {__MODULE__, make_ref()}
          config = %{parent: parent, owner: self(), fact: initial, db_pid: db_pid}

          :ok =
            :telemetry.attach(
              handler,
              [:golf_scoring, :repo, :query],
              &__MODULE__.pause_after_applicability/4,
              config
            )

          try do
            LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    assert_receive {:snapshot_ready, reader_pid, fact, db_pid}, 30_000

    writer =
      Task.async(fn ->
        verified_unboxed(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows

          result =
            Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
              hole_result_id: fact.hole_result_id,
              expected_revision: 1,
              new_gross_strokes: 9,
              reason: "snapshot correction"
            })

          {pid, result}
        end)
      end)

    {writer_pid, result} = Task.await(writer, 30_000)
    assert writer_pid != db_pid
    assert {:ok, _} = result
    send(reader_pid, :continue)
    assert {:ok, old_holes} = Task.await(reader, 30_000)
    old_member = Enum.find(hd(old_holes).members, &(&1.round_entry_id == hd(f.entries).id))
    assert old_member.revision == 1 and old_member.hole_result_id == fact.hole_result_id
    assert old_member.points > 0

    before_withdrawal =
      verified_unboxed(fn ->
        assert {:ok, holes} = LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
        member = Enum.find(hd(holes).members, &(&1.round_entry_id == hd(f.entries).id))
        assert member.hole_result_id == fact.hole_result_id
        assert member.revision == 2
        assert member.points == 0

        assert [[2, 9]] =
                 Repo.query!(
                   "SELECT revision, gross_strokes FROM hole_results WHERE id = $1::uuid",
                   [uuid(fact.hole_result_id)]
                 ).rows

        holes
      end)

    entry = List.last(f.entries)
    boundary = hd(f.route)
    withdrawn_fact = Enum.find(hd(before_withdrawal).members, &(&1.round_entry_id == entry.id))
    assert withdrawn_fact.withdrawal_applicability == :applicable
    assert withdrawn_fact.status == :recorded and withdrawn_fact.points == 0

    withdrawal_reader =
      Task.async(fn ->
        verified_unboxed(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          handler = {__MODULE__, make_ref()}
          config = %{parent: parent, owner: self(), fact: withdrawn_fact, db_pid: pid}

          :ok =
            :telemetry.attach(
              handler,
              [:golf_scoring, :repo, :query],
              &__MODULE__.pause_after_applicability/4,
              config
            )

          try do
            LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    try do
      assert_receive {:snapshot_ready, withdrawal_reader_pid, ^withdrawn_fact, withdrawal_db_pid},
                     30_000

      withdrawal_writer =
        Task.async(fn ->
          verified_unboxed(fn ->
            [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows

            result =
              AcceptRoundEntryWithdrawal.run(
                f.admin,
                f.event.id,
                f.round.id,
                f.group.id,
                entry.id,
                %{
                  reason: "fixture withdrawal",
                  attestation: %{
                    observed_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second),
                    method: "direct_visual",
                    observation_location: "fixture",
                    round_id: f.round.id,
                    playing_group_id: f.group.id,
                    effective_round_hole_id: boundary.id,
                    effective_play_index: 1,
                    confirms_unplayed?: true
                  }
                }
              )

            {pid, result}
          end)
        end)

      {withdrawal_writer_pid, withdrawal_result} = Task.await(withdrawal_writer, 30_000)
      assert withdrawal_writer_pid != withdrawal_db_pid
      assert {:ok, ruling} = withdrawal_result
      send(withdrawal_reader_pid, :continue)
      assert {:ok, ^before_withdrawal} = Task.await(withdrawal_reader, 30_000)

      verified_unboxed(fn ->
        assert {:ok, holes} = LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
        historical = Enum.find(hd(holes).members, &(&1.round_entry_id == entry.id))
        assert historical.status == :recorded and historical.ruling_id == ruling.ruling_id
        assert historical.hole_result_id == withdrawn_fact.hole_result_id
        assert historical.revision == withdrawn_fact.revision
        assert historical.points == withdrawn_fact.points

        for {before_hole, after_hole} <- Enum.zip(before_withdrawal, holes) do
          before_partner = Enum.reject(before_hole.members, &(&1.round_entry_id == entry.id))
          after_partner = Enum.reject(after_hole.members, &(&1.round_entry_id == entry.id))
          assert after_partner == before_partner
        end

        for hole <- tl(holes) do
          excluded = Enum.find(hole.members, &(&1.round_entry_id == entry.id))
          assert excluded.status == :excluded and is_nil(excluded.points)
          assert excluded.ruling_id == ruling.ruling_id
        end

        assert {:ok, standard_holes} =
                 LoadStandardSideHoles.run(
                   f.event.id,
                   f.round.id,
                   f.side.id
                 )

        assert Enum.map(standard_holes, & &1.members) == Enum.map(holes, & &1.members)
        assert %{status: :computed, points: 0} = hd(standard_holes)

        for hole <- tl(standard_holes) do
          assert hole.status == :pending and is_nil(hole.points)

          assert Enum.any?(
                   hole.members,
                   &(&1.status == :excluded and &1.ruling_id == ruling.ruling_id)
                 )
        end

        assert {:error, :invalid_scope} =
                 LoadSideHolePoints.run(Ecto.UUID.generate(), f.round.id, f.side.id)
      end)
    after
      send(withdrawal_reader.pid, :continue)
      Task.shutdown(withdrawal_reader, 5_000)
    end

    verified_unboxed(fn ->
      [[tee_hole_id, original_index]] =
        Repo.query!(
          "SELECT id::text, stroke_index FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id = $1::uuid AND round_hole_id = $2::uuid",
          [uuid(f.tee_snapshot.id), uuid(f.start_hole.id)]
        ).rows

      Repo.query!("UPDATE round_tee_hole_snapshots SET stroke_index = 19 WHERE id = $1::uuid", [
        uuid(tee_hole_id)
      ])

      try do
        assert {:error, :inconsistent_evidence} =
                 LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
      after
        Repo.query!("UPDATE round_tee_hole_snapshots SET stroke_index = $2 WHERE id = $1::uuid", [
          uuid(tee_hole_id),
          original_index
        ])
      end

      assert {:ok, _holes} = LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)

      Repo.query!("DELETE FROM competition_handicaps WHERE round_entry_id = $1::uuid", [
        uuid(entry.id)
      ])

      assert {:error, :inconsistent_evidence} =
               LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
    end)
  end

  test "caller-owned snapshot retains facts across an accepted correction" do
    {:ok, f} =
      verified_unboxed_transaction(fn ->
        f = Fixtures.setup_submit_fixture!(2)
        Fixtures.set_round_state!(f.round, :draft)

        {:ok, side} =
          Competition.create_competition_side(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            :partnership
          )

        {:ok, _} =
          Fixtures.set_side_membership_for_fixture(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            side.id,
            Enum.map(f.entries, & &1.id)
          )

        Fixtures.set_round_state!(f.round, :scoring_open)
        Map.put(f, :side, side)
      end)

    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      assert {:ok, _} =
               Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
                 client_submission_id: Ecto.UUID.generate(),
                 playing_group_id: f.group.id,
                 round_hole_id: hd(f.route).id,
                 expected_group_score_revision: 0,
                 captured_at: DateTime.utc_now(),
                 results:
                   Enum.map(
                     f.entries,
                     &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4}
                   )
               })
    end)

    parent = self()

    reader =
      Task.async(fn ->
        verified_unboxed(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

            assert [["repeatable read", "on", reader_db_pid]] =
                     Repo.query!(
                       "SELECT current_setting('transaction_isolation'), current_setting('transaction_read_only'), pg_backend_pid()"
                     ).rows

            assert {:ok, first} =
                     LoadSideHolePoints.run_in_snapshot(f.event.id, f.round.id, f.side.id)

            member = Enum.find(hd(first).members, &(&1.round_entry_id == hd(f.entries).id))
            assert member.revision == 1 and member.points > 0
            send(parent, {:caller_snapshot_ready, self(), reader_db_pid, first, member})

            receive do
              :continue -> :ok
            after
              30_000 -> raise "timed out waiting for correction"
            end

            assert {:ok, second} =
                     LoadSideHolePoints.run_in_snapshot(f.event.id, f.round.id, f.side.id)

            assert second == first
            second
          end)
        end)
      end)

    try do
      assert_receive {:caller_snapshot_ready, reader_pid, reader_db_pid, before, member}, 30_000

      writer =
        Task.async(fn ->
          verified_unboxed(fn ->
            [[writer_db_pid]] = Repo.query!("SELECT pg_backend_pid()").rows

            result =
              Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
                hole_result_id: member.hole_result_id,
                expected_revision: 1,
                new_gross_strokes: 9,
                reason: "caller snapshot correction"
              })

            {self(), writer_db_pid, result}
          end)
        end)

      {writer_pid, writer_db_pid, result} = Task.await(writer, 30_000)
      assert writer_pid != reader_pid and writer_db_pid != reader_db_pid
      assert {:ok, correction} = result
      assert correction.hole_result.revision == 2
      assert correction.hole_result.gross_strokes == 9
      assert correction.score_revision.original_revision == 1
      assert correction.score_revision.resulting_revision == 2
      assert Enum.all?(correction.side_results, &(&1.state == :review_required))
      assert correction.audit.action == "correct_hole_result"
      send(reader_pid, :continue)
      assert {:ok, ^before} = Task.await(reader, 30_000)

      verified_unboxed(fn ->
        assert {:ok, holes} = LoadSideHolePoints.run(f.event.id, f.round.id, f.side.id)
        corrected = Enum.find(hd(holes).members, &(&1.round_entry_id == hd(f.entries).id))
        assert corrected.hole_result_id == member.hole_result_id
        assert corrected.revision == 2 and corrected.points == 0
      end)
    after
      send(reader.pid, :continue)
      Task.shutdown(reader, 5_000)
    end
  end

  test "caller-owned snapshot rejects an absent transaction" do
    verified_unboxed(fn ->
      id = Ecto.UUID.generate()
      assert {:error, :invalid_snapshot} = LoadSideHolePoints.run_in_snapshot(id, id, id)
    end)
  end

  test "caller-owned snapshot rejects unsafe transaction settings" do
    verified_unboxed(fn ->
      id = Ecto.UUID.generate()

      assert {:ok, {:error, :invalid_snapshot}} =
               Repo.transaction(fn ->
                 LoadSideHolePoints.run_in_snapshot(id, id, id)
               end)

      assert {:ok, {:error, :invalid_snapshot}} =
               Repo.transaction(fn ->
                 Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ WRITE")
                 LoadSideHolePoints.run_in_snapshot(id, id, id)
               end)
    end)
  end

  test "rejects invalid scope" do
    assert {:error, :invalid_scope} =
             LoadSideHolePoints.run("bad", "bad", "bad")
  end

  @doc false
  def pause_after_applicability(_event, _measurements, metadata, config) do
    if self() == config.owner and
         String.starts_with?(String.trim_leading(metadata.query), "WITH scope AS") do
      send(config.parent, {:snapshot_ready, self(), config.fact, config.db_pid})

      receive do
        :continue -> :ok
      after
        30_000 -> raise "timed out waiting for concurrent writer"
      end
    end
  end

  @doc false
  def capture_query(_event, _measurements, metadata, owner) do
    if self() == owner do
      Process.put(:gls90_queries, [
        String.trim_leading(metadata.query) | Process.get(:gls90_queries, [])
      ])
    end
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

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

  defp cleanup!(f) do
    verified_unboxed_transaction(fn ->
      # Test-only DDL, after same-connection identity validation. The exclusive
      # lock is held until commit, so other sessions cannot use a disabled guard.
      Repo.query!("SET LOCAL lock_timeout = '5s'")

      Repo.query!(
        "LOCK TABLE public.score_revisions, public.round_entry_participation_rulings IN ACCESS EXCLUSIVE MODE"
      )

      Repo.query!(
        "ALTER TABLE public.round_entry_participation_rulings DISABLE TRIGGER round_entry_participation_rulings_reject_mutation"
      )

      Repo.query!(
        "ALTER TABLE public.score_revisions DISABLE TRIGGER score_revisions_immutable_rows"
      )

      try do
        delete_fixture_rows!(f)
      after
        Repo.query!(
          "ALTER TABLE public.round_entry_participation_rulings ENABLE ALWAYS TRIGGER round_entry_participation_rulings_reject_mutation"
        )

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
          {"DELETE FROM round_entry_participation_rulings WHERE round_id = $1::uuid", [round]},
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
