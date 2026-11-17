defmodule GolfScoring.Scoring.Services.LoadStandardStandingsTest do
  use GolfScoring.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  alias GolfScoring.Scoring.Services.LoadStandardStandings

  test "rejects invalid identifiers" do
    assert {:error, :invalid_scope} = LoadStandardStandings.run("invalid", "invalid", "invalid")
  end

  test "an event admin can read staff standings" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      assert {:ok, standings} =
               LoadStandardStandings.run_for_staff(f.admin, f.event.id, f.round.id, f.track.id)

      assert length(standings) == 2
    end)
  end

  test "staff authorization uses current event roles and stops before standings queries" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)
    {:ok, other} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(other) end)

    verified_unboxed(fn ->
      read = fn ->
        LoadStandardStandings.run_for_staff(f.admin, f.event.id, f.round.id, f.track.id)
      end

      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:golf_scoring, :repo, :query],
          &__MODULE__.capture_query/4,
          self()
        )

      try do
        for role <- ["event_admin", "competition_manager"] do
          Repo.query!("UPDATE event_staff_assignments SET role = $2 WHERE event_id = $1::uuid", [
            uuid(f.event.id),
            role
          ])

          Process.put(:standings_queries, [])
          {micros, result} = :timer.tc(read)

          reads =
            Process.get(:standings_queries)
            |> Enum.filter(&String.starts_with?(&1, ["SELECT ", "WITH "]))

          IO.puts("GLS-42.3A role=#{role} sides=2 reads=#{length(reads)} elapsed_us=#{micros}")
          assert length(reads) == 10
          assert {:ok, standings} = result
          assert length(standings) == 2

          assert Enum.all?(
                   standings,
                   &(Enum.sort(Map.keys(&1)) == [
                       :display_status,
                       :holes_completed,
                       :position,
                       :side_id,
                       :subtotal
                     ])
                 )
        end

        for role <- ["scoring_support", "registration_staff"] do
          Repo.query!("UPDATE event_staff_assignments SET role = $2 WHERE event_id = $1::uuid", [
            uuid(f.event.id),
            role
          ])

          assert_denied_without_evidence(read)
        end

        Repo.query!(
          "UPDATE event_staff_assignments SET role = 'event_admin' WHERE event_id = $1::uuid",
          [uuid(f.event.id)]
        )

        for status <- ["suspended", "disabled"] do
          Repo.query!("UPDATE staff_users SET status = $2 WHERE id = $1::uuid", [
            uuid(f.admin.id),
            status
          ])

          assert_denied_without_evidence(read)
        end

        Repo.query!(
          "UPDATE staff_users SET status = 'active', system_admin = true WHERE id = $1::uuid",
          [uuid(f.admin.id)]
        )

        assert {:ok, _} = read.()

        Repo.query!(
          "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid",
          [uuid(f.event.id)]
        )

        assert_denied_without_evidence(read)

        assert_denied_without_evidence(fn ->
          LoadStandardStandings.run_for_staff(other.admin, f.event.id, f.round.id, f.track.id)
        end)

        assert {:error, :invalid_scope} =
                 LoadStandardStandings.run_for_staff(nil, f.event.id, f.round.id, f.track.id)

        assert {:error, :invalid_scope} =
                 LoadStandardStandings.run_for_staff(
                   %{id: f.admin.id},
                   f.event.id,
                   f.round.id,
                   f.track.id
                 )

        for {event, round, track} <- [
              {"bad", f.round.id, f.track.id},
              {f.event.id, "bad", f.track.id},
              {f.event.id, f.round.id, "bad"}
            ] do
          assert {:error, :invalid_scope} =
                   LoadStandardStandings.run_for_staff(f.admin, event, round, track)
        end

        assert {:ok, {:error, :outer_transaction_required}} = Repo.transaction(read)

        assert {:error, :invalid_scope} =
                 LoadStandardStandings.run_for_staff(
                   other.admin,
                   other.event.id,
                   f.round.id,
                   f.track.id
                 )

        assert {:error, :invalid_scope} =
                 LoadStandardStandings.run_for_staff(
                   other.admin,
                   other.event.id,
                   other.round.id,
                   f.track.id
                 )
      after
        :telemetry.detach(handler)
      end
    end)
  end

  defp assert_denied_without_evidence(read) do
    Process.put(:standings_queries, [])
    assert {:error, :not_found_or_forbidden} = read.()

    reads =
      Process.get(:standings_queries)
      |> Enum.filter(&String.starts_with?(&1, ["SELECT ", "WITH "]))

    assert length(reads) == 1
    assert hd(reads) =~ "FROM staff_users"
  end

  test "authorization and standings share a snapshot across revocation" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)
    parent = self()

    reader =
      Task.async(fn ->
        verified_unboxed(fn ->
          handler = {__MODULE__, make_ref()}

          :ok =
            :telemetry.attach(
              handler,
              [:golf_scoring, :repo, :query],
              &__MODULE__.pause_after_authorization/4,
              %{owner: self(), parent: parent}
            )

          try do
            LoadStandardStandings.run_for_staff(f.admin, f.event.id, f.round.id, f.track.id)
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    try do
      assert_receive {:authorization_read, reader_pid}, 30_000

      verified_unboxed(fn ->
        Repo.query!(
          "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid",
          [uuid(f.event.id)]
        )
      end)

      send(reader_pid, :continue)
      assert {:ok, standings} = Task.await(reader, 30_000)
      assert length(standings) == 2

      verified_unboxed(fn ->
        assert {:error, :not_found_or_forbidden} =
                 LoadStandardStandings.run_for_staff(f.admin, f.event.id, f.round.id, f.track.id)
      end)
    after
      send(reader.pid, :continue)
      Task.shutdown(reader, 5_000)
    end
  end

  @doc false
  def pause_after_authorization(_event, _measurements, metadata, config) do
    if self() == config.owner and String.contains?(metadata.query, "FROM staff_users staff") do
      send(config.parent, {:authorization_read, self()})

      receive do
        :continue -> :ok
      after
        30_000 -> raise "timed out waiting for revocation"
      end
    end
  end

  test "loads scoped sides deterministically with pending and recorded zero and no private evidence" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      assert {:ok, _} =
               Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
                 client_submission_id: Ecto.UUID.generate(),
                 playing_group_id: f.group.id,
                 round_hole_id: f.start_hole.id,
                 expected_group_score_revision: 0,
                 captured_at: DateTime.utc_now(),
                 results:
                   Enum.map(f.entries, fn e ->
                     %{
                       round_entry_id: e.id,
                       outcome: :picked_up,
                       gross_strokes: nil,
                       strokes_taken: 10
                     }
                   end)
               })

      handler = {__MODULE__, make_ref()}
      Process.put(:standings_queries, [])

      :ok =
        :telemetry.attach(
          handler,
          [:golf_scoring, :repo, :query],
          &__MODULE__.capture_query/4,
          self()
        )

      {micros, result} =
        :timer.tc(fn -> LoadStandardStandings.run(f.event.id, f.round.id, f.track.id) end)

      :telemetry.detach(handler)
      queries = Process.get(:standings_queries)
      reads = Enum.filter(queries, &String.starts_with?(&1, ["SELECT ", "WITH "]))

      IO.puts(
        "GLS-42.2B measurement sides=2 reads=#{length(reads)} total_sql=#{length(queries)} elapsed_us=#{micros}"
      )

      assert length(reads) == 9
      assert {:ok, standings} = result
      assert length(standings) == 2
      assert Enum.map(standings, & &1.side_id) == Enum.sort(Enum.map(f.sides, & &1.id))

      assert Enum.all?(
               standings,
               &(&1.subtotal == 0 and &1.holes_completed == 1 and &1.position == 1)
             )

      assert Enum.all?(
               standings,
               &(Map.keys(&1) |> Enum.sort() == [
                   :display_status,
                   :holes_completed,
                   :position,
                   :side_id,
                   :subtotal
                 ])
             )

      assert {:ok, ^standings} = LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)

      assert {:error, :invalid_scope} =
               LoadStandardStandings.run(Ecto.UUID.generate(), f.round.id, f.track.id)

      assert {:error, :invalid_scope} =
               LoadStandardStandings.run(f.event.id, Ecto.UUID.generate(), f.track.id)

      assert {:error, :invalid_scope} =
               LoadStandardStandings.run(f.event.id, f.round.id, Ecto.UUID.generate())

      assert {:ok, {:error, :outer_transaction_required}} =
               Repo.transaction(fn ->
                 LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
               end)

      Repo.query!(
        "UPDATE competition_side_results SET state = 'review_required' WHERE competition_side_id = $1::uuid",
        [uuid(hd(f.sides).id)]
      )

      assert {:ok, review} = LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
      assert Enum.find(review, &(&1.side_id == hd(f.sides).id)).display_status == :under_review

      Repo.query!(
        "UPDATE competition_side_results SET state = 'excluded', excluded_by_staff_user_id = $2::uuid, exclusion_reason = 'test exclusion', excluded_at = now(), excluded_playing_group_id = $3::uuid, excluded_effective_round_hole_id = $4::uuid, excluded_effective_play_index = 1, excluded_preplay_confirmed = true WHERE competition_side_id = $1::uuid",
        [
          uuid(List.last(f.sides).id),
          uuid(f.admin.id),
          uuid(f.group.id),
          uuid(Enum.at(f.route, 1).id)
        ]
      )

      assert {:ok, excluded} = LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)

      assert %{position: nil, display_status: :unranked} =
               Enum.find(excluded, &(&1.side_id == List.last(f.sides).id))

      Repo.query!("UPDATE course_holes SET hole_number = 19 WHERE id = $1::uuid", [
        uuid(hd(f.catalog_holes).id)
      ])

      assert {:error, :inconsistent_evidence} =
               LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)

      Repo.query!("UPDATE course_holes SET hole_number = 1 WHERE id = $1::uuid", [
        uuid(hd(f.catalog_holes).id)
      ])

      Repo.query!("UPDATE scoring_tracks SET configuration_state = 'draft' WHERE id = $1::uuid", [
        uuid(f.track.id)
      ])

      assert {:error, :invalid_scope} =
               LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)

      Repo.query!(
        "UPDATE scoring_tracks SET configuration_state = 'locked' WHERE id = $1::uuid",
        [uuid(f.track.id)]
      )

      Repo.query!("DELETE FROM competition_side_results WHERE competition_side_id = $1::uuid", [
        uuid(hd(f.sides).id)
      ])

      assert {:error, :inconsistent_evidence} =
               LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
    end)
  end

  test "rejects cross-event and cross-round track ownership and duplicate SideResult creation" do
    {:ok, first} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(first) end)
    {:ok, other} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(other) end)

    verified_unboxed(fn ->
      for {event, round, track} <- [
            {other.event.id, first.round.id, first.track.id},
            {first.event.id, other.round.id, first.track.id},
            {first.event.id, first.round.id, other.track.id},
            {other.event.id, other.round.id, first.track.id}
          ] do
        assert {:error, :invalid_scope} = LoadStandardStandings.run(event, round, track)
      end

      assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
               Repo.query(
                 "INSERT INTO competition_side_results (id, competition_side_id, state, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, 'provisional', now(), now())",
                 [uuid(Ecto.UUID.generate()), uuid(hd(first.sides).id)]
               )

      assert {:ok, _} = LoadStandardStandings.run(first.event.id, first.round.id, first.track.id)
    end)
  end

  test "a withdrawn solo Side is non-computable and exposes no withdrawal evidence" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      assert {:ok, _} =
               Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
                 client_submission_id: Ecto.UUID.generate(),
                 playing_group_id: f.group.id,
                 round_hole_id: f.start_hole.id,
                 expected_group_score_revision: 0,
                 captured_at: DateTime.utc_now(),
                 results:
                   Enum.map(f.entries, fn entry ->
                     %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 4}
                   end)
               })

      entry = List.last(f.entries)

      assert {:ok, ruling} =
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
                     effective_round_hole_id: Enum.at(f.route, 1).id,
                     effective_play_index: 1,
                     confirms_unplayed?: true
                   }
                 }
               )

      assert {:ok, standings} = LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
      withdrawn = Enum.find(standings, &(&1.side_id == List.last(f.sides).id))
      assert %{position: nil, display_status: :under_review, holes_completed: 1} = withdrawn

      assert Enum.all?(standings, fn row ->
               Map.keys(row) |> Enum.sort() == [
                 :display_status,
                 :holes_completed,
                 :position,
                 :side_id,
                 :subtotal
               ]
             end)

      refute inspect(standings) =~ ruling.ruling_id
      refute inspect(standings) =~ entry.id
      refute inspect(standings) =~ "revision"
      refute inspect(standings) =~ "mystery"
    end)
  end

  test "complete ties use physical holes with a shotgun start" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      start = Enum.at(f.route, 9)

      Repo.query!(
        "UPDATE playing_groups SET starting_round_hole_id = $2::uuid WHERE id = $1::uuid",
        [uuid(f.group.id), uuid(start.id)]
      )

      rotated = Enum.drop(f.route, 9) ++ Enum.take(f.route, 9)

      for {hole, revision} <- Enum.with_index(rotated) do
        physical = Enum.find_index(f.route, &(&1.id == hole.id)) + 1

        results =
          Enum.with_index(f.entries)
          |> Enum.map(fn {entry, index} ->
            gross =
              case {physical, index} do
                {18, 0} -> 3
                {18, 1} -> 5
                {9, 0} -> 5
                {9, 1} -> 3
                _ -> 4
              end

            %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: gross}
          end)

        assert {:ok, _} =
                 Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
                   client_submission_id: Ecto.UUID.generate(),
                   playing_group_id: f.group.id,
                   round_hole_id: hole.id,
                   expected_group_score_revision: revision,
                   captured_at: DateTime.utc_now(),
                   results: results
                 })
      end

      assert {:ok, [winner, runner_up]} =
               LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)

      assert winner.side_id == hd(f.sides).id and winner.position == 1
      assert runner_up.side_id == List.last(f.sides).id and runner_up.position == 2
      assert winner.subtotal == runner_up.subtotal and winner.holes_completed == 18
    end)
  end

  test "a correction between Side reads remains outside the old snapshot" do
    {:ok, f} = verified_unboxed_transaction(fn -> fixture!() end)
    on_exit(fn -> cleanup!(f) end)

    verified_unboxed(fn ->
      assert {:ok, _} =
               Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
                 client_submission_id: Ecto.UUID.generate(),
                 playing_group_id: f.group.id,
                 round_hole_id: f.start_hole.id,
                 expected_group_score_revision: 0,
                 captured_at: DateTime.utc_now(),
                 results:
                   Enum.map(f.entries, fn e ->
                     %{round_entry_id: e.id, outcome: :holed_out, gross_strokes: 4}
                   end)
               })
    end)

    parent = self()

    reader =
      Task.async(fn ->
        verified_unboxed(fn ->
          [[pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          handler = {__MODULE__, make_ref()}
          Process.put(:side_reads, 0)

          :ok =
            :telemetry.attach(
              handler,
              [:golf_scoring, :repo, :query],
              &__MODULE__.pause_between_sides/4,
              %{owner: self(), parent: parent, pid: pid}
            )

          try do
            LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
          after
            :telemetry.detach(handler)
          end
        end)
      end)

    try do
      assert_receive {:between_sides, reader_pid, reader_db}, 30_000
      second_side = f.sides |> Enum.sort_by(& &1.id) |> List.last()

      writer =
        Task.async(fn ->
          verified_unboxed(fn ->
            [[writer_db]] = Repo.query!("SELECT pg_backend_pid()").rows

            [[result_id]] =
              Repo.query!(
                """
                SELECT hr.id::text FROM competition_side_memberships m
                JOIN scorecards sc ON sc.round_entry_id = m.round_entry_id
                JOIN hole_results hr ON hr.scorecard_id = sc.id
                WHERE m.competition_side_id = $1::uuid AND hr.round_hole_id = $2::uuid
                """,
                [uuid(second_side.id), uuid(f.start_hole.id)]
              ).rows

            result =
              Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
                hole_result_id: result_id,
                expected_revision: 1,
                new_gross_strokes: 9,
                reason: "standings snapshot correction"
              })

            {writer_db, result}
          end)
        end)

      {writer_db, correction} = Task.await(writer, 30_000)
      assert writer_db != reader_db
      assert {:ok, _} = correction
      send(reader_pid, :continue)
      assert {:ok, old} = Task.await(reader, 30_000)
      old_second = Enum.find(old, &(&1.side_id == second_side.id))
      assert old_second.subtotal > 0 and old_second.display_status == :provisional

      verified_unboxed(fn ->
        assert {:ok, fresh} = LoadStandardStandings.run(f.event.id, f.round.id, f.track.id)
        new_second = Enum.find(fresh, &(&1.side_id == second_side.id))
        assert new_second.subtotal == 0 and new_second.display_status == :under_review
      end)
    after
      send(reader.pid, :continue)
      Task.shutdown(reader, 5_000)
    end
  end

  @doc false
  def pause_between_sides(_event, _measurements, metadata, config) do
    if self() == config.owner and
         String.starts_with?(String.trim_leading(metadata.query), "SELECT current_setting") do
      count = Process.get(:side_reads, 0) + 1
      Process.put(:side_reads, count)

      if count == 2 do
        send(config.parent, {:between_sides, self(), config.pid})

        receive do
          :continue -> :ok
        after
          30_000 -> raise "timed out waiting for correction"
        end
      end
    end
  end

  @doc false
  def capture_query(_event, _measurements, metadata, owner) do
    if self() == owner do
      Process.put(:standings_queries, [
        String.trim_leading(metadata.query) | Process.get(:standings_queries, [])
      ])
    end
  end

  defp fixture! do
    f = Fixtures.setup_submit_fixture!(2)
    Fixtures.set_round_state!(f.round, :draft)

    sides =
      Enum.map(f.entries, fn entry ->
        {:ok, side} =
          Competition.create_competition_side(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            :solo
          )

        {:ok, _} =
          Fixtures.set_side_membership_for_fixture(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            side.id,
            [entry.id]
          )

        side
      end)

    {:ok, track} =
      Competition.configure_scoring_track(f.admin, f.event.id, f.round.id, f.competition.id, %{
        track_type: :standard_better_ball,
        name: "Standard Better-Ball",
        is_primary: false,
        visibility_policy_identifier: "leaderboard_v1",
        aggregation_policy_identifier: "standard_better_ball_v1",
        tie_break_policy_identifier: "standard_countback_v1"
      })

    Repo.query!("UPDATE scoring_tracks SET configuration_state = 'locked' WHERE id = $1::uuid", [
      uuid(track.id)
    ])

    Fixtures.set_round_state!(f.round, :scoring_open)
    Map.merge(f, %{sides: sides, track: track})
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
          {"DELETE FROM scoring_tracks WHERE round_id = $1::uuid", [round]},
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
