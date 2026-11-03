defmodule GolfScoring.Scoring.Services.PaperRecoveryTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @password "GLS-79 synthetic staff passphrase 2026"

  setup do
    Process.put(:gls34_prefix, "gls79-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "active Event Admin can use paper recovery and the receipt records the provenance" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)

    assert function_exported?(SubmitGroupHole, :run_paper_recovery, 5)

    assert {:ok, receipt} = recover(setup.admin, setup, command, "  scorecard recovered  ")

    assert receipt.source == "paper_recovery"
    assert receipt.recovery_reason == "scorecard recovered"
    assert receipt.submitted_by_staff_user_id == setup.admin.id
    assert result_count(setup.round.id) == length(setup.entries)

    audit = audit_for_receipt!(receipt.id)
    assert audit.reason == "scorecard recovered"
    assert audit.context["source"] == "paper_recovery"
  end

  test "active Competition Manager can recover a hole" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    manager = create_staff_user!()
    assign_event_role!(setup, manager, :competition_manager)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)

    assert {:ok, receipt} = recover(manager, setup, command, "paper scorecard")
    assert receipt.source == "paper_recovery"
    assert receipt.submitted_by_staff_user_id == manager.id
  end

  test "recovery rejects scoring support, registration staff, suspended staff, players, and unassigned SYSTEM_ADMIN" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)

    for role <- [:scoring_support, :registration_staff] do
      staff = create_staff_user!()
      assign_event_role!(setup, staff, role)
      assert {:error, :forbidden} = recover(staff, setup, command, "paper scorecard")
    end

    suspended = create_staff_user!()
    assign_event_role!(setup, suspended, :event_admin)

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(suspended.id)
    ])

    assert {:error, :forbidden} = recover(suspended, setup, command, "paper scorecard")

    system_admin = create_staff_user!()

    Repo.query!("UPDATE staff_users SET system_admin = TRUE WHERE id = $1::uuid", [
      Ecto.UUID.dump!(system_admin.id)
    ])

    assert {:error, :forbidden} = recover(system_admin, setup, command, "paper scorecard")

    [scorer | _] = setup.entries

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    assert {:error, :forbidden} = recover(grant, setup, command, "paper scorecard")
    assert submission_count(setup.round.id) == 0
    assert result_count(setup.round.id) == 0
  end

  test "missing and blank recovery reasons fail without writes" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    before = snapshot(setup)

    for reason <- [nil, "", " \t\n "] do
      assert {:error, :recovery_reason_required} = recover(setup.admin, setup, command, reason)
    end

    assert snapshot(setup) == before
    refute_receive {:group_hole_submitted, _}
  end

  test "normal run ignores client-supplied paper provenance" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)

    command =
      command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
      |> Map.put(:source, "paper_recovery")
      |> Map.put(:recovery_reason, "client supplied")

    assert {:ok, receipt} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert receipt.source == "normal"
    assert is_nil(receipt.recovery_reason)

    audit = audit_for_receipt!(receipt.id)
    assert is_nil(audit.reason)
    refute Map.has_key?(audit.context, :source)
    refute Map.has_key?(audit.context, "source")
  end

  test "normal submission keeps the accepted pre-GLS79 fingerprint contract" do
    vector = legacy_vector()

    assert legacy_fingerprint(vector) ==
             "6fade5a3d1b3e790c3f6eec4124ef45fa66a217f29c43e4a026d0f82c59b048f"

    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    captured_at = ~U[2026-11-03 12:00:00.000000Z]

    command =
      command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
      |> Map.put(:captured_at, captured_at)

    assert {:ok, receipt} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    expected =
      legacy_fingerprint(%{
        group_id: setup.group.id,
        hole_id: setup.start_hole.id,
        revision: 0,
        captured_at: captured_at,
        actor_id: setup.admin.id,
        results: command.results
      })

    assert Base.encode16(receipt.payload_fingerprint, case: :lower) == expected
    assert receipt.source == "normal"
  end

  test "database constraints reject invalid source and source-reason combinations" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)

    assert {:ok, receipt} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'unknown' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_allowed"
    )

    assert_constraint_violation!(
      "UPDATE hole_submissions SET recovery_reason = 'unexpected' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_reason"
    )

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'paper_recovery', recovery_reason = '  ' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_reason"
    )

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'paper_recovery', recovery_reason = chr(9) || chr(10) WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_reason"
    )

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'paper_recovery', recovery_reason = chr(160) WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_reason"
    )

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'paper_recovery', recovery_reason = chr(9) || 'paper' || chr(10) WHERE id = $1::uuid",
      [Ecto.UUID.dump!(receipt.id)],
      "hole_submissions_source_reason"
    )

    [scorer | _] = setup.entries

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, scorer.player_id)

    assignment =
      Repo.query!(
        "SELECT id::text, assignment_version FROM group_role_assignments WHERE playing_group_id = $1::uuid AND round_entry_id = $2::uuid AND role = 'primary_scorer' AND state = 'active'",
        [Ecto.UUID.dump!(setup.group.id), Ecto.UUID.dump!(scorer.id)]
      ).rows

    [[assignment_id, version]] = assignment

    player_command =
      command(setup, setup.group.id, setup.entries, Enum.at(setup.route, 1).id, 1)
      |> Map.put(:role_assignment_version, version)

    assert {:ok, player_receipt} =
             SubmitGroupHole.run(grant, setup.event.id, setup.round.id, player_command)

    assert_constraint_violation!(
      "UPDATE hole_submissions SET source = 'paper_recovery', recovery_reason = 'paper' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(player_receipt.id)],
      "hole_submissions_paper_recovery_staff_only"
    )

    assert is_binary(assignment_id)
  end

  test "paper retry returns the original receipt without extra writes or broadcasts" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, first} = recover(setup.admin, setup, command, "paper scorecard")
    assert_receive {:group_hole_submitted, _}
    before = snapshot(setup)

    assert {:ok, retry} = recover(setup.admin, setup, command, " paper scorecard ")
    assert retry.id == first.id
    assert snapshot(setup) == before
    refute_receive {:group_hole_submitted, _}, 50
    refute_receive {:mystery_reveal_changed, _}, 50
  end

  test "same key conflicts when source, reason, or scoring payload changes" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)

    assert {:ok, _} = recover(setup.admin, setup, command, "paper scorecard")

    assert {:error, :idempotency_payload_conflict} =
             recover(setup.admin, setup, command, "different reason")

    changed_payload = Map.put(command, :results, holed_out_results(setup.entries, 5))

    assert {:error, :idempotency_payload_conflict} =
             recover(setup.admin, setup, changed_payload, "paper scorecard")

    assert {:error, :idempotency_payload_conflict} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
  end

  test "complete valid paper outcomes pass while invalid outcomes and pickups fail" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    [first_entry, second_entry] = setup.entries

    valid =
      command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
      |> Map.put(:results, [
        %{
          round_entry_id: first_entry.id,
          outcome: :picked_up,
          gross_strokes: nil,
          strokes_taken: 8
        },
        %{round_entry_id: second_entry.id, outcome: :holed_out, gross_strokes: 4}
      ])

    assert {:ok, receipt} = recover(setup.admin, setup, valid, "paper scorecard")
    assert receipt.source == "paper_recovery"

    second = PaperRecoveryFixtures.setup_submit_fixture!(2)

    invalid_result =
      command(second, second.group.id, second.entries, second.start_hole.id, 0)
      |> Map.update!(:results, fn [first | rest] -> [%{first | outcome: :disqualified} | rest] end)

    assert {:error, :invalid_result} = recover(second.admin, second, invalid_result, "paper")

    incomplete =
      command(second, second.group.id, second.entries, second.start_hole.id, 0)
      |> Map.update!(:results, &Enum.take(&1, 1))

    assert {:error, :results_count_mismatch} = recover(second.admin, second, incomplete, "paper")

    invalid_pickup =
      command(second, second.group.id, second.entries, second.start_hole.id, 0)
      |> Map.update!(:results, fn [first | rest] ->
        [Map.merge(first, %{outcome: :picked_up, gross_strokes: nil, strokes_taken: 1}) | rest]
      end)

    assert {:error, :pickup_not_eligible} = recover(second.admin, second, invalid_pickup, "paper")
    assert submission_count(second.round.id) == 0
  end

  test "stale revisions and skipped holes are rejected; consecutive recovery follows play order" do
    setup = PaperRecoveryFixtures.setup_shotgun_fixture!(10)
    start_index = Enum.find_index(setup.route, &(&1.id == setup.start_hole.id))
    {head, tail} = Enum.split(setup.route, start_index)
    playing_order = tail ++ head
    first_hole = Enum.at(playing_order, 0)
    second_hole = Enum.at(playing_order, 1)
    third_hole = Enum.at(playing_order, 2)

    assert first_hole.play_order == 10
    assert second_hole.play_order == 11
    first = command(setup, setup.group.id, setup.entries, first_hole.id, 0)

    assert {:ok, _} = recover(setup.admin, setup, first, "paper hole one")

    stale = Map.put(first, :client_submission_id, Ecto.UUID.generate())

    assert {:error, :stale_scoring_revision} =
             recover(setup.admin, setup, stale, "paper hole one")

    skipped = command(setup, setup.group.id, setup.entries, third_hole.id, 1)
    assert {:error, :wrong_round_hole} = recover(setup.admin, setup, skipped, "paper hole three")

    second = command(setup, setup.group.id, setup.entries, second_hole.id, 1)
    assert {:ok, second_receipt} = recover(setup.admin, setup, second, "paper hole two")
    assert second_receipt.round_hole_id == second_hole.id
    assert submission_count(setup.round.id) == 2
    assert result_count(setup.round.id) == 2 * length(setup.entries)
  end

  test "paper recovery of the final required Mystery group reveals exactly once" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    normal = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    paper = command(setup, setup.group_b.id, setup.entries_b, setup.start_hole.id, 0)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, normal)
    assert_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}, 50

    assert {:ok, receipt} = recover(setup.admin, setup, paper, "final paper scorecard")
    assert receipt.source == "paper_recovery"
    assert_receive {:group_hole_submitted, _}
    assert_receive {:mystery_reveal_changed, reveal_payload}
    assert reveal_payload == %{round_id: setup.round.id}
    assert reveal_count(setup.mystery.rule.id) == 1

    assert {:ok, _} = recover(setup.admin, setup, paper, "final paper scorecard")
    refute_receive {:mystery_reveal_changed, _}, 50
    assert reveal_count(setup.mystery.rule.id) == 1
  end

  test "concurrent online and paper submissions cannot accept the same hole twice" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")

    tasks = [
      Task.async(fn ->
        SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, command)
      end),
      Task.async(fn -> recover(setup.admin, setup, command, "paper scorecard") end)
    ]

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :idempotency_payload_conflict})) == 1
    assert submission_count(setup.round.id) == 1
    assert result_count(setup.round.id) == length(setup.entries)
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 1
    assert_receive {:group_hole_submitted, _}
    refute_receive {:group_hole_submitted, _}, 50
  end

  test "late receipt failure rolls back paper scoring and emits no PubSub" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    install_reject_receipt_trigger!()

    assert {:error, _} = recover(setup.admin, setup, command, "paper scorecard")
    assert snapshot(setup) == empty_snapshot(setup)
    refute_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}
  end

  test "late audit failure rolls back paper scoring, receipt, and lifecycle" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    command = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    install_reject_audit_trigger!()

    assert {:error, _} = recover(setup.admin, setup, command, "paper scorecard")
    assert snapshot(setup) == empty_snapshot(setup)
    refute_receive {:group_hole_submitted, _}
  end

  test "late Mystery reveal failure rolls back paper scoring, receipt, and audit" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    normal = command(setup, setup.group.id, setup.entries, setup.start_hole.id, 0)
    assert {:ok, _} = SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, normal)

    before = snapshot_for_group(setup, setup.group_b.id, setup.entries_b)
    paper = command(setup, setup.group_b.id, setup.entries_b, setup.start_hole.id, 0)
    Phoenix.PubSub.subscribe(GolfScoring.PubSub, "round:#{setup.round.id}")
    install_reject_reveal_trigger!()

    assert {:error, _} = recover(setup.admin, setup, paper, "final paper scorecard")
    assert snapshot_for_group(setup, setup.group_b.id, setup.entries_b) == before
    assert reveal_count(setup.mystery.rule.id) == 0
    refute_receive {:group_hole_submitted, _}
    refute_receive {:mystery_reveal_changed, _}
  end

  defp recover(actor, setup, command, reason) do
    SubmitGroupHole.run_paper_recovery(actor, setup.event.id, setup.round.id, command, reason)
  end

  defp command(_setup, group_id, entries, hole_id, revision) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: group_id,
      round_hole_id: hole_id,
      expected_group_score_revision: revision,
      results: holed_out_results(entries, 4),
      captured_at: ~U[2026-11-03 12:00:00.000000Z]
    }
  end

  defp holed_out_results(entries, strokes) do
    Enum.map(entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: strokes})
  end

  defp create_staff_user! do
    email = "gls79-#{System.unique_integer([:positive])}@example.com"

    StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp assign_event_role!(setup, staff, role) do
    assert {:ok, _} =
             Accounts.assign_event_staff_role(
               %{event_id: setup.event.id, staff_user_id: staff.id, role: role},
               actor: setup.admin
             )
  end

  defp audit_for_receipt!(receipt_id) do
    AuditEvent
    |> Ash.Query.filter(target_id == ^receipt_id and action == "submit_group_hole")
    |> Ash.read_one!(authorize?: false)
  end

  defp snapshot(setup), do: snapshot_for_group(setup, setup.group.id, setup.entries)

  defp empty_snapshot(setup) do
    %{
      results: 0,
      submissions: 0,
      audits: 0,
      scorecards: 0,
      revision: 0,
      group_state: :not_started,
      participation: List.duplicate(:not_started, length(setup.entries))
    }
  end

  defp snapshot_for_group(setup, group_id, entries) do
    group = Ash.get!(PlayingGroup, group_id, authorize?: false)
    entry_ids = Enum.map(entries, & &1.id)

    %{
      results: result_count_for_group(group_id),
      submissions: count_by_group("hole_submissions", group_id),
      audits: audit_count(setup.round.id, group_id),
      scorecards: count_for_entries("scorecards", entry_ids),
      revision: group.scoring_revision,
      group_state: group.state,
      participation:
        Enum.map(entries, fn entry ->
          Ash.get!(RoundEntry, entry.id, authorize?: false).participation_status
        end)
    }
  end

  defp result_count_for_group(group_id) do
    Repo.query!(
      """
      SELECT count(*)::int
      FROM hole_results hr
      JOIN scorecards sc ON sc.id = hr.scorecard_id
      JOIN round_entries re ON re.id = sc.round_entry_id
      WHERE re.playing_group_id = $1::uuid
      """,
      [Ecto.UUID.dump!(group_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp count_by_group(table, group_id) do
    Repo.query!("SELECT count(*)::int FROM #{table} WHERE playing_group_id = $1::uuid", [
      Ecto.UUID.dump!(group_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp count_for_entries(table, entry_ids) do
    Repo.query!("SELECT count(*)::int FROM #{table} WHERE round_entry_id = ANY($1::uuid[])", [
      Enum.map(entry_ids, &Ecto.UUID.dump!/1)
    ]).rows
    |> hd()
    |> hd()
  end

  defp audit_count(round_id, group_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'submit_group_hole' AND context->>'round_id' = $1 AND context->>'playing_group_id' = $2",
      [to_string(round_id), to_string(group_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp submission_count(round_id) do
    Repo.query!("SELECT count(*)::int FROM hole_submissions WHERE round_id = $1::uuid", [
      Ecto.UUID.dump!(round_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp result_count(round_id) do
    Repo.query!("SELECT count(*)::int FROM hole_results WHERE round_id = $1::uuid", [
      Ecto.UUID.dump!(round_id)
    ]).rows
    |> hd()
    |> hd()
  end

  defp reveal_count(rule_id) do
    Repo.query!(
      "SELECT count(*)::int FROM mystery_reveals WHERE mystery_hole_rule_id = $1::uuid",
      [
        Ecto.UUID.dump!(rule_id)
      ]
    ).rows
    |> hd()
    |> hd()
  end

  defp assert_constraint_violation!(sql, params, constraint) do
    error = assert_raise Postgrex.Error, fn -> Repo.query!(sql, params) end
    assert error.postgres.constraint == constraint
  end

  defp install_reject_receipt_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls79_reject_receipt() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'GLS-79 receipt failure'; END; $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls79_reject_receipt_trigger
    BEFORE INSERT ON hole_submissions
    FOR EACH ROW EXECUTE FUNCTION gls79_reject_receipt()
    """)
  end

  defp install_reject_audit_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls79_reject_audit() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'submit_group_hole' THEN RAISE EXCEPTION 'GLS-79 audit failure'; END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls79_reject_audit_trigger
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION gls79_reject_audit()
    """)
  end

  defp install_reject_reveal_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION gls79_reject_reveal() RETURNS trigger
    LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'GLS-79 reveal failure'; END; $$
    """)

    Repo.query!("""
    CREATE TRIGGER gls79_reject_reveal_trigger
    BEFORE INSERT ON mystery_reveals
    FOR EACH ROW EXECUTE FUNCTION gls79_reject_reveal()
    """)
  end

  defp legacy_vector do
    %{
      group_id: "00000000-0000-4000-8000-000000000001",
      hole_id: "00000000-0000-4000-8000-000000000002",
      revision: 0,
      captured_at: ~U[2026-11-03 12:00:00.000000Z],
      actor_id: "00000000-0000-4000-8000-000000000003",
      results: [
        %{
          round_entry_id: "00000000-0000-4000-8000-000000000005",
          outcome: :holed_out,
          gross_strokes: 5
        },
        %{
          round_entry_id: "00000000-0000-4000-8000-000000000004",
          outcome: :holed_out,
          gross_strokes: 4
        }
      ]
    }
  end

  defp legacy_fingerprint(vector) do
    results =
      vector.results
      |> Enum.map(fn result ->
        {result.round_entry_id, result.outcome, result.gross_strokes,
         Map.get(result, :strokes_taken)}
      end)
      |> Enum.sort_by(fn {entry_id, _, _, _} -> entry_id end)

    {
      vector.group_id,
      vector.hole_id,
      vector.revision,
      nil,
      DateTime.to_unix(vector.captured_at, :microsecond),
      {:staff, vector.actor_id},
      results
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
