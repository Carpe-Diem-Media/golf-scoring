defmodule GolfScoring.LockProtocolTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.MysteryHoleRule
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.CreateCompetitionSide
  alias GolfScoring.GolfCatalog
  alias GolfScoring.LockProtocol
  alias GolfScoring.Repo

  @password "GLS-30 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls30_email_prefix, "gls30-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls30_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "acquire rejects calls outside an open repository transaction" do
    assert_raise ArgumentError, ~r/open repository transaction/, fn ->
      LockProtocol.acquire!(round: [Ecto.UUID.generate()])
    end
  end

  test "non-list lock request values return invalid_lock_request without crashing" do
    round_id = Ecto.UUID.generate()

    assert {:error, {:invalid_lock_request, :round}} =
             transaction_error(fn ->
               LockProtocol.acquire!(round: round_id)
             end)
  end

  test "unknown lock class returns before row lock SQL runs" do
    assert {:error, {:unknown_lock_class, :bogus_lock_class}} =
             transaction_error(fn ->
               LockProtocol.acquire!(bogus_lock_class: [Ecto.UUID.generate()])
             end)
  end

  test "malformed request after a valid entry still fails during request parsing" do
    round_id = Ecto.UUID.generate()

    assert {:error, {:invalid_lock_request, :round}} =
             transaction_error(fn ->
               LockProtocol.acquire!(playing_group: [Ecto.UUID.generate()], round: round_id)
             end)
  end

  test "acquire orders relation classes canonically regardless of caller input order" do
    fixture = setup_representative_fixture!()

    assert {:ok, result} =
             transaction_ok(fn ->
               LockProtocol.acquire!(
                 mystery_hole_rule: [fixture.mystery_rule.id],
                 competition_side: [fixture.side.id],
                 playing_group: [fixture.group.id],
                 round: [fixture.round.id],
                 group_role_assignment: [fixture.assignment.id],
                 competition_side_result: [fixture.side_result.id]
               )
             end)

    assert acquisition_classes(result) == [
             :round,
             :playing_group,
             :group_role_assignment,
             :competition_side,
             :competition_side_result,
             :mystery_hole_rule
           ]
  end

  test "acquire orders duplicate playing group ids stably and without duplicate work" do
    fixture = setup_two_groups_fixture!()
    [first_id, second_id] = sorted_group_ids(fixture.group_a.id, fixture.group_b.id)

    assert {:ok, result} =
             transaction_ok(fn ->
               LockProtocol.acquire!(
                 playing_group: [fixture.group_b.id, fixture.group_a.id, fixture.group_b.id]
               )
             end)

    assert Enum.map(result.acquired, & &1.id) == [first_id, second_id]
    assert length(result.acquired) == 2
  end

  test "acquire uses stable UUID order within a relation class" do
    fixture = setup_two_groups_fixture!()
    [first_id, second_id] = sorted_group_ids(fixture.group_a.id, fixture.group_b.id)

    assert {:ok, result} =
             transaction_ok(fn ->
               LockProtocol.acquire!(playing_group: [fixture.group_b.id, fixture.group_a.id])
             end)

    assert Enum.map(result.acquired, & &1.id) == [first_id, second_id]
  end

  test "a second transaction blocks on the same locked row until the first releases" do
    fixture = setup_committed_round_lock_fixture!()
    parent = self()

    try do
      blocker =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, _} = LockProtocol.acquire!(round: [fixture.round_id])
              send(parent, {:gls30_lock_held, pg_backend_pid()})

              receive do
                :gls30_release_lock -> :released
              after
                15_000 -> Repo.rollback(:gls30_blocker_timeout)
              end
            end)
          end)
        end)

      assert_receive {:gls30_lock_held, _blocker_backend}, 5_000

      waiter =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls30_waiter_ready, pg_backend_pid()})

            Repo.transaction(fn ->
              case LockProtocol.acquire!(round: [fixture.round_id]) do
                {:ok, _} = ok ->
                  send(parent, :gls30_waiter_acquired)
                  ok

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)
          end)
        end)

      assert_receive {:gls30_waiter_ready, waiter_backend}, 5_000
      await_lock_waiters!([waiter_backend])
      refute_received_message(:gls30_waiter_acquired, 200)

      send(blocker.pid, :gls30_release_lock)
      assert {:ok, _} = Task.await(blocker, 10_000)
      assert {:ok, {:ok, %{acquired: [_]}}} = Task.await(waiter, 10_000)
      assert_received_message(:gls30_waiter_acquired, 5_000)
    after
      cleanup_committed_round_lock_fixture!(fixture)
    end
  end

  test "opposite caller order canonicalizes to the same acquisition order under concurrency" do
    fixture = setup_committed_two_groups_fixture!()
    [first_id, second_id] = sorted_group_ids(fixture.group_a_id, fixture.group_b_id)
    parent = self()
    start_ref = make_ref()

    try do
      task_a =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {start_ref, :ready_a})
            receive do: (^start_ref -> :go)

            transaction_ok(fn ->
              LockProtocol.acquire!(playing_group: [fixture.group_b_id, fixture.group_a_id])
            end)
          end)
        end)

      task_b =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {start_ref, :ready_b})
            receive do: (^start_ref -> :go)

            transaction_ok(fn ->
              LockProtocol.acquire!(playing_group: [fixture.group_a_id, fixture.group_b_id])
            end)
          end)
        end)

      assert_receive {^start_ref, :ready_a}, 5_000
      assert_receive {^start_ref, :ready_b}, 5_000
      send(task_a.pid, start_ref)
      send(task_b.pid, start_ref)

      assert {:ok, result_a} = Task.await(task_a, 15_000)
      assert {:ok, result_b} = Task.await(task_b, 15_000)

      expected = [first_id, second_id]

      assert Enum.map(result_a.acquired, & &1.id) == expected
      assert Enum.map(result_b.acquired, & &1.id) == expected
    after
      cleanup_committed_two_groups_fixture!(fixture)
    end
  end

  test "missing row ids fail without acquiring a partial lock set" do
    fixture = setup_representative_fixture!()
    missing_id = Ecto.UUID.generate()

    assert {:error, :playing_group_not_found} =
             Repo.transaction(fn ->
               case LockProtocol.acquire!(
                      round: [fixture.round.id],
                      playing_group: [missing_id]
                    ) do
                 {:error, reason} -> Repo.rollback(reason)
                 {:ok, _} -> Repo.rollback(:unexpected_success)
               end
             end)

    assert {:ok, %{acquired: acquired}} =
             transaction_ok(fn ->
               LockProtocol.acquire!(
                 round: [fixture.round.id],
                 playing_group: [fixture.group.id]
               )
             end)

    assert length(acquired) == 2
  end

  test "rollback releases row locks so a waiting transaction can proceed" do
    fixture = setup_committed_round_lock_fixture!()
    parent = self()

    try do
      blocker =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert {:ok, _} = LockProtocol.acquire!(round: [fixture.round_id])
              send(parent, {:gls30_rollback_held, pg_backend_pid()})

              receive do
                :gls30_rollback_now -> Repo.rollback(:gls30_intentional_rollback)
              after
                15_000 -> Repo.rollback(:gls30_blocker_timeout)
              end
            end)
          end)
        end)

      assert_receive {:gls30_rollback_held, _}, 5_000

      waiter =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:gls30_rollback_waiter_ready, pg_backend_pid()})

            Repo.transaction(fn ->
              case LockProtocol.acquire!(round: [fixture.round_id]) do
                {:ok, _} = ok ->
                  send(parent, :gls30_rollback_waiter_acquired)
                  ok

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)
          end)
        end)

      assert_receive {:gls30_rollback_waiter_ready, waiter_backend}, 5_000
      await_lock_waiters!([waiter_backend])
      refute_received_message(:gls30_rollback_waiter_acquired, 200)

      send(blocker.pid, :gls30_rollback_now)
      assert {:error, :gls30_intentional_rollback} = Task.await(blocker, 10_000)
      assert {:ok, {:ok, %{acquired: [_]}}} = Task.await(waiter, 10_000)
    after
      cleanup_committed_round_lock_fixture!(fixture)
    end
  end

  test "future lock classes are rejected without querying their tables" do
    missing_id = Ecto.UUID.generate()

    assert {:error, {:lock_class_not_yet_available, :verification_row}} =
             transaction_error(fn ->
               LockProtocol.acquire!(verification_row: [missing_id])
             end)

    refute future_table_sql_fragment?("hole_results")
    refute future_table_sql_fragment?("score_queries")
    refute future_table_sql_fragment?("mystery_reveals")
  end

  test "score_row locks scorecards in stable UUID order with row facts" do
    fixture = setup_representative_fixture!()

    card_a =
      GolfScoring.Scoring.Scorecard
      |> Changeset.for_create(:create_internal, %{
        round_id: fixture.round.id,
        round_entry_id: fixture.assignment.round_entry_id
      })
      |> Ash.create!(authorize?: false)

    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(fixture.event.id, fixture.round.id, player.id,
        actor: fixture.admin
      )

    card_b =
      GolfScoring.Scoring.Scorecard
      |> Changeset.for_create(:create_internal, %{
        round_id: fixture.round.id,
        round_entry_id: entry.id
      })
      |> Ash.create!(authorize?: false)

    [first_id, second_id] = sorted_group_ids(card_a.id, card_b.id)

    assert {:ok, result} =
             transaction_ok(fn ->
               LockProtocol.acquire!(score_row: [card_b.id, card_a.id])
             end)

    assert Enum.map(result.acquired, & &1.class) == [:score_row, :score_row]
    assert Enum.map(result.acquired, & &1.id) == [first_id, second_id]
    assert Enum.all?(result.acquired, &match?(%{row: %{state: _}}, &1))
  end

  test "missing scorecard id returns scorecard_not_found" do
    assert {:error, :scorecard_not_found} =
             transaction_error(fn ->
               LockProtocol.acquire!(score_row: [Ecto.UUID.generate()])
             end)
  end

  test "documented total relation order includes future classes after current rows" do
    assert LockProtocol.relation_order() == [
             :round,
             :playing_group,
             :group_role_assignment,
             :competition_side,
             :competition_side_result,
             :score_row,
             :verification_row,
             :query_row,
             :mystery_hole_rule,
             :mystery_reveal
           ]

    assert :round in LockProtocol.implemented_lock_classes()
    assert :score_row in LockProtocol.implemented_lock_classes()
    refute :verification_row in LockProtocol.implemented_lock_classes()
  end

  defp transaction_error(fun) do
    case transaction_ok(fun) do
      {:ok, _} -> flunk("expected transaction error")
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction_ok(fun) do
    Repo.transaction(fn -> unwrap_transaction_fun(fun) end)
    |> normalize_transaction_result()
  end

  defp unwrap_transaction_fun(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, reason} -> Repo.rollback(reason)
      other -> Repo.rollback({:unexpected_transaction_result, other})
    end
  end

  defp normalize_transaction_result({:ok, {:ok, result}}), do: {:ok, result}

  defp normalize_transaction_result({:ok, other}),
    do: flunk("unexpected ok transaction result: #{inspect(other)}")

  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp acquisition_classes(%{acquired: acquired}) do
    Enum.map(acquired, & &1.class)
  end

  defp sorted_group_ids(id_a, id_b) do
    [id_a, id_b] |> Enum.sort_by(&Ecto.UUID.dump!/1)
  end

  defp setup_representative_fixture! do
    event = create_event!()
    admin = create_staff_user!()

    insert_event_admin!(event, admin)

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, entry} =
             AssignEntryToGroup.run(
               admin,
               event.id,
               round.id,
               entry.id,
               group.id
             )

    assert {:ok, assignment} =
             Competition.assign_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               entry.id
             )

    assert {:ok, competition} =
             ConfigureRoundCompetition.run(admin, event.id, round.id, %{})

    assert {:ok, side} =
             CreateCompetitionSide.run(
               admin,
               event.id,
               round.id,
               competition.id,
               :solo
             )

    side_result =
      CompetitionSideResult
      |> Ash.Query.filter(competition_side_id == ^side.id)
      |> Ash.read_one!(authorize?: false)

    catalog_holes = create_eighteen_holes!(event, admin, course)

    {:ok, _route} =
      ConfigureRoundLayout.run(admin, round.id, Enum.map(catalog_holes, & &1.id))

    [[round_hole_id]] =
      Repo.query!(
        "SELECT id::text FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order LIMIT 1",
        [Ecto.UUID.dump!(round.id)]
      ).rows

    round_hole_id = Ecto.UUID.cast!(round_hole_id)

    assert {:ok, track} =
             Competition.configure_scoring_track(
               admin,
               event.id,
               round.id,
               competition.id,
               %{
                 track_type: :mystery,
                 name: "Mystery #{System.unique_integer([:positive])}",
                 is_primary: false,
                 visibility_policy_identifier: "staff_only_v1",
                 aggregation_policy_identifier: "mystery_v1",
                 tie_break_policy_identifier: "mystery_holes_then_countback_v1"
               }
             )

    assert {:ok, %MysteryHoleRule{} = rule} =
             Competition.configure_mystery_hole_rule(
               admin,
               event.id,
               round.id,
               track.id,
               round_hole_id,
               :best
             )

    %{
      event: event,
      round: round,
      group: group,
      assignment: assignment,
      side: side,
      side_result: side_result,
      mystery_rule: rule,
      admin: admin
    }
  end

  defp setup_committed_round_lock_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      event = create_event!()
      admin = create_staff_user!()
      insert_event_admin!(event, admin)
      course = create_course!(event, admin)
      {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)

      %{
        event_id: event.id,
        round_id: round.id,
        admin_id: admin.id,
        course_id: course.id
      }
    end)
  end

  defp cleanup_committed_round_lock_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      dumped_round = Ecto.UUID.dump!(fixture.round_id)
      dumped_event = Ecto.UUID.dump!(fixture.event_id)
      dumped_staff = Ecto.UUID.dump!(fixture.admin_id)

      Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [dumped_round])

      Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [
        dumped_event
      ])

      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [dumped_staff])
    end)
  end

  defp setup_committed_two_groups_fixture! do
    Sandbox.unboxed_run(Repo, fn ->
      event = create_event!()
      admin = create_staff_user!()
      insert_event_admin!(event, admin)
      course = create_course!(event, admin)
      {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
      {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
      {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)

      %{
        event_id: event.id,
        round_id: round.id,
        admin_id: admin.id,
        group_a_id: group_a.id,
        group_b_id: group_b.id
      }
    end)
  end

  defp cleanup_committed_two_groups_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      dumped_round = Ecto.UUID.dump!(fixture.round_id)
      dumped_event = Ecto.UUID.dump!(fixture.event_id)
      dumped_staff = Ecto.UUID.dump!(fixture.admin_id)

      Repo.query!("DELETE FROM playing_groups WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [dumped_round])

      Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [
        dumped_event
      ])

      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [dumped_staff])
    end)
  end

  defp setup_two_groups_fixture! do
    event = create_event!()
    admin = create_staff_user!()
    insert_event_admin!(event, admin)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)

    %{event: event, round: round, admin: admin, group_a: group_a, group_b: group_b}
  end

  defp await_lock_waiters!(backend_pids) do
    deadline = System.monotonic_time(:millisecond) + 10_000
    do_await_lock_waiters(backend_pids, deadline)
  end

  defp do_await_lock_waiters(backend_pids, deadline) do
    waiters =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.query!(
          "SELECT pid FROM pg_stat_activity WHERE pid = ANY($1::int[]) AND wait_event_type = 'Lock'",
          [backend_pids]
        ).rows
        |> Enum.map(&hd/1)
      end)

    if length(Enum.uniq(waiters)) == length(backend_pids) do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("expected each independent PostgreSQL session to wait on a row lock")
      else
        do_await_lock_waiters(backend_pids, deadline)
      end
    end
  end

  defp pg_backend_pid do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp refute_received_message(message, timeout_ms) do
    receive do
      ^message -> flunk("unexpected message #{inspect(message)}")
    after
      timeout_ms -> :ok
    end
  end

  defp assert_received_message(message, timeout_ms) do
    assert_receive ^message, timeout_ms
  end

  defp future_table_sql_fragment?(table_name) do
    path = Path.join(File.cwd!(), "lib/golf_scoring/lock_protocol.ex")
    source = File.read!(path)
    String.contains?(source, table_name)
  end

  defp create_event! do
    Event
    |> Changeset.for_create(:create_internal, %{})
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_user! do
    prefix = Process.get(:gls30_email_prefix)
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp insert_event_admin!(event, staff) do
    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id)]
    )
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfCatalog.create_course(
        event.id,
        %{name: "GLS-30 #{System.unique_integer([:positive])}", location: "Test"},
        actor: admin
      )

    course
  end

  defp create_player! do
    GolfScoring.Competition.Player
    |> Changeset.for_create(:create_internal, %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_eighteen_holes!(event, admin, course) do
    for n <- 1..18 do
      {:ok, hole} =
        GolfCatalog.configure_course_hole(
          event.id,
          %{course_id: course.id, hole_number: n},
          actor: admin
        )

      hole
    end
  end
end
