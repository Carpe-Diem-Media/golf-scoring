defmodule GolfScoring.Competition.Services.FillGroupRoleVacancyTest do
  use ExUnit.Case, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit
  alias GolfScoring.Competition
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.Services.AcceptRoundEntryWithdrawal
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.HandoverGroupRole
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @reason "participant withdrew before starting the next hole"

  setup do
    Process.put(:gls34_prefix, "gls42a-t3-#{Ecto.UUID.generate()}")
    owner = Sandbox.start_owner!(Repo, shared: true)

    on_exit(fn ->
      Process.delete(:gls34_prefix)
      if Process.alive?(owner), do: Sandbox.stop_owner(owner)
    end)

    %{sandbox_owner: owner}
  end

  test "fills a scorer vacancy at the next revision and recovers verified play" do
    fixture = vacancy_fixture!(:primary_scorer, mystery?: true)
    subscribe(fixture.round.id)
    old_assignment = assignment_for_role!(fixture.group.id, :primary_scorer)
    old_row = assignment_row!(old_assignment)
    score_rows = score_rows(fixture.group.id)
    membership_rows = membership_rows(fixture.group.id)
    mystery_rows = mystery_rows(fixture.round.id)
    side_state = side_result_state(fixture.side.id)

    assert old_row.state == "revoked"

    assert {:ok, filled} =
             Competition.fill_group_role_vacancy(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 2).id,
               :primary_scorer
             )

    assert filled.assignment.assignment_version == 2
    assert filled.assignment.round_entry_id == Enum.at(fixture.entries, 2).id
    assert filled.withdrawal_ruling_id == fixture.withdrawal.ruling_id
    assert filled.attention_cleared?
    assert filled.remaining_attention_blockers == []
    assert group_state(fixture.group.id) == "playing"
    assert assignment_row!(old_assignment) == old_row
    assert active_role_holder(fixture.group.id, :primary_scorer) == Enum.at(fixture.entries, 2).id
    assert score_rows(fixture.group.id) == score_rows
    assert membership_rows(fixture.group.id) == membership_rows
    assert mystery_rows(fixture.round.id) == mystery_rows
    assert side_result_state(fixture.side.id) == side_state
    assert side_state == "review_required"

    context = fill_audit_context!(fixture.group.id)
    assert context["withdrawal_ruling_id"] == fixture.withdrawal.ruling_id
    assert context["vacancy"]["revoked_assignment_id"] == old_assignment
    assert context["replacement"]["assignment_id"] == filled.assignment.id
    assert context["replacement"]["assignment_version"] == 2
    assert context["verification"]["independent_verification_available"]
    assert context["group_attention"]["current_state"] == "playing"
    assert context["group_attention"]["remaining_blockers"] == []
    assert context["verification"]["result_mappings"] != []

    assert_receive {:group_role_vacancy_filled,
                    %{round_id: round_id, playing_group_id: group_id, role: :primary_scorer}}

    assert round_id == fixture.round.id
    assert group_id == fixture.group.id

    assert_receive {:playing_group_attention_cleared,
                    %{round_id: ^round_id, playing_group_id: ^group_id}}

    refute_receive {:playing_group_attention_required, _}, 50
  end

  test "fills a verifier vacancy without restoring its revoked assignment" do
    fixture = vacancy_fixture!(:designated_verifier)
    subscribe(fixture.round.id)
    old_assignment = assignment_for_role!(fixture.group.id, :designated_verifier)
    old_row = assignment_row!(old_assignment)

    assert {:ok, filled} =
             Competition.fill_group_role_vacancy(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 2).id,
               :designated_verifier
             )

    assert filled.assignment.state == :active
    assert filled.assignment.assignment_version == 2
    assert assignment_row!(old_assignment) == old_row

    assert active_role_holder(fixture.group.id, :designated_verifier) ==
             Enum.at(fixture.entries, 2).id

    assert group_state(fixture.group.id) == "playing"
    assert filled.attention_cleared?
    assert_receive {:group_role_vacancy_filled, %{role: :designated_verifier}}
    assert_receive {:playing_group_attention_cleared, _}
  end

  test "recovers when no current HoleResults need verifier mappings" do
    fixture = vacancy_fixture!(:primary_scorer)
    delete_current_hole_results!(fixture.round.id)

    assert Repo.query!(
             "SELECT id FROM hole_results WHERE round_id = $1::uuid",
             [Ecto.UUID.dump!(fixture.round.id)]
           ).rows == []

    assert {:ok, filled} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert filled.verification_mappings == []
    assert filled.attention_cleared?
    assert group_state(fixture.group.id) == "playing"
  end

  test "allows active Event Admin, Competition Manager, and Scoring Support actors" do
    for role <- ["competition_manager", "scoring_support"] do
      fixture = vacancy_fixture!(:primary_scorer)
      actor = staff_with_role!(fixture, role)

      assert {:ok, filled} =
               Competition.fill_group_role_vacancy(
                 actor,
                 fixture.event.id,
                 fixture.round.id,
                 fixture.group.id,
                 Enum.at(fixture.entries, 2).id,
                 :primary_scorer
               )

      assert filled.assignment.role == :primary_scorer
      assert audit_staff_role(fixture.group.id) == role
    end
  end

  test "rejects wrong-event, suspended, revoked, and ordinary actors without writes" do
    fixture = vacancy_fixture!(:primary_scorer)
    other = PaperRecoveryFixtures.setup_submit_fixture!(2)
    subscribe(fixture.round.id)
    before = assignment_count(fixture.group.id)

    assert {:error, :forbidden} =
             fill(fixture, other.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.admin.id)
    ])

    assert {:error, :forbidden} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.admin.id)
    ])

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE event_id = $1::uuid AND staff_user_id = $2::uuid AND role = 'event_admin'",
      [Ecto.UUID.dump!(fixture.event.id), Ecto.UUID.dump!(fixture.admin.id)]
    )

    assert {:error, :forbidden} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    ordinary = %StaffUser{id: Ecto.UUID.generate(), status: :active}

    assert {:error, :forbidden} =
             fill(fixture, ordinary, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert assignment_count(fixture.group.id) == before
    assert count_fill_audits(fixture.group.id) == 0
    assert group_state(fixture.group.id) == "attention_required"
    refute_receive {:group_role_vacancy_filled, _}, 50
    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "rejects a plain map that impersonates an active staff actor" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)
    before_assignments = assignment_count(fixture.group.id)
    forged_actor = %{id: fixture.admin.id, status: :active}

    assert {:error, :forbidden} =
             fill(fixture, forged_actor, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert assignment_count(fixture.group.id) == before_assignments
    assert count_fill_audits(fixture.group.id) == 0
    assert group_state(fixture.group.id) == "attention_required"
    refute_receive {:group_role_vacancy_filled, _}, 50
    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "rejects invocation in a caller transaction before issuing SQL" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)
    assignments_before = assignment_count(fixture.group.id)
    handler = {__MODULE__, make_ref()}

    assert {:ok, :rejected} =
             Repo.transaction(fn ->
               :ok =
                 :telemetry.attach(
                   handler,
                   [:golf_scoring, :repo, :query],
                   &__MODULE__.observe_query/4,
                   self()
                 )

               try do
                 assert {:error, :transaction_already_open} =
                          fill(
                            fixture,
                            fixture.admin,
                            Enum.at(fixture.entries, 2).id,
                            :primary_scorer
                          )

                 refute_receive {:fill_group_role_vacancy_query, _metadata}, 0
               after
                 :telemetry.detach(handler)
               end

               :rejected
             end)

    assert assignment_count(fixture.group.id) == assignments_before
    assert count_fill_audits(fixture.group.id) == 0
    assert group_state(fixture.group.id) == "attention_required"
    refute_receive {:group_role_vacancy_filled, _}, 50
    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "rejects an ineligible replacement participant" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)
    replacement = Enum.at(fixture.entries, 2)
    before = assignment_count(fixture.group.id)

    for state <- ["not_started", "completed", "withdrawn", "disqualified"] do
      Repo.query!("UPDATE round_entries SET participation_status = $2 WHERE id = $1::uuid", [
        Ecto.UUID.dump!(replacement.id),
        state
      ])

      assert {:error, _reason} = fill(fixture, fixture.admin, replacement.id, :primary_scorer)
    end

    Repo.query!("UPDATE round_entries SET participation_status = 'active' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(replacement.id)
    ])

    Repo.query!(
      "UPDATE round_entries SET registration_status = 'withdrawn_before_start' WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(replacement.id)
      ]
    )

    assert {:error, _reason} = fill(fixture, fixture.admin, replacement.id, :primary_scorer)
    assert assignment_count(fixture.group.id) == before
    assert count_fill_audits(fixture.group.id) == 0
    refute_receive {:group_role_vacancy_filled, _}, 50
    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "rejects cross-event, wrong-group, other-role, and already-filled assignments" do
    fixture = vacancy_fixture!(:primary_scorer, other_group?: true)
    other_event = PaperRecoveryFixtures.setup_submit_fixture!(2)
    subscribe(fixture.round.id)

    assert {:error, :round_entry_mismatch} =
             fill(fixture, fixture.admin, hd(other_event.entries).id, :primary_scorer)

    assert {:error, :round_entry_not_in_playing_group} =
             fill(fixture, fixture.admin, hd(fixture.other_group_entries).id, :primary_scorer)

    assert {:error, :round_entry_already_holds_other_active_role} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 1).id, :primary_scorer)

    assert {:error, :active_role_already_assigned} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :designated_verifier)

    assert assignment_count(fixture.group.id) == 2
    assert count_fill_audits(fixture.group.id) == 0
    refute_receive {:group_role_vacancy_filled, _}, 50
  end

  test "does not infer a vacancy from a revoked assignment without A2 and audit provenance" do
    fixture = playing_fixture!()
    assignment = active_assignment_for_role!(fixture.group.id, :primary_scorer)

    Repo.query!("UPDATE group_role_assignments SET state = 'revoked' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(assignment)
    ])

    Repo.query!("UPDATE playing_groups SET state = 'attention_required' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(fixture.group.id)
    ])

    subscribe(fixture.round.id)

    assert {:error, :withdrawal_provenance_required} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert assignment_row!(assignment).state == "revoked"
    assert assignment_count(fixture.group.id) == 2
    assert count_fill_audits(fixture.group.id) == 0
    refute_receive {:group_role_vacancy_filled, _}, 50
  end

  test "ordinary handover cannot fill a withdrawn vacancy" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)

    assert {:error, :no_active_assignment} =
             HandoverGroupRole.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 2).id,
               :primary_scorer
             )

    assert {:ok, filled} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert filled.assignment.assignment_version == 2
    assert count_fill_audits(fixture.group.id) == 1
  end

  test "commits a fill but retains attention when a role holder cannot verify results" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)
    verifier = Enum.at(fixture.entries, 1)

    Repo.query!(
      "UPDATE round_entries SET participation_status = 'disqualified' WHERE id = $1::uuid",
      [
        Ecto.UUID.dump!(verifier.id)
      ]
    )

    assert {:ok, filled} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert filled.assignment.state == :active
    refute filled.attention_cleared?
    assert :independent_verification_unavailable in filled.remaining_attention_blockers
    assert group_state(fixture.group.id) == "attention_required"
    assert active_role_holder(fixture.group.id, :primary_scorer) == Enum.at(fixture.entries, 2).id
    assert length(active_assignments(fixture.group.id)) == 2

    assert fill_audit_context!(fixture.group.id)["group_attention"]["current_state"] ==
             "attention_required"

    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "keeps preexisting or ambiguous attention blocked after filling the role" do
    fixture = vacancy_fixture!(:primary_scorer, preexisting_attention?: true)
    subscribe(fixture.round.id)

    assert {:ok, filled} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    refute filled.attention_cleared?
    assert :attention_provenance_unresolved in filled.remaining_attention_blockers
    assert group_state(fixture.group.id) == "attention_required"

    assert fill_audit_context!(fixture.group.id)["group_attention"]["remaining_blockers"] ==
             ["attention_provenance_unresolved"]

    refute_receive {:playing_group_attention_cleared, _}, 50

    ambiguous = vacancy_fixture!(:primary_scorer)

    assert {:ok, _audit} =
             Audit.record_staff_event(
               %{
                 actor_staff_user_id: ambiguous.admin.id,
                 action: "unresolved_group_attention_blocker",
                 target_type: "PlayingGroup",
                 target_id: ambiguous.group.id,
                 context: %{},
                 changes: %{}
               },
               authorize?: false
             )

    assert {:ok, ambiguous_fill} =
             fill(ambiguous, ambiguous.admin, Enum.at(ambiguous.entries, 2).id, :primary_scorer)

    refute ambiguous_fill.attention_cleared?
    assert :attention_provenance_unresolved in ambiguous_fill.remaining_attention_blockers
    assert group_state(ambiguous.group.id) == "attention_required"
  end

  test "fails closed when the withdrawal audit provenance is ambiguous" do
    fixture = vacancy_fixture!(:primary_scorer)
    duplicate_withdrawal_audit!(fixture.withdrawal.ruling_id)
    subscribe(fixture.round.id)
    before = assignment_count(fixture.group.id)

    assert {:error, :ambiguous_withdrawal_provenance} =
             fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)

    assert assignment_count(fixture.group.id) == before
    assert group_state(fixture.group.id) == "attention_required"
    assert count_fill_audits(fixture.group.id) == 0
    refute_receive {:group_role_vacancy_filled, _}, 50
  end

  test "private vacancy writes reject direct Ash calls without coordinator evidence" do
    fixture = vacancy_fixture!(:primary_scorer)
    subscribe(fixture.round.id)
    before = assignment_count(fixture.group.id)

    assert {:error, _reason} =
             GroupRoleAssignment
             |> Changeset.for_create(:create_for_vacancy_internal, %{
               round_id: fixture.round.id,
               playing_group_id: fixture.group.id,
               round_entry_id: Enum.at(fixture.entries, 2).id,
               role: :primary_scorer,
               state: :active,
               assignment_version: 2
             })
             |> Ash.create(authorize?: false)

    assert {:error, _reason} =
             PlayingGroup
             |> Ash.get!(fixture.group.id, authorize?: false)
             |> Changeset.for_update(:clear_group_attention_for_vacancy_internal, %{})
             |> Ash.update(authorize?: false)

    assert assignment_count(fixture.group.id) == before
    assert group_state(fixture.group.id) == "attention_required"
    assert count_fill_audits(fixture.group.id) == 0
    refute_receive {:group_role_vacancy_filled, _}, 50
    refute_receive {:playing_group_attention_cleared, _}, 50
  end

  test "assignment, attention, and audit write failures roll back the full vacancy fill" do
    for failure <- [:assignment, :attention, :audit] do
      fixture = vacancy_fixture!(:primary_scorer)
      subscribe(fixture.round.id)
      before = assignment_count(fixture.group.id)

      with_failure_trigger!(failure, fn ->
        assert {:error, _reason} =
                 fill(fixture, fixture.admin, Enum.at(fixture.entries, 2).id, :primary_scorer)
      end)

      assert assignment_count(fixture.group.id) == before
      assert group_state(fixture.group.id) == "attention_required"
      assert count_fill_audits(fixture.group.id) == 0
      refute_receive {:group_role_vacancy_filled, _}, 50
      refute_receive {:playing_group_attention_cleared, _}, 50
    end
  end

  test "scoring resumes against the new role revision, not a stale revision" do
    fixture = vacancy_fixture!(:primary_scorer)
    replacement = Enum.at(fixture.entries, 2)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(fixture.admin, fixture.event.id, replacement.player_id)

    assert {:error, :no_active_primary_scorer} =
             SubmitGroupHole.run(
               grant,
               fixture.event.id,
               fixture.round.id,
               next_submission_command(fixture, replacement.id, 2)
             )

    assert {:ok, filled} = fill(fixture, fixture.admin, replacement.id, :primary_scorer)
    assert filled.assignment.assignment_version == 2

    assert {:error, :stale_role_assignment} =
             SubmitGroupHole.run(
               grant,
               fixture.event.id,
               fixture.round.id,
               next_submission_command(fixture, replacement.id, 1)
             )

    assert {:ok, receipt} =
             SubmitGroupHole.run(
               grant,
               fixture.event.id,
               fixture.round.id,
               next_submission_command(fixture, replacement.id, 2)
             )

    assert receipt.role_assignment_version == 2
    assert group_state(fixture.group.id) == "playing"
  end

  test "competing fills serialize into exactly one new role revision" do
    fixture = committed_vacancy_fixture!(:primary_scorer)

    [first_replacement, second_replacement] = [
      Enum.at(fixture.entries, 2),
      Enum.at(fixture.entries, 3)
    ]

    subscribe(fixture.round.id)

    {first_pid, first_result, second_pid, second_result} =
      race_with_round_lock_barrier!(
        fixture,
        fn -> fill(fixture, fixture.admin, first_replacement.id, :primary_scorer) end,
        fn -> fill(fixture, fixture.admin, second_replacement.id, :primary_scorer) end
      )

    assert first_pid != second_pid
    assert {:ok, filled} = first_result
    assert {:error, {:invalid_playing_group_state, "playing"}} = second_result
    assert filled.assignment.round_entry_id == first_replacement.id
    assert filled.assignment.assignment_version == 2
    assert count_fill_audits(fixture.group.id) == 1
    assert active_role_holder(fixture.group.id, :primary_scorer) == first_replacement.id
    assert group_scoring_revision(fixture.group.id) == 1
    assert_receive {:group_role_vacancy_filled, %{playing_group_id: group_id}}
    assert group_id == fixture.group.id
    assert_receive {:playing_group_attention_cleared, %{playing_group_id: ^group_id}}
    refute_receive {:group_role_vacancy_filled, _}, 50

    assert Repo.query!(
             "SELECT assignment_version, state FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = 'primary_scorer' ORDER BY assignment_version",
             [Ecto.UUID.dump!(fixture.group.id)]
           ).rows == [[1, "revoked"], [2, "active"]]

    assert length(active_assignments(fixture.group.id)) == 2
  end

  test "submission that queues first rejects the vacancy before fill commits" do
    fixture = committed_vacancy_fixture!(:primary_scorer)
    replacement = Enum.at(fixture.entries, 2)
    subscribe(fixture.round.id)

    assert {:ok, %{grant: grant}} =
             Sandbox.unboxed_run(Repo, fn ->
               Accounts.issue_player_access(
                 fixture.admin,
                 fixture.event.id,
                 replacement.player_id
               )
             end)

    submissions_before = hole_submission_count(fixture.round.id)
    submit_audits_before = submission_audit_count(fixture.round.id)
    command = next_submission_command(fixture, replacement.id, 1)

    {submit_pid, submit_result, fill_pid, fill_result} =
      race_with_round_lock_barrier!(
        fixture,
        fn -> SubmitGroupHole.run(grant, fixture.event.id, fixture.round.id, command) end,
        fn -> fill(fixture, fixture.admin, replacement.id, :primary_scorer) end
      )

    assert submit_pid != fill_pid
    assert {:error, :no_active_primary_scorer} = submit_result
    assert {:ok, filled} = fill_result
    assert filled.assignment.assignment_version == 2
    assert group_state(fixture.group.id) == "playing"
    assert active_role_holder(fixture.group.id, :primary_scorer) == replacement.id
    assert group_scoring_revision(fixture.group.id) == 1
    assert hole_submission_count(fixture.round.id) == submissions_before
    assert submission_audit_count(fixture.round.id) == submit_audits_before
    assert count_fill_audits(fixture.group.id) == 1
    assert fill_audit_context!(fixture.group.id)["replacement"]["assignment_version"] == 2

    assert_receive {:group_role_vacancy_filled, %{round_id: round_id, playing_group_id: group_id}}

    assert round_id == fixture.round.id
    assert group_id == fixture.group.id
    assert_receive {:playing_group_attention_cleared, %{playing_group_id: ^group_id}}
    refute_receive {:group_hole_submitted, _}, 50
    refute_receive {:playing_group_attention_required, _}, 50
  end

  test "fill that queues first commits a revision used by the following submission" do
    fixture = committed_vacancy_fixture!(:primary_scorer)
    replacement = Enum.at(fixture.entries, 2)

    assert {:ok, %{grant: grant}} =
             Sandbox.unboxed_run(Repo, fn ->
               Accounts.issue_player_access(
                 fixture.admin,
                 fixture.event.id,
                 replacement.player_id
               )
             end)

    submissions_before = hole_submission_count(fixture.round.id)
    submit_audits_before = submission_audit_count(fixture.round.id)
    command = next_submission_command(fixture, replacement.id, 2)
    subscribe(fixture.round.id)

    {fill_pid, fill_result, submit_pid, submit_result} =
      race_with_round_lock_barrier!(
        fixture,
        fn -> fill(fixture, fixture.admin, replacement.id, :primary_scorer) end,
        fn -> SubmitGroupHole.run(grant, fixture.event.id, fixture.round.id, command) end
      )

    assert fill_pid != submit_pid
    assert {:ok, filled} = fill_result
    assert filled.assignment.assignment_version == 2

    assert {:ok, receipt} = submit_result
    assert receipt.role_assignment_version == 2
    assert group_state(fixture.group.id) == "playing"
    assert active_role_holder(fixture.group.id, :primary_scorer) == replacement.id
    assert group_scoring_revision(fixture.group.id) == 2
    assert hole_submission_count(fixture.round.id) == submissions_before + 1
    assert submission_audit_count(fixture.round.id) == submit_audits_before + 1
    assert count_fill_audits(fixture.group.id) == 1
    assert fill_audit_context!(fixture.group.id)["replacement"]["assignment_version"] == 2

    assert_receive {:group_role_vacancy_filled, %{round_id: round_id, playing_group_id: group_id}}

    assert round_id == fixture.round.id
    assert group_id == fixture.group.id
    assert_receive {:playing_group_attention_cleared, %{playing_group_id: ^group_id}}
    assert_receive {:group_hole_submitted, %{round_id: ^round_id, playing_group_id: ^group_id}}
    refute_receive {:playing_group_attention_required, _}, 50
  end

  defp race_with_round_lock_barrier!(fixture, first_operation, second_operation) do
    parent = self()
    token = make_ref()

    lock_holder = Task.async(fn -> hold_round_lock!(fixture.round.id, parent, token) end)

    first =
      Task.async(fn ->
        receive do
          {:t3_run_round_operation, ^token} ->
            Sandbox.unboxed_run(Repo, fn ->
              backend_pid = pg_backend_pid!()
              send(parent, {:t3_round_operation_started, token, :first, backend_pid})
              first_operation.()
            end)
        end
      end)

    second =
      Task.async(fn ->
        receive do
          {:t3_run_round_operation, ^token} ->
            Sandbox.unboxed_run(Repo, fn ->
              backend_pid = pg_backend_pid!()
              send(parent, {:t3_round_operation_started, token, :second, backend_pid})
              second_operation.()
            end)
        end
      end)

    try do
      assert_receive {:t3_round_lock_held, ^token, holder_pid}, 5_000
      send(first.pid, {:t3_run_round_operation, token})

      assert_receive {:t3_round_operation_started, ^token, :first, first_pid}, 10_000
      await_blocked_by!(first_pid, holder_pid, System.monotonic_time(:millisecond) + 10_000)

      send(second.pid, {:t3_run_round_operation, token})
      assert_receive {:t3_round_operation_started, ^token, :second, second_pid}, 10_000
      await_blocked_by!(second_pid, first_pid, System.monotonic_time(:millisecond) + 10_000)

      send(lock_holder.pid, {:t3_release_round_lock, token})
      assert {:ok, :released} = Task.await(lock_holder, 10_000)

      first_result = Task.await(first, 25_000)
      second_result = Task.await(second, 25_000)
      {first_pid, first_result, second_pid, second_result}
    after
      send(lock_holder.pid, {:t3_release_round_lock, token})
      Task.shutdown(first, :brutal_kill)
      Task.shutdown(second, :brutal_kill)
      Task.shutdown(lock_holder, :brutal_kill)
    end
  end

  defp hold_round_lock!(round_id, parent, token) do
    Sandbox.unboxed_run(Repo, fn ->
      Repo.transaction(fn ->
        backend_pid = pg_backend_pid!()

        Repo.query!(
          "SELECT id FROM rounds WHERE id = $1::uuid FOR UPDATE",
          [Ecto.UUID.dump!(round_id)]
        )

        send(parent, {:t3_round_lock_held, token, backend_pid})
        wait_for_round_lock_release!(token)
      end)
    end)
  end

  defp wait_for_round_lock_release!(token) do
    receive do
      {:t3_release_round_lock, ^token} -> :released
    after
      20_000 -> raise "timed out holding the T3 Round lock barrier"
    end
  end

  defp vacancy_fixture!(role, opts \\ []) do
    fixture = PaperRecoveryFixtures.setup_submit_fixture!(4)
    PaperRecoveryFixtures.set_round_state!(fixture.round, :draft)

    other_group_data =
      if Keyword.get(opts, :other_group?, false) do
        {:ok, group} =
          Competition.create_playing_group(fixture.event.id, fixture.round.id,
            actor: fixture.admin
          )

        assert {:ok, _} =
                 AssignPlayingGroupStart.run(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   group.id,
                   fixture.start_hole.id,
                   2
                 )

        entries = PaperRecoveryFixtures.add_player_entries_to_group!(fixture, group, 2)
        %{other_group: group, other_group_entries: entries}
      end

    assert {:ok, _verifier} =
             PaperRecoveryFixtures.assign_designated_verifier_for_fixture(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 1).id
             )

    fixture =
      if Keyword.get(opts, :mystery?, false) do
        mystery =
          PaperRecoveryFixtures.configure_mystery_for_groups!(
            fixture,
            [{fixture.group, Enum.take(fixture.entries, 2)}]
          )

        Map.put(fixture, :mystery, mystery)
      else
        {:ok, side} =
          Competition.create_competition_side(
            fixture.admin,
            fixture.event.id,
            fixture.round.id,
            fixture.competition.id,
            :partnership
          )

        assert {:ok, _} =
                 PaperRecoveryFixtures.set_side_membership_for_fixture(
                   fixture.admin,
                   fixture.event.id,
                   fixture.round.id,
                   fixture.competition.id,
                   side.id,
                   fixture.entries |> Enum.take(2) |> Enum.map(& &1.id)
                 )

        Map.put(fixture, :side, side)
      end

    fixture = Map.merge(fixture, Map.new(other_group_data || %{}))
    PaperRecoveryFixtures.set_round_state!(fixture.round, :scoring_open)

    assert {:ok, _submission} =
             SubmitGroupHole.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               first_submission_command(fixture)
             )

    fixture =
      if Keyword.get(opts, :mystery?, false) do
        [[side_id]] =
          Repo.query!(
            "SELECT cs.id::text FROM competition_sides cs JOIN competition_side_memberships csm ON csm.competition_side_id = cs.id WHERE cs.round_id = $1::uuid AND csm.round_entry_id = $2::uuid ORDER BY cs.id LIMIT 1",
            [Ecto.UUID.dump!(fixture.round.id), Ecto.UUID.dump!(hd(fixture.entries).id)]
          ).rows

        Map.put(fixture, :side, %{id: Ecto.UUID.cast!(side_id)})
      else
        fixture
      end

    if Keyword.get(opts, :preexisting_attention?, false) do
      Repo.query!("UPDATE playing_groups SET state = 'attention_required' WHERE id = $1::uuid", [
        Ecto.UUID.dump!(fixture.group.id)
      ])
    end

    target = Enum.at(fixture.entries, if(role == :primary_scorer, do: 0, else: 1))

    assert {:ok, withdrawal} =
             AcceptRoundEntryWithdrawal.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               target.id,
               withdrawal_attrs(fixture)
             )

    Map.merge(fixture, %{withdrawal: withdrawal, withdrawn_entry: target, vacancy_role: role})
  end

  defp playing_fixture! do
    fixture = PaperRecoveryFixtures.setup_submit_fixture!(4)
    PaperRecoveryFixtures.set_round_state!(fixture.round, :draft)

    assert {:ok, _verifier} =
             PaperRecoveryFixtures.assign_designated_verifier_for_fixture(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               fixture.group.id,
               Enum.at(fixture.entries, 1).id
             )

    PaperRecoveryFixtures.set_round_state!(fixture.round, :scoring_open)

    assert {:ok, _submission} =
             SubmitGroupHole.run(
               fixture.admin,
               fixture.event.id,
               fixture.round.id,
               first_submission_command(fixture)
             )

    fixture
  end

  defp committed_vacancy_fixture!(role) do
    fixture = Sandbox.unboxed_run(Repo, fn -> vacancy_fixture!(role) end)
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)
    fixture
  end

  defp cleanup_committed_fixture!(fixture) do
    Sandbox.unboxed_run(Repo, fn ->
      assert {:ok, :cleaned} =
               Repo.transaction(fn ->
                 Repo.query!(
                   "DROP TRIGGER round_entry_participation_rulings_reject_mutation ON public.round_entry_participation_rulings"
                 )

                 Repo.query!(
                   "ALTER TABLE public.score_revisions DISABLE TRIGGER score_revisions_immutable_rows"
                 )

                 try do
                   player_ids =
                     Repo.query!(
                       "SELECT player_id::text FROM round_entries WHERE round_id = $1::uuid",
                       [
                         Ecto.UUID.dump!(fixture.round.id)
                       ]
                     ).rows
                     |> Enum.map(fn [id] -> Ecto.UUID.cast!(id) end)

                   statements = [
                     {"DELETE FROM audit_events WHERE context->>'round_id' = $1",
                      [fixture.round.id]},
                     {"DELETE FROM round_entry_participation_rulings WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_verifications WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_revisions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM score_queries WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM hole_results WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM hole_submissions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM scorecards WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM competition_sides WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM group_role_assignments WHERE playing_group_id IN (SELECT id FROM playing_groups WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_entries WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM playing_groups WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_competitions WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM round_holes WHERE round_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM rounds WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.round.id)]},
                     {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.tee_profile.id)]},
                     {"DELETE FROM tee_sets WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.tee_set.id)]},
                     {"DELETE FROM course_holes WHERE course_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.course.id)]},
                     {"DELETE FROM courses WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.course.id)]},
                     {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM player_access_grants WHERE event_id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM events WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.event.id)]},
                     {"DELETE FROM staff_users WHERE id = $1::uuid",
                      [Ecto.UUID.dump!(fixture.admin.id)]}
                   ]

                   Enum.each(statements, fn {sql, args} -> Repo.query!(sql, args) end)

                   Enum.each(
                     player_ids,
                     &Repo.query!("DELETE FROM players WHERE id = $1::uuid", [Ecto.UUID.dump!(&1)])
                   )
                 after
                   Repo.query!(
                     "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_rows"
                   )

                   Repo.query!(
                     "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_truncate"
                   )

                   Repo.query!("""
                   CREATE TRIGGER round_entry_participation_rulings_reject_mutation
                   BEFORE UPDATE OR DELETE ON public.round_entry_participation_rulings
                   FOR EACH ROW EXECUTE FUNCTION public.reject_round_entry_participation_ruling_mutation()
                   """)

                   Repo.query!(
                     "ALTER TABLE public.round_entry_participation_rulings ENABLE ALWAYS TRIGGER round_entry_participation_rulings_reject_mutation"
                   )

                   Repo.query!(
                     "ALTER TABLE public.round_entry_participation_rulings ENABLE ALWAYS TRIGGER round_entry_participation_rulings_reject_truncate"
                   )
                 end

                 assert [["A"], ["A"]] ==
                          Repo.query!("""
                          SELECT tgenabled::text
                          FROM pg_trigger
                          WHERE tgrelid = 'public.round_entry_participation_rulings'::regclass
                            AND tgname IN (
                              'round_entry_participation_rulings_reject_mutation',
                              'round_entry_participation_rulings_reject_truncate'
                            )
                          ORDER BY tgname
                          """).rows

                 assert [["A"], ["A"]] ==
                          Repo.query!("""
                          SELECT tgenabled::text
                          FROM pg_trigger
                          WHERE tgrelid = 'public.score_revisions'::regclass
                            AND tgname IN (
                              'score_revisions_immutable_rows',
                              'score_revisions_immutable_truncate'
                            )
                          ORDER BY tgname
                          """).rows

                 :cleaned
               end)
    end)
  end

  defp first_submission_command(fixture) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: hd(fixture.route).id,
      expected_group_score_revision: 0,
      results:
        Enum.map(fixture.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }
  end

  defp next_submission_command(fixture, _replacement_entry_id, role_version) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: fixture.group.id,
      round_hole_id: Enum.at(fixture.route, 1).id,
      expected_group_score_revision: 1,
      role_assignment_version: role_version,
      results:
        fixture.entries
        |> Enum.reject(&(&1.id == fixture.withdrawn_entry.id))
        |> Enum.map(fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
        end),
      captured_at: DateTime.utc_now(:microsecond)
    }
  end

  defp withdrawal_attrs(fixture) do
    attested_at = DateTime.utc_now(:microsecond)

    %{
      reason: @reason,
      attestation: %{
        observed_at: DateTime.add(attested_at, -1, :second),
        method: "direct_visual",
        observation_location: "starting area for the next hole",
        round_id: fixture.round.id,
        playing_group_id: fixture.group.id,
        effective_round_hole_id: Enum.at(fixture.route, 1).id,
        effective_play_index: 1,
        confirms_unplayed?: true
      }
    }
  end

  defp fill(fixture, actor, replacement_id, role) do
    Competition.fill_group_role_vacancy(
      actor,
      fixture.event.id,
      fixture.round.id,
      fixture.group.id,
      replacement_id,
      role
    )
  end

  defp subscribe(round_id), do: Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{round_id}")

  defp staff_with_role!(fixture, role) do
    password = "gls42-t3-test-password"

    staff =
      StaffUser
      |> Changeset.for_create(:provision_staff_user, %{
        email: "gls42-t3-#{System.unique_integer([:positive])}@example.com",
        password: password,
        password_confirmation: password
      })
      |> Ash.create!(authorize?: false)

    assert {:ok, _assignment} =
             Accounts.assign_event_staff_role(
               %{event_id: fixture.event.id, staff_user_id: staff.id, role: role},
               actor: fixture.admin
             )

    staff
  end

  defp assignment_for_role!(group_id, role) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = $2 AND state = 'revoked' ORDER BY assignment_version DESC LIMIT 1",
        [Ecto.UUID.dump!(group_id), Atom.to_string(role)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp active_assignment_for_role!(group_id, role) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = $2 AND state = 'active' ORDER BY assignment_version DESC LIMIT 1",
        [Ecto.UUID.dump!(group_id), Atom.to_string(role)]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp assignment_row!(id) do
    [[row_id, state, version, entry_id]] =
      Repo.query!(
        "SELECT id::text, state, assignment_version, round_entry_id::text FROM group_role_assignments WHERE id = $1::uuid",
        [Ecto.UUID.dump!(id)]
      ).rows

    %{
      id: Ecto.UUID.cast!(row_id),
      state: state,
      assignment_version: version,
      round_entry_id: Ecto.UUID.cast!(entry_id)
    }
  end

  defp active_role_holder(group_id, role) do
    case Repo.query!(
           "SELECT round_entry_id::text FROM group_role_assignments WHERE playing_group_id = $1::uuid AND role = $2 AND state = 'active'",
           [Ecto.UUID.dump!(group_id), Atom.to_string(role)]
         ).rows do
      [[id]] -> Ecto.UUID.cast!(id)
      [] -> nil
    end
  end

  defp active_assignments(group_id) do
    Repo.query!(
      "SELECT id::text, role, round_entry_id::text, assignment_version FROM group_role_assignments WHERE playing_group_id = $1::uuid AND state = 'active' ORDER BY role",
      [Ecto.UUID.dump!(group_id)]
    ).rows
  end

  defp assignment_count(group_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM group_role_assignments WHERE playing_group_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp group_state(group_id) do
    [[state]] =
      Repo.query!("SELECT state FROM playing_groups WHERE id = $1::uuid", [
        Ecto.UUID.dump!(group_id)
      ]).rows

    state
  end

  defp delete_current_hole_results!(round_id) do
    assert {:ok, :deleted} =
             Repo.transaction(fn ->
               Repo.query!("DELETE FROM score_verifications WHERE round_id = $1::uuid", [
                 Ecto.UUID.dump!(round_id)
               ])

               Repo.query!(
                 "ALTER TABLE public.score_revisions DISABLE TRIGGER score_revisions_immutable_rows"
               )

               try do
                 Repo.query!("DELETE FROM score_revisions WHERE round_id = $1::uuid", [
                   Ecto.UUID.dump!(round_id)
                 ])
               after
                 Repo.query!(
                   "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_rows"
                 )

                 Repo.query!(
                   "ALTER TABLE public.score_revisions ENABLE ALWAYS TRIGGER score_revisions_immutable_truncate"
                 )
               end

               Repo.query!("DELETE FROM hole_results WHERE round_id = $1::uuid", [
                 Ecto.UUID.dump!(round_id)
               ])

               assert [["A"], ["A"]] ==
                        Repo.query!("""
                        SELECT tgenabled::text
                        FROM pg_trigger
                        WHERE tgrelid = 'public.score_revisions'::regclass
                          AND tgname IN (
                            'score_revisions_immutable_rows',
                            'score_revisions_immutable_truncate'
                          )
                        ORDER BY tgname
                        """).rows

               :deleted
             end)
  end

  defp group_scoring_revision(group_id) do
    [[revision]] =
      Repo.query!("SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid", [
        Ecto.UUID.dump!(group_id)
      ]).rows

    revision
  end

  defp hole_submission_count(round_id) do
    [[count]] =
      Repo.query!("SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid", [
        Ecto.UUID.dump!(round_id)
      ]).rows

    count
  end

  defp submission_audit_count(round_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM audit_events WHERE action = 'submit_group_hole' AND context->>'round_id' = $1",
        [round_id]
      ).rows

    count
  end

  defp await_blocked_by!(waiting_pid, blocking_pid, deadline) do
    [[blocked?]] =
      Repo.query!(
        "SELECT $1::integer = ANY(pg_blocking_pids($2::integer))",
        [blocking_pid, waiting_pid]
      ).rows

    cond do
      blocked? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected PostgreSQL lock blocking between #{waiting_pid} and #{blocking_pid}")

      true ->
        Process.sleep(5)
        await_blocked_by!(waiting_pid, blocking_pid, deadline)
    end
  end

  defp pg_backend_pid! do
    Repo.query!("SELECT pg_backend_pid()").rows |> hd() |> hd()
  end

  defp score_rows(group_id) do
    Repo.query!(
      "SELECT hr.id::text, hr.round_hole_id::text, sc.round_entry_id::text, hr.revision FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id JOIN round_entries re ON re.id = sc.round_entry_id WHERE re.playing_group_id = $1::uuid ORDER BY sc.round_entry_id, hr.round_hole_id",
      [Ecto.UUID.dump!(group_id)]
    ).rows
  end

  defp membership_rows(group_id) do
    Repo.query!(
      "SELECT csm.id::text, csm.competition_side_id::text, csm.round_entry_id::text FROM competition_side_memberships csm JOIN competition_sides cs ON cs.id = csm.competition_side_id WHERE cs.round_id = (SELECT round_id FROM playing_groups WHERE id = $1::uuid) ORDER BY csm.competition_side_id, csm.round_entry_id",
      [Ecto.UUID.dump!(group_id)]
    ).rows
  end

  defp side_result_state(side_id) do
    case Repo.query!(
           "SELECT state FROM competition_side_results WHERE competition_side_id = $1::uuid",
           [Ecto.UUID.dump!(side_id)]
         ).rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp mystery_rows(round_id) do
    rules =
      Repo.query!(
        "SELECT id::text, round_hole_id::text, rule FROM mystery_hole_rules WHERE round_id = $1::uuid ORDER BY id",
        [Ecto.UUID.dump!(round_id)]
      ).rows

    reveals =
      Repo.query!(
        "SELECT id::text, mystery_hole_rule_id::text FROM mystery_reveals WHERE mystery_hole_rule_id IN (SELECT id FROM mystery_hole_rules WHERE round_id = $1::uuid) ORDER BY id",
        [Ecto.UUID.dump!(round_id)]
      ).rows

    {rules, reveals}
  end

  defp fill_audit_context!(group_id) do
    [[context]] =
      Repo.query!(
        "SELECT context FROM audit_events WHERE action = 'fill_group_role_vacancy' AND target_type = 'PlayingGroup' AND target_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    context
  end

  defp audit_staff_role(group_id) do
    fill_audit_context!(group_id)["authorized_by_role"]
  end

  defp count_fill_audits(group_id) do
    [[count]] =
      Repo.query!(
        "SELECT count(*)::int FROM audit_events WHERE action = 'fill_group_role_vacancy' AND target_type = 'PlayingGroup' AND target_id = $1::uuid",
        [Ecto.UUID.dump!(group_id)]
      ).rows

    count
  end

  defp duplicate_withdrawal_audit!(ruling_id) do
    Repo.query!(
      "INSERT INTO audit_events (action, target_type, target_id, context, changes, reason, actor_staff_user_id) SELECT action, target_type, target_id, context, changes, reason, actor_staff_user_id FROM audit_events WHERE action = 'accept_round_entry_withdrawal' AND target_id = $1::uuid",
      [Ecto.UUID.dump!(ruling_id)]
    )
  end

  defp with_failure_trigger!(failure, fun) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    function = "gls42a_t3_failure_fn_#{suffix}"
    trigger = "gls42a_t3_failure_#{suffix}"

    {table, event, condition} =
      case failure do
        :assignment ->
          {"group_role_assignments", "INSERT",
           "NEW.state = 'active' AND NEW.assignment_version > 1"}

        :attention ->
          {"playing_groups", "UPDATE",
           "OLD.state = 'attention_required' AND NEW.state = 'playing'"}

        :audit ->
          {"audit_events", "INSERT", "NEW.action = 'fill_group_role_vacancy'"}
      end

    Repo.query!("""
    CREATE FUNCTION #{function}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN
        RAISE EXCEPTION 'injected vacancy write failure';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!(
      "CREATE TRIGGER #{trigger} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{function}()"
    )

    try do
      fun.()
    after
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger} ON #{table}")
      Repo.query!("DROP FUNCTION IF EXISTS #{function}()")
    end
  end

  def observe_query(_event, _measurements, metadata, owner) do
    send(owner, {:fill_group_role_vacancy_query, metadata})
  end
end
