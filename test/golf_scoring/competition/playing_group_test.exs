defmodule GolfScoring.Competition.PlayingGroupTest do
  use ExUnit.Case, async: false

  alias Ash.Changeset
  alias Ash.Resource.Info
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.EventStaffAssignment
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Event
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.PlayingGroupReadiness
  alias GolfScoring.Competition.RoundHole
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.CreateCompetitionSide
  alias GolfScoring.Competition.Services.ReplaceRoundEntry
  alias GolfScoring.Competition.Services.SetSideMembership
  alias GolfScoring.Competition.StartingParticipant
  alias GolfScoring.Competition.StartingPositionLabel
  alias GolfScoring.Repo

  @password "GLS-18 synthetic staff passphrase 2026"
  @state_check "playing_groups_state_must_be_valid"
  @position_check "playing_groups_starting_position_must_be_positive"
  @start_complete_check "playing_groups_start_assignment_must_be_complete"
  @start_slot_unique "playing_groups_unique_start_slot_index"
  @start_hole_fkey "playing_groups_starting_round_hole_id_fkey"
  @entry_group_fkey "round_entries_playing_group_same_round_fkey"

  setup do
    Process.put(:gls18_email_prefix, "gls18-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls18_email_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "PlayingGroup is registered without generic public CRUD" do
    assert PlayingGroup in Ash.Domain.Info.resources(Competition)
    refute Info.action(PlayingGroup, :create)
    refute Info.action(PlayingGroup, :update)
    refute Info.action(PlayingGroup, :destroy)
    assert Info.action(PlayingGroup, :create_playing_group)
    refute function_exported?(Competition, :assign_entry_to_group, 5)
  end

  test "implementation contains no ShotgunSlot concept" do
    root = Path.expand("../../..", __DIR__)
    lib_dir = Path.join(root, "lib")

    matches =
      lib_dir
      |> Path.join("**/*.{ex,exs,heex}")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        content = File.read!(path)
        Regex.match?(~r/shotgun_slot|ShotgunSlot/, content)
      end)

    assert matches == []
  end

  test "create_playing_group creates not_started group with no start assignment" do
    %{event: event, round: round, admin: admin} = setup_round!()

    assert {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    assert group.state == :not_started
    assert is_nil(group.starting_round_hole_id)
    assert is_nil(group.starting_position)
  end

  test "starting position labels derive from display hole number" do
    assert StartingPositionLabel.format(14, 1) == "14A"
    assert StartingPositionLabel.format(14, 2) == "14B"
    assert StartingPositionLabel.position_letter(26) == "Z"
    assert StartingPositionLabel.position_letter(27) == "AA"
  end

  test "setup capacity and starting readiness semantics" do
    assert PlayingGroupReadiness.setup_capacity_allowed?(0)
    assert PlayingGroupReadiness.setup_capacity_allowed?(1)
    refute PlayingGroupReadiness.starting_participant_count_valid?(0)
    refute PlayingGroupReadiness.starting_participant_count_valid?(1)
    assert PlayingGroupReadiness.starting_participant_count_valid?(2)
    assert PlayingGroupReadiness.starting_participant_count_valid?(4)
    refute PlayingGroupReadiness.starting_participant_count_valid?(5)
  end

  test "PostgreSQL rejects invalid state, position, half start assignment, duplicate slot" do
    %{round: round, admin: admin, hole_a: hole_a, hole_b: hole_b} = setup_round_with_holes!()

    {:ok, group} = Competition.create_playing_group(round.event_id, round.id, actor: admin)

    invalid_state =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE playing_groups SET state = 'finalized' WHERE id = $1::uuid",
          [Ecto.UUID.dump!(group.id)]
        )
      end

    assert invalid_state.postgres.code == :check_violation
    assert invalid_state.postgres.constraint == @state_check

    invalid_position =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE playing_groups
          SET starting_round_hole_id = $2::uuid, starting_position = 0
          WHERE id = $1::uuid
          """,
          [Ecto.UUID.dump!(group.id), Ecto.UUID.dump!(hole_a.id)]
        )
      end

    assert invalid_position.postgres.code == :check_violation
    assert invalid_position.postgres.constraint == @position_check

    half_assignment =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE playing_groups SET starting_round_hole_id = $2::uuid
          WHERE id = $1::uuid
          """,
          [Ecto.UUID.dump!(group.id), Ecto.UUID.dump!(hole_a.id)]
        )
      end

    assert half_assignment.postgres.code == :check_violation
    assert half_assignment.postgres.constraint == @start_complete_check

    set_start!(group, hole_a, 1)

    duplicate =
      assert_raise Postgrex.Error, fn ->
        insert_group_start!(round, hole_a, 1)
      end

    assert duplicate.postgres.code == :unique_violation
    assert duplicate.postgres.constraint == @start_slot_unique

    insert_group_start!(round, hole_a, 2)
    insert_group_start!(round, hole_b, 1)
  end

  test "cross-round starting hole and membership composite FK rejections" do
    setup_a = setup_round_with_holes!()
    setup_b = setup_round_with_holes!()

    {:ok, group_a} =
      Competition.create_playing_group(setup_a.event.id, setup_a.round.id, actor: setup_a.admin)

    cross_hole =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          UPDATE playing_groups
          SET starting_round_hole_id = $2::uuid, starting_position = 1
          WHERE id = $1::uuid
          """,
          [Ecto.UUID.dump!(group_a.id), Ecto.UUID.dump!(setup_b.hole_a.id)]
        )
      end

    assert cross_hole.postgres.code == :foreign_key_violation
    assert cross_hole.postgres.constraint == @start_hole_fkey

    {:ok, entry_b} =
      Competition.add_round_entry(
        setup_b.event.id,
        setup_b.round.id,
        create_player!().id,
        actor: setup_b.admin
      )

    cross_member =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE round_entries SET playing_group_id = $2::uuid WHERE id = $1::uuid",
          [Ecto.UUID.dump!(entry_b.id), Ecto.UUID.dump!(group_a.id)]
        )
      end

    assert cross_member.postgres.code == :foreign_key_violation
    assert cross_member.postgres.constraint == @entry_group_fkey
  end

  test "assign_entry_to_group rejects splitting current partnership across playing groups" do
    %{event: event, round: round, admin: admin} = setup_round!()

    assert {:ok, competition} =
             ConfigureRoundCompetition.run(admin, event.id, round.id, %{
               solo_sides_permitted: true
             })

    {:ok, side} =
      CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

    {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entry_one = add_entry!(event, round, admin)
    entry_two = add_entry!(event, round, admin)

    assert {:ok, _} =
             SetSideMembership.run(
               admin,
               event.id,
               round.id,
               competition.id,
               side.id,
               [entry_one.id, entry_two.id]
             )

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_one.id, group_a.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_two.id, group_a.id)

    assert {:error, :competition_side_split_across_groups} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_one.id, group_b.id)

    assert entry_playing_group_id(entry_one.id) == group_a.id
    assert entry_playing_group_id(entry_two.id) == group_a.id
  end

  test "assign_entry_to_group allows partnership regrouping after side reconfiguration" do
    %{event: event, round: round, admin: admin} = setup_round!()

    assert {:ok, competition} =
             ConfigureRoundCompetition.run(admin, event.id, round.id, %{
               solo_sides_permitted: true
             })

    {:ok, side} =
      CreateCompetitionSide.run(admin, event.id, round.id, competition.id, :partnership)

    {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entry_one = add_entry!(event, round, admin)
    entry_two = add_entry!(event, round, admin)
    entry_three = add_entry!(event, round, admin)

    assert {:ok, _} =
             SetSideMembership.run(
               admin,
               event.id,
               round.id,
               competition.id,
               side.id,
               [entry_one.id, entry_two.id]
             )

    for entry <- [entry_one, entry_two] do
      assert {:ok, _} =
               AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group_a.id)
    end

    assert {:ok, _} =
             SetSideMembership.run(
               admin,
               event.id,
               round.id,
               competition.id,
               side.id,
               [entry_two.id, entry_three.id]
             )

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_one.id, group_b.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_two.id, group_b.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry_three.id, group_b.id)

    assert {:ok, _} =
             SetSideMembership.run(
               admin,
               event.id,
               round.id,
               competition.id,
               side.id,
               [entry_one.id, entry_three.id]
             )

    assert entry_playing_group_id(entry_one.id) == group_b.id
    assert entry_playing_group_id(entry_three.id) == group_b.id
    assert entry_playing_group_id(entry_two.id) == group_b.id
  end

  test "assign_entry_to_group still assigns entries without competition side membership" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)

    assert {:ok, assigned} =
             AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

    assert assigned.playing_group_id == group.id
  end

  test "assign_entry_to_group enforces capacity, idempotency, and authorization" do
    %{event: event, round: round, admin: admin} = setup_round!()
    manager = create_manager!(event, admin)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entries = for _ <- 1..5, do: add_entry!(event, round, admin)

    for entry <- Enum.take(entries, 4) do
      assert {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)
    end

    assert {:error, :group_capacity_exceeded} =
             AssignEntryToGroup.run(admin, event.id, round.id, List.last(entries).id, group.id)

    assert current_starting_participant_count(group.id) == 4

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, hd(entries).id, group.id)

    assert current_starting_participant_count(group.id) == 4

    registration = create_staff_user!()
    assign_role!(admin, event, registration, :registration_staff)

    assert {:error, :forbidden} =
             AssignEntryToGroup.run(registration, event.id, round.id, hd(entries).id, group.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(manager, event.id, round.id, hd(entries).id, group.id)
  end

  test "assign_starting_hole is idempotent and validates ownership" do
    %{event: event, round: round, admin: admin, hole_a: hole} = setup_round_with_holes!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    assert {:ok, updated} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole.id, 1)

    assert updated.starting_round_hole_id == hole.id
    assert updated.starting_position == 1

    assert {:ok, same} =
             AssignPlayingGroupStart.run(admin, event.id, round.id, group.id, hole.id, 1)

    assert same.id == group.id

    other = setup_round_with_holes!()

    assert {:error, :round_hole_not_found} =
             AssignPlayingGroupStart.run(
               admin,
               event.id,
               round.id,
               group.id,
               other.hole_a.id,
               2
             )
  end

  test "round state guard rejects post-open configuration" do
    %{event: event, round: round, admin: admin, group: group, hole: hole} = setup_group_fixture!()
    entry = add_entry!(event, round, admin)
    {:ok, assigned} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

    for {state, state_str} <- [
          {:scoring_open, "scoring_open"},
          {:scoring_closed, "scoring_closed"},
          {:finalized, "finalized"},
          {:cancelled, "cancelled"}
        ] do
      set_round_state!(round, state)

      assert {:error, %Ash.Error.Invalid{}} =
               Competition.create_playing_group(event.id, round.id, actor: admin)

      assert {:error, {:invalid_round_state, ^state_str}} =
               AssignEntryToGroup.run(admin, event.id, round.id, assigned.id, group.id)

      assert {:error, {:invalid_round_state, ^state_str}} =
               AssignPlayingGroupStart.run(
                 admin,
                 event.id,
                 round.id,
                 group.id,
                 hole.id,
                 1
               )
    end
  end

  test "stale Event Admin cannot assign entries after revocation" do
    %{event: event, round: round, admin: admin, group: group} = setup_group_fixture!()
    entry = add_entry!(event, round, admin)
    stale = admin
    replacement = create_event_admin!(event)

    {:ok, _} =
      Accounts.revoke_event_staff_role(
        active_assignment_record(event, admin),
        actor: replacement
      )

    assert {:error, :forbidden} =
             AssignEntryToGroup.run(stale, event.id, round.id, entry.id, group.id)

    assert is_nil(entry_playing_group_id(entry.id))
  end

  test "lifecycle transitions enforce valid state paths and SubmitGroupHole progression" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    assert {:error, %Ash.Error.Invalid{}} =
             group
             |> Changeset.for_update(:mark_group_playing, %{})
             |> Ash.update(authorize?: false)

    Repo.query!("UPDATE playing_groups SET state = 'playing' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(group.id)
    ])

    playing = Ash.get!(PlayingGroup, group.id, authorize?: false)

    assert {:error, %Ash.Error.Invalid{}} =
             playing
             |> Changeset.for_update(:mark_group_finished, %{})
             |> Ash.update(authorize?: false)

    for action <- [:flag_group_attention, :clear_group_attention] do
      assert {:error, %Ash.Error.Invalid{}} =
               playing
               |> Changeset.for_update(action, %{})
               |> Ash.update(authorize?: false)
    end
  end

  test "terminal pre-start historical entries do not consume current starter capacity" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    entries =
      for _ <- 1..4 do
        entry = add_entry!(event, round, admin)

        {:ok, assigned} =
          AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

        assigned
      end

    assert current_starting_participant_count(group.id) == 4

    [victim | _rest] = entries

    assert {:ok, _} = Competition.mark_no_show(victim, actor: admin)

    assert current_starting_participant_count(group.id) == 3
    assert entry_playing_group_id(victim.id) == group.id

    replacement = add_entry!(event, round, admin)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, replacement.id, group.id)

    assert current_starting_participant_count(group.id) == 4
  end

  test "terminal registrations are rejected by assign_entry_to_group" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)
    {:ok, assigned} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

    assert {:ok, _} = Competition.mark_no_show(assigned, actor: admin)

    assert {:error, :not_current_starting_participant} =
             AssignEntryToGroup.run(admin, event.id, round.id, assigned.id, group.id)
  end

  test "withdrawn_before_start linked to group is not counted as current starter" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)
    {:ok, assigned} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

    assert {:ok, _} = Competition.withdraw_before_start(assigned, actor: admin)

    assert current_starting_participant_count(group.id) == 0
    assert entry_playing_group_id(assigned.id) == group.id

    assert {:error, :not_current_starting_participant} =
             AssignEntryToGroup.run(admin, event.id, round.id, assigned.id, group.id)
  end

  test "replaced_before_start linked to group is not counted as current starter" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)
    {:ok, assigned} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)
    replacement_player = create_player!()

    assert {:ok, %{original: marked}} =
             ReplaceRoundEntry.run(
               admin,
               event.id,
               round.id,
               assigned.id,
               replacement_player.id
             )

    assert current_starting_participant_count(group.id) == 1
    assert marked.playing_group_id == group.id

    assert {:error, :not_current_starting_participant} =
             AssignEntryToGroup.run(admin, event.id, round.id, marked.id, group.id)
  end

  test "active group role blocks cross-group move; historical roles do not" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group_a} = Competition.create_playing_group(event.id, round.id, actor: admin)
    {:ok, group_b} = Competition.create_playing_group(event.id, round.id, actor: admin)

    scorer_entry = add_entry!(event, round, admin)
    verifier_entry = add_entry!(event, round, admin)
    spare_entry = add_entry!(event, round, admin)

    {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, scorer_entry.id, group_a.id)
    {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, verifier_entry.id, group_a.id)
    {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, spare_entry.id, group_a.id)

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               admin,
               event.id,
               round.id,
               group_a.id,
               scorer_entry.id
             )

    assert {:ok, _} =
             Competition.assign_designated_verifier(
               admin,
               event.id,
               round.id,
               group_a.id,
               verifier_entry.id
             )

    assert {:error, :active_group_role_assignment_blocks_group_move} =
             AssignEntryToGroup.run(admin, event.id, round.id, scorer_entry.id, group_b.id)

    assert {:error, :active_group_role_assignment_blocks_group_move} =
             AssignEntryToGroup.run(admin, event.id, round.id, verifier_entry.id, group_b.id)

    assert {:ok, _} =
             Competition.handover_primary_scorer(
               admin,
               event.id,
               round.id,
               group_a.id,
               spare_entry.id
             )

    assert {:ok, _} =
             Competition.revoke_designated_verifier(
               admin,
               event.id,
               round.id,
               group_a.id,
               "release verifier"
             )

    assert {:ok, _} =
             Competition.revoke_primary_scorer(
               admin,
               event.id,
               round.id,
               group_a.id,
               "release scorer after handover"
             )

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, spare_entry.id, group_b.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, scorer_entry.id, group_b.id)

    assert {:ok, _} =
             AssignEntryToGroup.run(admin, event.id, round.id, verifier_entry.id, group_b.id)
  end

  test "same-group assign_entry_to_group remains idempotent for role holders" do
    %{event: event, round: round, admin: admin} = setup_round!()
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)
    entry = add_entry!(event, round, admin)
    {:ok, assigned} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

    assert {:ok, _} =
             Competition.assign_primary_scorer(
               admin,
               event.id,
               round.id,
               group.id,
               assigned.id
             )

    assert {:ok, same} =
             AssignEntryToGroup.run(admin, event.id, round.id, assigned.id, group.id)

    assert same.id == assigned.id
  end

  @tag :real_concurrency
  test "independent PostgreSQL backends enforce group capacity under concurrency" do
    fixture_key = System.unique_integer([:positive])
    prefix = "gls18-unboxed-#{fixture_key}"

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_capacity_fixture!(prefix)
      end)

    try do
      parent = self()

      task_one =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = pg_backend_pid!()
            send(parent, {:gls18_ready, :one, backend_pid})

            receive do
              :gls18_go ->
                AssignEntryToGroup.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.entry_one_id,
                  fixture.group_id
                )
            after
              10_000 -> flunk("GLS-18 concurrency worker one did not receive go")
            end
          end)
        end)

      task_two =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = pg_backend_pid!()
            send(parent, {:gls18_ready, :two, backend_pid})

            receive do
              :gls18_go ->
                AssignEntryToGroup.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.entry_two_id,
                  fixture.group_id
                )
            after
              10_000 -> flunk("GLS-18 concurrency worker two did not receive go")
            end
          end)
        end)

      assert_receive {:gls18_ready, :one, pid_one}, 10_000
      assert_receive {:gls18_ready, :two, pid_two}, 10_000
      assert pid_one != pid_two

      send(task_one.pid, :gls18_go)
      send(task_two.pid, :gls18_go)

      results = [Task.await(task_one, 30_000), Task.await(task_two, 30_000)]
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :group_capacity_exceeded}, &1)) == 1

      final_count =
        Sandbox.unboxed_run(Repo, fn ->
          current_starting_participant_count(fixture.group_id)
        end)

      assert final_count == 4
    after
      cleanup_committed_capacity_fixture!(fixture)
    end
  end

  @tag :real_concurrency
  test "replacement and fifth-entry assignment race preserve four current starters" do
    fixture_key = System.unique_integer([:positive])
    prefix = "gls18-replace-race-#{fixture_key}"

    fixture =
      Sandbox.unboxed_run(Repo, fn ->
        setup_committed_replacement_race_fixture!(prefix)
      end)

    try do
      parent = self()

      replace_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = pg_backend_pid!()
            send(parent, {:gls18_replace_ready, backend_pid})

            receive do
              :gls18_go ->
                ReplaceRoundEntry.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.replace_entry_id,
                  fixture.replacement_player_id
                )
            after
              10_000 -> flunk("replacement race worker did not receive go")
            end
          end)
        end)

      assign_task =
        Task.async(fn ->
          Sandbox.unboxed_run(Repo, fn ->
            backend_pid = pg_backend_pid!()
            send(parent, {:gls18_assign_ready, backend_pid})

            receive do
              :gls18_go ->
                AssignEntryToGroup.run(
                  fixture.admin,
                  fixture.event_id,
                  fixture.round_id,
                  fixture.fifth_entry_id,
                  fixture.group_id
                )
            after
              10_000 -> flunk("assignment race worker did not receive go")
            end
          end)
        end)

      assert_receive {:gls18_replace_ready, pid_replace}, 10_000
      assert_receive {:gls18_assign_ready, pid_assign}, 10_000
      assert pid_replace != pid_assign

      send(replace_task.pid, :gls18_go)
      send(assign_task.pid, :gls18_go)

      replace_result = Task.await(replace_task, 30_000)
      assign_result = Task.await(assign_task, 30_000)

      assert match?({:ok, _}, replace_result)
      assert match?({:error, :group_capacity_exceeded}, assign_result)

      Sandbox.unboxed_run(Repo, fn ->
        assert current_starting_participant_count(fixture.group_id) == 4

        assert entry_registration(fixture.replace_entry_id) == "replaced_before_start"
      end)
    after
      cleanup_committed_replacement_race_fixture!(fixture)
    end
  end

  defp setup_round! do
    event = create_event!()
    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    %{event: event, round: round, admin: admin}
  end

  defp setup_round_with_holes! do
    base = setup_round!()

    holes =
      for n <- 1..2 do
        RoundHole
        |> Changeset.for_create(:insert_layout_row, %{
          round_id: base.round.id,
          course_id: base.round.course_id,
          course_hole_id: create_course_hole!(base.event, base.admin, base.round.course_id, n).id,
          play_order: n,
          display_hole_number: if(n == 1, do: 14, else: 15)
        })
        |> Ash.create!(authorize?: false)
      end

    Map.merge(base, %{hole_a: hd(holes), hole_b: List.last(holes)})
  end

  defp setup_group_fixture! do
    base = setup_round_with_holes!()

    {:ok, group} =
      Competition.create_playing_group(base.event.id, base.round.id, actor: base.admin)

    Map.merge(base, %{group: group, hole: base.hole_a})
  end

  defp add_entry!(event, round, admin) do
    player = create_player!()

    {:ok, entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    entry
  end

  defp create_manager!(event, admin) do
    staff = create_staff_user!()
    assign_role!(admin, event, staff, :competition_manager)
    staff
  end

  defp current_starting_participant_count(group_id) do
    [[count]] =
      Repo.query!(
        StartingParticipant.count_starters_in_group_sql(),
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp entry_registration(entry_id) do
    [[status]] =
      Repo.query!("SELECT registration_status FROM round_entries WHERE id = $1::uuid", [
        Ecto.UUID.dump!(entry_id)
      ]).rows

    status
  end

  defp entry_playing_group_id(entry_id) do
    [[value]] =
      Repo.query!(
        "SELECT playing_group_id::text FROM round_entries WHERE id = $1::uuid",
        [Ecto.UUID.dump!(entry_id)]
      ).rows

    case value do
      nil -> nil
      id -> Ecto.UUID.cast!(id)
    end
  end

  defp set_start!(group, hole, position) do
    Repo.query!(
      """
      UPDATE playing_groups
      SET starting_round_hole_id = $2::uuid, starting_position = $3
      WHERE id = $1::uuid
      """,
      [Ecto.UUID.dump!(group.id), Ecto.UUID.dump!(hole.id), position]
    )
  end

  defp insert_group_start!(round, hole, position) do
    Repo.query!(
      """
      INSERT INTO playing_groups (round_id, state, starting_round_hole_id, starting_position)
      VALUES ($1::uuid, 'not_started', $2::uuid, $3)
      """,
      [Ecto.UUID.dump!(round.id), Ecto.UUID.dump!(hole.id), position]
    )
  end

  defp setup_committed_capacity_fixture!(email_prefix) do
    event = create_event!()
    admin = create_staff_user_for_prefix!(email_prefix)

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(admin.id)]
    )

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)

    course_hole = create_course_hole!(event, admin, course.id, 1)

    hole =
      RoundHole
      |> Changeset.for_create(:insert_layout_row, %{
        round_id: round.id,
        course_id: round.course_id,
        course_hole_id: course_hole.id,
        play_order: 1,
        display_hole_number: 14
      })
      |> Ash.create!(authorize?: false)

    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    existing_entries = for _ <- 1..3, do: add_entry!(event, round, admin)
    player_ids = Enum.map(existing_entries, & &1.player_id)

    for entry <- existing_entries do
      {:ok, _} = AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)
    end

    entry_one = add_entry!(event, round, admin)
    entry_two = add_entry!(event, round, admin)

    %{
      event_id: event.id,
      round_id: round.id,
      course_id: course.id,
      staff_id: admin.id,
      admin: admin,
      group_id: group.id,
      entry_one_id: entry_one.id,
      entry_two_id: entry_two.id,
      player_ids: [entry_one.player_id, entry_two.player_id | player_ids],
      hole_id: hole.id
    }
  end

  defp cleanup_committed_capacity_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      dumped_event = Ecto.UUID.dump!(fixture.event_id)
      dumped_round = Ecto.UUID.dump!(fixture.round_id)
      dumped_course = Ecto.UUID.dump!(fixture.course_id)
      dumped_staff = Ecto.UUID.dump!(fixture.staff_id)

      Repo.query!("DELETE FROM round_entries WHERE round_id = $1::uuid", [dumped_round])

      Repo.query!("DELETE FROM playing_groups WHERE round_id = $1::uuid", [dumped_round])

      Repo.query!("DELETE FROM round_holes WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [dumped_round])

      for player_id <- fixture.player_ids do
        Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(player_id)])
      end

      Repo.query!("DELETE FROM course_holes WHERE course_id = $1::uuid", [dumped_course])
      Repo.query!("DELETE FROM tee_sets WHERE course_id = $1::uuid", [dumped_course])
      Repo.query!("DELETE FROM courses WHERE id = $1::uuid", [dumped_course])

      Repo.query!(
        "DELETE FROM audit_events WHERE target_id = $1::uuid OR actor_staff_user_id = $2::uuid OR target_id = $2::uuid",
        [dumped_event, dumped_staff]
      )

      Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [dumped_staff])
    end)
  end

  defp setup_committed_replacement_race_fixture!(email_prefix) do
    event = create_event!()
    admin = create_staff_user_for_prefix!(email_prefix)

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(admin.id)]
    )

    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)
    {:ok, group} = Competition.create_playing_group(event.id, round.id, actor: admin)

    starter_entries =
      for _ <- 1..4 do
        entry = add_entry!(event, round, admin)

        {:ok, assigned} =
          AssignEntryToGroup.run(admin, event.id, round.id, entry.id, group.id)

        assigned
      end

    [replace_entry | _rest] = starter_entries
    fifth_entry = add_entry!(event, round, admin)
    replacement_player = create_player!()

    player_ids =
      [replacement_player.id, fifth_entry.player_id | Enum.map(starter_entries, & &1.player_id)]

    %{
      event_id: event.id,
      round_id: round.id,
      course_id: course.id,
      staff_id: admin.id,
      admin: admin,
      group_id: group.id,
      replace_entry_id: replace_entry.id,
      fifth_entry_id: fifth_entry.id,
      replacement_player_id: replacement_player.id,
      player_ids: player_ids
    }
  end

  defp cleanup_committed_replacement_race_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      dumped_event = Ecto.UUID.dump!(fixture.event_id)
      dumped_round = Ecto.UUID.dump!(fixture.round_id)
      dumped_course = Ecto.UUID.dump!(fixture.course_id)
      dumped_staff = Ecto.UUID.dump!(fixture.staff_id)

      Repo.query!("DELETE FROM round_entries WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM playing_groups WHERE round_id = $1::uuid", [dumped_round])
      Repo.query!("DELETE FROM rounds WHERE id = $1::uuid", [dumped_round])

      for player_id <- fixture.player_ids do
        Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(player_id)])
      end

      Repo.query!("DELETE FROM course_holes WHERE course_id = $1::uuid", [dumped_course])
      Repo.query!("DELETE FROM tee_sets WHERE course_id = $1::uuid", [dumped_course])
      Repo.query!("DELETE FROM courses WHERE id = $1::uuid", [dumped_course])
      Repo.query!("DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM events WHERE id = $1::uuid", [dumped_event])
      Repo.query!("DELETE FROM staff_users WHERE id = $1::uuid", [dumped_staff])
    end)
  end

  defp pg_backend_pid! do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp create_course_hole!(event, admin, course_id, n) do
    {:ok, hole} =
      GolfScoring.GolfCatalog.configure_course_hole(
        event.id,
        %{course_id: course_id, hole_number: n},
        actor: admin
      )

    hole
  end

  defp create_player! do
    GolfScoring.Competition.Player
    |> Changeset.for_create(:create_internal, %{
      first_name: "Pat",
      surname: "Golfer#{System.unique_integer([:positive])}"
    })
    |> Ash.create!(authorize?: false)
  end

  defp assign_role!(actor, event, staff, role) do
    {:ok, _} =
      Accounts.assign_event_staff_role(
        %{event_id: event.id, staff_user_id: staff.id, role: role},
        actor: actor
      )
  end

  defp create_event! do
    Event
    |> Changeset.for_create(:create_internal, %{})
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
      "#{Process.get(:gls18_email_prefix)}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_staff_user_for_prefix!(prefix) do
    email = "#{prefix}-#{System.unique_integer([:positive])}@example.com"

    Accounts.StaffUser
    |> Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin) do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "Test #{System.unique_integer([:positive])}", location: "ZA"},
        actor: admin
      )

    course
  end

  defp set_round_state!(round, state) do
    Repo.query!("UPDATE rounds SET state = $1 WHERE id = $2::uuid", [
      Atom.to_string(state),
      Ecto.UUID.dump!(round.id)
    ])
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
end
