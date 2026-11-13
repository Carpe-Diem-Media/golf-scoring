defmodule GolfScoring.Competition.RoundEntryTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.EventStaffAssignment
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.Player
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignRoundTee
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.ReplaceRoundEntry
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.Competition.StartingParticipant
  alias GolfScoring.Repo

  @password "GLS-16 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls16_email_prefix, "gls16-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls16_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "add_round_entry creates expected/not_started exactly once for one Player/Round" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert entry.registration_status == :expected
    assert entry.participation_status == :not_started
    assert entry.event_id == event.id
    assert entry.round_id == round.id
    assert entry.player_id == player.id
    assert is_nil(entry.checked_in_at)
    assert is_nil(entry.checked_in_by_staff_user_id)
    assert round_entry_count(round.id) == 1
  end

  test "Player and RoundEntry are separate resources with guarded domain surface" do
    assert Player in Ash.Domain.Info.resources(Competition)
    assert RoundEntry in Ash.Domain.Info.resources(Competition)
    assert Info.action(RoundEntry, :add_round_entry)
    assert Info.action(RoundEntry, :check_in_round_entry)
    assert is_nil(Info.action(RoundEntry, :create))
    assert is_nil(Info.action(RoundEntry, :update))
    assert is_nil(Info.action(RoundEntry, :destroy))
    assert is_nil(Info.action(Player, :create))
    refute function_exported?(Competition, :update_round_entry, 2)
  end

  test "replacement coordinator uses private internal Ash lifecycle actions only" do
    assert Info.action(RoundEntry, :mark_replaced_before_start_internal)
    assert Info.action(RoundEntry, :create_replacement_entry_internal)
    refute function_exported?(Competition, :mark_replaced_before_start_internal, 1)
    refute function_exported?(Competition, :create_replacement_entry_internal, 3)

    create_round_entry_source =
      File.read!("lib/golf_scoring/competition/changes/create_round_entry.ex")

    replace_source = File.read!("lib/golf_scoring/competition/services/replace_round_entry.ex")

    refute create_round_entry_source =~ "gls16_skip_entry_authorization"
    refute replace_source =~ "UPDATE round_entries"
    refute replace_source =~ ":add_round_entry"
  end

  test "registration lifecycle covers expected and checked_in source states" do
    %{event: event, round: round, admin: admin} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    expected_player = create_player!()

    assert {:ok, expected_entry} =
             Competition.add_round_entry(event.id, round.id, expected_player.id, actor: admin)

    assert {:ok, withdrawn} =
             Competition.withdraw_before_start(expected_entry, actor: staff)

    assert withdrawn.registration_status == :withdrawn_before_start

    checked_player = create_player!()

    assert {:ok, checked_entry} =
             Competition.add_round_entry(event.id, round.id, checked_player.id, actor: admin)

    assert {:ok, checked_entry} =
             Competition.check_in_round_entry(checked_entry, actor: staff)

    assert {:ok, no_show} = Competition.mark_no_show(checked_entry, actor: staff)
    assert no_show.registration_status == :no_show
    assert no_show.participation_status == :not_started
  end

  test "terminal registration entries cannot be revived by ordinary registration actions" do
    %{event: event, round: round, admin: admin} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)

    add_entry = fn ->
      player = create_player!()

      assert {:ok, entry} =
               Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

      entry
    end

    assert {:ok, no_show} = add_entry.() |> then(&Competition.mark_no_show(&1, actor: staff))

    assert {:ok, withdrawn} =
             add_entry.() |> then(&Competition.withdraw_before_start(&1, actor: staff))

    original = add_entry.()

    assert {:ok, %{original: replaced}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               original.id,
               create_player!().id
             )

    for terminal <- [no_show, withdrawn, replaced] do
      assert terminal.registration_status in [
               :no_show,
               :withdrawn_before_start,
               :replaced_before_start
             ]

      assert {:error, _error} = Competition.check_in_round_entry(terminal, actor: staff)
      assert {:error, _error} = Competition.mark_no_show(terminal, actor: staff)
      assert {:error, _error} = Competition.withdraw_before_start(terminal, actor: staff)
    end
  end

  test "registration lifecycle Ash policies require active same-event staff roles" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    registration_staff = create_staff_user!()
    revoked_staff = create_staff_user!()
    inactive_staff = create_staff_user!()

    assign_role!(admin, event, manager, :competition_manager)
    assign_role!(admin, event, registration_staff, :registration_staff)
    assign_role!(admin, event, revoked_staff, :registration_staff)
    assign_role!(admin, event, inactive_staff, :registration_staff)

    other_event = create_event!()
    other_event_admin = create_event_admin!(other_event)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, _revoked} =
             Accounts.revoke_event_staff_role(
               active_assignment_record(event, revoked_staff, :registration_staff),
               actor: admin
             )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(inactive_staff.id)
    ])

    for action <- [:check_in_round_entry, :mark_no_show, :withdraw_before_start] do
      for authorized_actor <- [admin, manager, registration_staff] do
        assert Ash.can?({entry, action}, authorized_actor)
      end

      refute Ash.can?({entry, action}, other_event_admin)
      refute Ash.can?({entry, action}, revoked_staff)
      refute Ash.can?({entry, action}, inactive_staff)
      refute Ash.can?({entry, action}, nil)
    end
  end

  test "PostgreSQL integrity constraints and RESTRICT history" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    other_event = create_event!()
    other_admin = create_event_admin!(other_event)
    other_course = create_course!(other_event, other_admin)

    {:ok, other_round} =
      Competition.create_round(other_event.id, other_course.id, actor: other_admin)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    duplicate_error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO round_entries (event_id, round_id, player_id, registration_status, participation_status)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'expected', 'not_started')
          """,
          [
            Ecto.UUID.dump!(event.id),
            Ecto.UUID.dump!(round.id),
            Ecto.UUID.dump!(player.id)
          ]
        )
      end

    assert duplicate_error.postgres.code == :unique_violation

    assert duplicate_error.postgres.constraint ==
             "round_entries_unique_player_per_round_index"

    cross_event_error =
      assert_raise Postgrex.Error, fn ->
        cross_player = create_player!()

        Repo.query!(
          """
          INSERT INTO round_entries (event_id, round_id, player_id, registration_status, participation_status)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'expected', 'not_started')
          """,
          [
            Ecto.UUID.dump!(other_event.id),
            Ecto.UUID.dump!(round.id),
            Ecto.UUID.dump!(cross_player.id)
          ]
        )
      end

    assert cross_event_error.postgres.code == :foreign_key_violation
    assert cross_event_error.postgres.constraint == "round_entries_round_id_fkey"

    invalid_registration_error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO round_entries (event_id, round_id, player_id, registration_status, participation_status)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'bogus', 'not_started')
          """,
          [
            Ecto.UUID.dump!(event.id),
            Ecto.UUID.dump!(round.id),
            Ecto.UUID.dump!(Ecto.UUID.generate())
          ]
        )
      end

    assert invalid_registration_error.postgres.constraint ==
             "round_entries_registration_status_must_be_valid"

    invalid_participation_error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO round_entries (event_id, round_id, player_id, registration_status, participation_status)
          VALUES ($1::uuid, $2::uuid, $3::uuid, 'expected', 'bogus')
          """,
          [
            Ecto.UUID.dump!(event.id),
            Ecto.UUID.dump!(round.id),
            Ecto.UUID.dump!(Ecto.UUID.generate())
          ]
        )
      end

    assert invalid_participation_error.postgres.constraint ==
             "round_entries_participation_status_must_be_valid"

    assert %Postgrex.Result{rows: [["r"]]} =
             Repo.query!("""
             SELECT c.confdeltype::text
             FROM pg_constraint c
             JOIN unnest(c.conkey) AS key(attnum) ON true
             JOIN pg_attribute a
               ON a.attrelid = c.conrelid
              AND a.attnum = key.attnum
             WHERE c.conrelid = 'round_entries'::regclass
               AND c.contype = 'f'
               AND a.attname = 'player_id'
             """)

    assert_raise Postgrex.Error, fn ->
      Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(player.id)])
    end

    assert %Postgrex.Result{rows: [["r"]]} =
             Repo.query!("""
             SELECT c.confdeltype::text
             FROM pg_constraint c
             JOIN unnest(c.conkey) AS key(attnum) ON true
             JOIN pg_attribute a
               ON a.attrelid = c.conrelid
              AND a.attnum = key.attnum
             WHERE c.conrelid = 'round_entries'::regclass
               AND c.contype = 'f'
               AND c.conname = 'round_entries_event_id_fkey'
             """)

    assert_raise Postgrex.Error, fn ->
      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [Ecto.UUID.dump!(event.id)])
    end

    refute is_nil(entry.id)
    refute is_nil(other_round.id)
  end

  test "add_round_entry authorization matrix and pre-open guardrails" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)
    system_admin = create_system_admin!()

    assert {:ok, _} = Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    player2 = create_player!()

    assert {:ok, _} =
             Competition.add_round_entry(event.id, round.id, player2.id, actor: manager)

    player3 = create_player!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Competition.add_round_entry(event.id, round.id, player3.id, actor: staff)

    player4 = create_player!()

    assert {:error, %Ash.Error.Forbidden{}} =
             Competition.add_round_entry(event.id, round.id, player4.id, actor: system_admin)

    scoring_open = set_round_state!(round, :scoring_open)
    player5 = create_player!()

    assert {:error, _error} =
             Competition.add_round_entry(event.id, scoring_open.id, player5.id, actor: admin)

    assert round_entry_count(round.id) == 2
  end

  test "stale Event Admin and Competition Manager cannot add_round_entry" do
    %{event: event, round: round, admin: admin, player: _player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    stale_admin = admin
    stale_manager = manager
    replacement = create_event_admin!(event)

    assert {:ok, _revoked} =
             Accounts.revoke_event_staff_role(active_assignment_record(event, admin),
               actor: replacement
             )

    player2 = create_player!()

    assert {:error, _error} =
             Competition.add_round_entry(event.id, round.id, player2.id, actor: stale_admin)

    assert {:ok, _revoked_manager} =
             Accounts.revoke_event_staff_role(
               active_assignment_record(event, manager, :competition_manager),
               actor: replacement
             )

    player3 = create_player!()

    assert {:error, _error} =
             Competition.add_round_entry(event.id, round.id, player3.id, actor: stale_manager)

    assert round_entry_count(round.id) == 0
  end

  test "concurrent add_round_entry attempts leave exactly one row" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())

          Competition.add_round_entry(event.id, round.id, player.id, actor: admin)
        end)
      end

    results = Task.await_many(tasks, 30_000)
    successes = Enum.count(results, &match?({:ok, _}, &1))
    assert successes == 1
    assert round_entry_count(round.id) == 1
  end

  test "check_in_round_entry records actor/time and rejects invalid states" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    before = DateTime.utc_now(:microsecond)

    assert {:ok, checked_in} = Competition.check_in_round_entry(entry, actor: staff)
    after_time = DateTime.utc_now(:microsecond)

    assert checked_in.registration_status == :checked_in
    assert checked_in.participation_status == :not_started
    assert checked_in.checked_in_by_staff_user_id == staff.id
    assert DateTime.compare(checked_in.checked_in_at, before) in [:eq, :gt]
    assert DateTime.compare(checked_in.checked_in_at, after_time) in [:eq, :lt]

    assert {:error, _error} = Competition.check_in_round_entry(checked_in, actor: staff)

    withdrawn_player = create_player!()

    assert {:ok, withdrawn} =
             Competition.add_round_entry(event.id, round.id, withdrawn_player.id, actor: admin)

    assert {:ok, withdrawn} = Competition.withdraw_before_start(withdrawn, actor: staff)

    assert {:error, _error} = Competition.check_in_round_entry(withdrawn, actor: staff)
  end

  test "caller cannot spoof check-in actor or timestamp through writable fields" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    check_in_action = Info.action(RoundEntry, :check_in_round_entry)
    assert check_in_action.accept == []

    other_staff = create_staff_user!()

    assert {:ok, checked_in} = Competition.check_in_round_entry(entry, actor: admin)
    assert checked_in.checked_in_by_staff_user_id == admin.id
    refute checked_in.checked_in_by_staff_user_id == other_staff.id
    assert DateTime.diff(checked_in.checked_in_at, ~U[2000-01-01 00:00:00Z], :day) > 365
  end

  test "stale Registration Staff cannot check in after revocation" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)
    stale_staff = staff

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, _revoked} =
             Accounts.revoke_event_staff_role(
               active_assignment_record(event, staff, :registration_staff),
               actor: admin
             )

    assert {:error, _error} = Competition.check_in_round_entry(entry, actor: stale_staff)
    assert entry_registration(entry.id) == "expected"
  end

  test "mark_no_show and withdraw_before_start keep participation not_started" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, expected_entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, no_show} = Competition.mark_no_show(expected_entry, actor: staff)
    assert no_show.registration_status == :no_show
    assert no_show.participation_status == :not_started

    checked_player = create_player!()

    assert {:ok, checked_entry} =
             Competition.add_round_entry(event.id, round.id, checked_player.id, actor: admin)

    assert {:ok, checked_entry} =
             Competition.check_in_round_entry(checked_entry, actor: staff)

    assert {:ok, withdrawn} =
             Competition.withdraw_before_start(checked_entry, actor: staff)

    assert withdrawn.registration_status == :withdrawn_before_start
    assert withdrawn.participation_status == :not_started
    refute withdrawn.participation_status == :withdrawn
  end

  test "registration lifecycle actions reject caller transactions before issuing SQL" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    actions = [
      {:check_in_round_entry, fn -> Competition.check_in_round_entry(entry, actor: staff) end,
       false},
      {:mark_no_show, fn -> Competition.mark_no_show(entry, actor: staff) end, true},
      {:withdraw_before_start, fn -> Competition.withdraw_before_start(entry, actor: staff) end,
       false}
    ]

    expected_state = registration_lifecycle_state(entry.id)

    for {operation, call, hold_entry?} <- actions do
      assert {:ok, {:error, %Ash.Error.Invalid{} = error}} =
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()

                 if hold_entry? do
                   Repo.query!(
                     "SELECT id FROM round_entries WHERE id = $1::uuid FOR UPDATE",
                     [Ecto.UUID.dump!(entry.id)]
                   )
                 end

                 handler = {__MODULE__, make_ref()}
                 event = [:golf_scoring, :repo, :query]

                 :ok =
                   :telemetry.attach(
                     handler,
                     event,
                     &__MODULE__.observe_lifecycle_query/4,
                     self()
                   )

                 try do
                   result = call.()
                   refute_receive {:round_entry_lifecycle_query, _metadata}, 0
                   result
                 after
                   :telemetry.detach(handler)
                 end
               end),
             "#{operation} did not reject the caller-owned transaction before querying"

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidChanges{vars: vars} ->
                 Keyword.get(vars, :reason) == :transaction_already_open

               _error ->
                 false
             end)

      assert registration_lifecycle_state(entry.id) == expected_state
    end
  end

  test "prebuilt registration changesets reject caller transactions before policy SQL" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    actions = [:check_in_round_entry, :mark_no_show, :withdraw_before_start]

    changesets =
      Enum.map(actions, fn action ->
        {action, Ash.Changeset.for_update(entry, action, %{}, actor: staff)}
      end)

    expected_state = registration_lifecycle_state(entry.id)

    for {action, changeset} <- changesets do
      handler = {__MODULE__, make_ref()}

      assert {:ok, {:error, %Ash.Error.Invalid{} = error}} =
               Repo.transaction(fn ->
                 assert Repo.in_transaction?()

                 :ok =
                   :telemetry.attach(
                     handler,
                     [:golf_scoring, :repo, :query],
                     &__MODULE__.observe_lifecycle_query/4,
                     self()
                   )

                 try do
                   result = Ash.update(changeset, actor: staff)
                   refute_receive {:round_entry_lifecycle_query, _metadata}, 0
                   result
                 after
                   :telemetry.detach(handler)
                 end
               end),
             "#{action} checked its policy before rejecting the caller-owned transaction"

      assert Enum.any?(error.errors, fn
               %Ash.Error.Changes.InvalidChanges{vars: vars} ->
                 Keyword.get(vars, :reason) == :transaction_already_open

               _error ->
                 false
             end)

      assert registration_lifecycle_state(entry.id) == expected_state
    end
  end

  test "cannot mark no_show when participation is already active at the database layer" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    force_participation!(entry.id, :active)

    assert {:error, _error} = Competition.mark_no_show(entry, actor: staff)
    assert entry_participation(entry.id) == "active"
  end

  test "checked_in registration does not imply active participation" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, checked_in} = Competition.check_in_round_entry(entry, actor: admin)
    assert checked_in.registration_status == :checked_in
    assert checked_in.participation_status == :not_started
  end

  test "ordinary actions cannot directly set future participation states" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()

    for status <- [:active, :completed, :withdrawn, :disqualified] do
      changeset =
        RoundEntry
        |> Ash.Changeset.for_create(:add_round_entry, %{
          event_id: event.id,
          round_id: round.id,
          player_id: player.id,
          participation_status: status,
          registration_status: :expected
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, actor: admin)
    end
  end

  test "replace_before_start is atomic and preserves original player history" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    replacement = create_player!()

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, %{original: marked, replacement: new_entry}} =
             ReplaceRoundEntry.run(manager, event.id, round.id, original.id, replacement.id)

    assert marked.registration_status == :replaced_before_start
    assert marked.player_id == player.id
    assert new_entry.player_id == replacement.id
    assert new_entry.registration_status == :expected
    assert new_entry.participation_status == :not_started
    assert new_entry.round_id == round.id
    assert new_entry.event_id == event.id
    assert new_entry.id != original.id
    assert round_entry_count(round.id) == 2
  end

  test "replace_before_start inherits original playing group membership" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, grouped} =
             AssignEntryToGroup.run(
               admin,
               event.id,
               round.id,
               original.id,
               group.id
             )

    replacement_player = create_player!()

    assert {:ok, %{original: marked, replacement: new_entry}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               grouped.id,
               replacement_player.id
             )

    assert marked.registration_status == :replaced_before_start
    assert marked.playing_group_id == group.id
    assert new_entry.playing_group_id == group.id
    assert new_entry.player_id == replacement_player.id
  end

  test "replace_before_start leaves unassigned replacement when original had no group" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    replacement_player = create_player!()

    assert {:ok, %{original: marked, replacement: new_entry}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               original.id,
               replacement_player.id
             )

    assert is_nil(marked.playing_group_id)
    assert is_nil(new_entry.playing_group_id)
  end

  test "active group role blocks registration transitions and replacement" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    registration = create_staff_user!()
    assign_role!(admin, event, registration, :registration_staff)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, grouped} =
             AssignEntryToGroup.run(admin, event.id, round.id, original.id, group.id)

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               grouped.id
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Competition.mark_no_show(grouped, actor: registration)

    assert {:error, %Ash.Error.Invalid{}} =
             Competition.withdraw_before_start(grouped, actor: registration)

    replacement_player = create_player!()

    assert {:error, :active_group_role_assignment_blocks_replacement} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               grouped.id,
               replacement_player.id
             )

    assert entry_registration(grouped.id) == "expected"

    assert {:ok, _} =
             Competition.revoke_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               "clear for replacement"
             )

    assert {:ok, _} = Competition.mark_no_show(grouped, actor: registration)
    assert entry_registration(grouped.id) == "no_show"

    replacement_player = create_player!()

    assert {:ok, fresh_entry} =
             Competition.add_round_entry(event.id, round.id, replacement_player.id, actor: admin)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, fresh_entry.id, group.id)

    assert {:ok, _} =
             Competition.withdraw_before_start(fresh_entry, actor: registration)

    assert entry_registration(fresh_entry.id) == "withdrawn_before_start"
  end

  test "replacement after role revoke does not inherit group role authority" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, grouped} =
             AssignEntryToGroup.run(admin, event.id, round.id, original.id, group.id)

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               grouped.id
             )

    assert {:ok, _} =
             Competition.revoke_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               "clear for replacement"
             )

    successor_player = create_player!()

    assert {:ok, %{replacement: successor}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               grouped.id,
               successor_player.id
             )

    role_rows =
      GroupRoleAssignment
      |> Ash.Query.filter(round_entry_id == ^successor.id)
      |> Ash.read!(authorize?: false)

    assert role_rows == []
  end

  test "full four-current-starter group replacement keeps four current starters" do
    %{event: event, round: round, admin: admin} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entries =
      for _ <- 1..4 do
        player = create_player!()

        {:ok, entry} =
          Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

        {:ok, entry} =
          AssignEntryToGroup.run(
            admin,
            event.id,
            round.id,
            entry.id,
            group.id
          )

        entry
      end

    replacement_player = create_player!()
    [to_replace | _rest] = entries

    assert {:ok, %{original: marked, replacement: new_entry}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               to_replace.id,
               replacement_player.id
             )

    assert marked.playing_group_id == group.id
    assert new_entry.playing_group_id == group.id

    assert current_starting_participant_count(group.id) == 4
    assert round_entry_count(round.id) == 5
  end

  test "replace_before_start authorization and guardrails" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    replacement = create_player!()

    assert {:error, :forbidden} =
             ReplaceRoundEntry.run(staff, event.id, round.id, original.id, replacement.id)

    already_entered = create_player!()

    assert {:ok, _} =
             Competition.add_round_entry(event.id, round.id, already_entered.id, actor: admin)

    assert {:error, :replacement_already_entered} =
             ReplaceRoundEntry.run(manager, event.id, round.id, original.id, already_entered.id)

    assert entry_registration(original.id) == "expected"

    assert {:error, :same_player} =
             ReplaceRoundEntry.run(manager, event.id, round.id, original.id, player.id)

    pre_open_player = create_player!()

    assert {:ok, pre_open_entry} =
             Competition.add_round_entry(event.id, round.id, pre_open_player.id, actor: admin)

    scoring_open = set_round_state!(round, :scoring_open)

    assert {:error, {:invalid_round_state, "scoring_open"}} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               scoring_open.id,
               pre_open_entry.id,
               create_player!().id
             )
  end

  test "replace_before_start rolls back when replacement creation fails" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    manager = create_staff_user!()
    assign_role!(admin, event, manager, :competition_manager)

    assert {:ok, original} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    install_round_entry_insert_failure_trigger!()

    assert {:error, _reason} =
             ReplaceRoundEntry.run(
               manager,
               event.id,
               round.id,
               original.id,
               create_player!().id
             )

    assert entry_registration(original.id) == "expected"
    assert round_entry_count(round.id) == 1

    drop_round_entry_insert_failure_trigger!()
  end

  test "concurrent registration transitions cannot produce impossible mixed states" do
    %{event: event, round: round, admin: admin, player: player} = setup_round!()
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :registration_staff)

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Competition.check_in_round_entry(entry, actor: staff)
        end)
      end

    results = Task.await_many(tasks, 30_000)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    status = entry_registration(entry.id)
    assert status == "checked_in"
  end

  test "assign_round_tee stores same-round snapshot on RoundEntry" do
    %{event: event, round: round, admin: admin, player: player, course: course} = setup_round!()
    holes = create_eighteen_holes!(event, admin, course)
    white = create_tee_set!(event, admin, course, "White")
    profile = create_profile!(event, admin, white, holes, "Men")

    {:ok, _} =
      ConfigureRoundLayout.run(
        admin,
        round.id,
        Enum.map(holes, & &1.id)
      )

    {:ok, [snapshot]} =
      SnapshotRoundTeeProfiles.run(admin, round.id, [
        profile.id
      ])

    assert {:ok, entry} =
             Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    assert {:ok, assigned} =
             AssignRoundTee.run(admin, event.id, round.id, entry.id, snapshot.id)

    assert assigned.round_tee_profile_snapshot_id == snapshot.id
  end

  test "RoundEntry tee assignment rejects cross-round snapshot" do
    setup_a = setup_round!()
    setup_b = setup_round!()

    holes = create_eighteen_holes!(setup_a.event, setup_a.admin, setup_a.course)
    white = create_tee_set!(setup_a.event, setup_a.admin, setup_a.course, "White")
    profile = create_profile!(setup_a.event, setup_a.admin, white, holes, "Men")

    {:ok, _} =
      ConfigureRoundLayout.run(
        setup_a.admin,
        setup_a.round.id,
        Enum.map(holes, & &1.id)
      )

    {:ok, [snapshot]} =
      SnapshotRoundTeeProfiles.run(
        setup_a.admin,
        setup_a.round.id,
        [profile.id]
      )

    assert {:ok, entry} =
             Competition.add_round_entry(
               setup_b.event.id,
               setup_b.round.id,
               setup_b.player.id,
               actor: setup_b.admin
             )

    assert {:error, :tee_snapshot_not_found} =
             AssignRoundTee.run(
               setup_b.admin,
               setup_b.event.id,
               setup_b.round.id,
               entry.id,
               snapshot.id
             )
  end

  defp create_eighteen_holes!(event, admin, course) do
    for n <- 1..18 do
      {:ok, hole} =
        GolfScoring.GolfCatalog.configure_course_hole(
          event.id,
          %{course_id: course.id, hole_number: n},
          actor: admin
        )

      hole
    end
  end

  defp create_tee_set!(event, admin, course, name) do
    {:ok, tee_set} =
      GolfScoring.GolfCatalog.configure_tee_set(
        event.id,
        %{course_id: course.id, name: name},
        actor: admin
      )

    tee_set
  end

  defp create_profile!(event, admin, tee_set, holes, label) do
    hole_ratings =
      Enum.map(holes, fn hole ->
        %{
          course_hole_id: hole.id,
          par: 4,
          stroke_index: hole.hole_number,
          distance_m: 300 + hole.hole_number
        }
      end)

    {:ok, profile} =
      GolfScoring.GolfCatalog.configure_tee_rating_profile(
        event.id,
        %{
          tee_set_id: tee_set.id,
          rating_label: label,
          course_rating: Decimal.new("72.0"),
          slope_rating: 113,
          total_par: 72,
          hole_ratings: hole_ratings
        },
        actor: admin
      )

    profile
  end

  defp setup_round! do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    player = create_player!()
    %{event: event, round: round, admin: admin, player: player, course: course}
  end

  defp create_player!(attrs \\ %{}) do
    defaults = %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    }

    Player
    |> Ash.Changeset.for_create(:create_internal, Map.merge(defaults, attrs))
    |> Ash.create!(authorize?: false)
  end

  defp round_entry_count(round_id) do
    [[count]] =
      Repo.query!("SELECT count(*) FROM round_entries WHERE round_id = $1::uuid", [
        Ecto.UUID.dump!(round_id)
      ]).rows

    count
  end

  defp current_starting_participant_count(group_id) do
    [[count]] =
      Repo.query!(
        StartingParticipant.count_starters_in_group_sql(),
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp entry_registration(round_entry_id) do
    [[status]] =
      Repo.query!("SELECT registration_status FROM round_entries WHERE id = $1::uuid", [
        Ecto.UUID.dump!(round_entry_id)
      ]).rows

    status
  end

  defp entry_participation(round_entry_id) do
    [[status]] =
      Repo.query!("SELECT participation_status FROM round_entries WHERE id = $1::uuid", [
        Ecto.UUID.dump!(round_entry_id)
      ]).rows

    status
  end

  defp registration_lifecycle_state(round_entry_id) do
    [[registration_status, participation_status, checked_in_at, checked_in_by_staff_user_id]] =
      Repo.query!(
        """
        SELECT registration_status, participation_status, checked_in_at,
               checked_in_by_staff_user_id::text
        FROM round_entries
        WHERE id = $1::uuid
        """,
        [Ecto.UUID.dump!(round_entry_id)]
      ).rows

    {registration_status, participation_status, checked_in_at, checked_in_by_staff_user_id}
  end

  defp force_participation!(round_entry_id, status) do
    Repo.query!(
      "UPDATE round_entries SET participation_status = $1 WHERE id = $2::uuid",
      [Atom.to_string(status), Ecto.UUID.dump!(round_entry_id)]
    )
  end

  defp install_round_entry_insert_failure_trigger! do
    Repo.query!("""
    CREATE FUNCTION gls16_reject_round_entry_insert() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'simulated GLS-16 round entry insert failure';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls16_reject_round_entry_insert
    BEFORE INSERT ON round_entries
    FOR EACH ROW EXECUTE FUNCTION gls16_reject_round_entry_insert()
    """)
  end

  defp drop_round_entry_insert_failure_trigger! do
    Repo.query!("DROP TRIGGER gls16_reject_round_entry_insert ON round_entries")
    Repo.query!("DROP FUNCTION gls16_reject_round_entry_insert()")
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_system_admin! do
    staff = create_staff_user!()

    Repo.query!("UPDATE staff_users SET system_admin = TRUE WHERE id = $1::uuid", [
      Ecto.UUID.dump!(staff.id)
    ])

    Repo.get!(GolfScoring.Accounts.StaffUser, staff.id)
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])

    Repo.get!(Round, round.id)
  end

  defp active_assignment_record(event, staff, role \\ :event_admin) do
    [[assignment_id]] =
      Repo.query!(
        "SELECT id::text FROM event_staff_assignments WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = $3 AND status = 'active'",
        [
          Ecto.UUID.dump!(event.id),
          Ecto.UUID.dump!(staff.id),
          Atom.to_string(role)
        ]
      ).rows

    EventStaffAssignment
    |> Ash.get!(assignment_id, authorize?: false)
  end

  defp create_event! do
    Event
    |> Ash.Changeset.for_create(:create_internal, %{})
    |> Ash.create!(authorize?: false)
  end

  defp create_event_admin!(event) do
    staff = create_staff_user!()

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id)]
    )

    staff
  end

  defp create_staff_user! do
    email =
      "#{Process.get(:gls16_email_prefix)}-#{System.unique_integer([:positive])}@example.com"

    GolfScoring.Accounts.StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin, suffix \\ "Main") do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "Test Course #{suffix}", location: "Here"},
        actor: admin
      )

    course
  end

  def observe_lifecycle_query(_event, _measurements, metadata, owner) do
    send(owner, {:round_entry_lifecycle_query, metadata})
  end
end
