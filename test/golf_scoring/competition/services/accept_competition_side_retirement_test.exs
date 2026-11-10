defmodule GolfScoring.Competition.Services.AcceptCompetitionSideRetirementTest do
  use ExUnit.Case, async: false

  alias Ash.Changeset
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.CompetitionSideRetirement
  alias GolfScoring.Competition.CompetitionSideRetirementEligibility
  alias GolfScoring.Competition.Services.AcceptCompetitionSideRetirement
  alias GolfScoring.Competition.Services.ExcludeCompetitionSideBeforeHole
  alias GolfScoring.Competition.Services.LoadSideReviewReason
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoring.Scoring.Services.SubmitGroupHole

  @password "GLS-80 synthetic staff passphrase 2026"
  @reason "authorized non-punitive retirement after reviewed checkpoint"

  setup do
    Process.put(:gls34_prefix, "gls41-retire-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  test "authorized acceptance persists evidence, review_required, audit, and eligibility" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()

    assert {:ok, %{retirement_id: retirement_id, idempotent_retry?: false}} =
             accept(setup, side_id, checkpoint, effective, command_id)

    assert side_result_state(side_id) == "review_required"
    refute CompetitionSideRetirementEligibility.placing_eligible?(side_id)
    assert count_retirement_audits(retirement_id) == 1

    assert Repo.query!("SELECT count(*)::int FROM competition_side_retirements").rows
           |> hd()
           |> hd() == 1

    assert hd(Repo.query!("SELECT count(*)::int FROM hole_results").rows |> hd()) > 0
  end

  test "exact command retry returns original outcome without duplicate audit" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()

    assert {:ok, %{retirement_id: first_id}} =
             accept(setup, side_id, checkpoint, effective, command_id)

    assert {:ok, %{retirement_id: second_id, idempotent_retry?: true}} =
             accept(setup, side_id, checkpoint, effective, command_id)

    assert first_id == second_id
    assert count_retirement_audits(first_id) == 1
  end

  test "conflicting command meaning rejects" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()

    assert {:ok, _} = accept(setup, side_id, checkpoint, effective, command_id)

    assert {:error, :command_meaning_conflict} =
             accept(setup, side_id, checkpoint, effective, command_id, %{
               reason: "changed meaning for the same command identity"
             })
  end

  test "second retirement for the same side rejects" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    assert {:ok, _} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    assert {:error, :competition_side_already_retired} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )
  end

  test "forged actor maps are rejected even when the id matches an authorized administrator" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    before = retirement_row_count()

    assert {:error, :forbidden} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate(),
               %{actor: %{id: setup.admin.id}}
             )

    assert retirement_row_count() == before
  end

  test "forbidden staff, missing attestation, and scope mismatch fail closed" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    assert {:error, :forbidden} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate(),
               %{
                 actor: %{id: hd(setup.entries).id}
               }
             )

    assert {:error, :preplay_boundary_attestation_required} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate(),
               %{
                 confirm_effective_hole_unplayed?: false
               }
             )

    assert {:error, scope_error} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate(),
               %{playing_group_id: Ecto.UUID.generate()}
             )

    assert scope_error in [:playing_group_mismatch, :playing_group_not_found]
  end

  test "terminal SideResult rejects acceptance" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)

    Repo.query!(
      "UPDATE competition_side_results SET state = 'finalized' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(result.id)]
    )

    assert {:error, :competition_side_result_terminal} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )
  end

  test "checkpoint and effective boundary validation rejects invalid play" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    assert {:error, :effective_boundary_already_passed} =
             accept(
               setup,
               side_id,
               checkpoint,
               %{effective | hole_id: checkpoint.hole_id},
               Ecto.UUID.generate()
             )
  end

  test "LoadSideReviewReason reflects accepted retirement placement boundary" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)

    assert {:ok, %{placing_eligible?: true, official_contribution_blocked_from_play_index: nil}} =
             LoadSideReviewReason.run(setup.admin, setup.event.id, setup.round.id, result.id)

    assert {:ok, %{retirement_id: retirement_id}} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    assert {:ok,
            %{
              placing_eligible?: false,
              official_contribution_blocked_from_play_index: blocked_from
            }} = LoadSideReviewReason.run(setup.admin, setup.event.id, setup.round.id, result.id)

    assert is_integer(blocked_from)
    refute CompetitionSideRetirementEligibility.placing_eligible?(side_id)
    assert count_retirement_audits(retirement_id) == 1
  end

  test "concurrent different-command acceptance keeps exactly one ruling" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    parent = self()

    first =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        accept(setup, side_id, checkpoint, effective, Ecto.UUID.generate())
      end)

    second =
      Task.async(fn ->
        Sandbox.allow(Repo, parent, self())

        accept(setup, side_id, checkpoint, effective, Ecto.UUID.generate())
      end)

    results = [Task.await(first, 30_000), Task.await(second, 30_000)]

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.any?(results, fn
             {:error, :competition_side_already_retired} -> true
             _ -> false
           end)

    assert Repo.query!("SELECT count(*)::int FROM competition_side_retirements").rows
           |> hd()
           |> hd() == 1
  end

  test "a failed audit insert rolls back retirement evidence and review transition" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)
    function_name = "gls41_reject_retire_audit_#{System.unique_integer([:positive])}"
    trigger_name = "gls41_reject_retire_audit_trigger_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.action = 'accept_competition_side_retirement' THEN
        RAISE EXCEPTION 'GLS-41 test audit failure' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON audit_events
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger_name} ON audit_events")
      Repo.query!("DROP FUNCTION IF EXISTS #{function_name}()")
    end)

    assert {:error, _} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    assert side_result_state(side_id) == "provisional"

    assert Repo.query!("SELECT count(*)::int FROM competition_side_retirements").rows
           |> hd()
           |> hd() == 0

    assert CompetitionSideRetirementEligibility.placing_eligible?(side_id)
    assert is_map(provisional_result_for_side!(side_id))
    assert result.id == provisional_result_for_side!(side_id).id
  end

  test "a failed mystery recheck rolls back retirement acceptance" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.configure_single_group_mystery!(setup)
    holes = round_holes_in_play_order(setup.round.id)
    mystery_hole = Enum.at(holes, 1)

    Repo.query!(
      "UPDATE mystery_hole_rules SET round_hole_id = $1::uuid WHERE round_id = $2::uuid",
      [Ecto.UUID.dump!(mystery_hole.id), Ecto.UUID.dump!(setup.round.id)]
    )

    {checkpoint, effective} = checkpoint_and_effective!(setup, setup.group, setup.entries)

    side_id = side_id_for_entries(setup.entries)

    function_name = "gls41_reject_retire_reveal_#{System.unique_integer([:positive])}"
    trigger_name = "gls41_reject_retire_reveal_trigger_#{System.unique_integer([:positive])}"

    Repo.query!("""
    CREATE FUNCTION #{function_name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION 'GLS-41 test reveal failure' USING ERRCODE = '23514';
    END;
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER #{trigger_name}
    BEFORE INSERT ON mystery_reveals
    FOR EACH ROW EXECUTE FUNCTION #{function_name}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{trigger_name} ON mystery_reveals")
      Repo.query!("DROP FUNCTION IF EXISTS #{function_name}()")
    end)

    assert {:error, _} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    assert side_result_state(side_id) == "provisional"

    assert Repo.query!("SELECT count(*)::int FROM competition_side_retirements").rows
           |> hd()
           |> hd() == 0
  end

  test "retirement after an accepted checkpoint submission keeps that submission" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    assert accepted_submission?(setup.round.id, setup.group.id, checkpoint.hole_id)

    assert {:ok, _} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    assert accepted_submission?(setup.round.id, setup.group.id, checkpoint.hole_id)
  end

  test "mixed retired and excluded cohort resolves NOT_APPLICABLE after both groups are ineligible" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    holes = round_holes_in_play_order(setup.round.id)
    mystery_hole = Enum.at(holes, 1).id

    Repo.query!(
      "UPDATE mystery_hole_rules SET round_hole_id = $1::uuid WHERE id = $2::uuid",
      [Ecto.UUID.dump!(mystery_hole), Ecto.UUID.dump!(setup.mystery.rule.id)]
    )

    side_a = side_id_for_entries(setup.entries)
    side_b = side_id_for_entries(setup.entries_b)

    {checkpoint_a, effective_a} = checkpoint_and_effective!(setup, setup.group, setup.entries)
    checkpoint_and_effective!(setup, setup.group_b, setup.entries_b)

    reveals_before =
      count_for_rule("mystery_reveals", setup.mystery.rule.id)

    assert {:ok, %{mystery_reveal_created?: false}} =
             accept(
               setup,
               side_a,
               checkpoint_a,
               effective_a,
               Ecto.UUID.generate(),
               %{playing_group_id: setup.group.id}
             )

    assert count_for_rule("mystery_reveals", setup.mystery.rule.id) == reveals_before

    assert {:ok, %{mystery_reveal_created?: true}} =
             ExcludeCompetitionSideBeforeHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               side_b,
               setup.group_b.id,
               mystery_hole,
               %{reason: "pre-play exclusion for partner group", confirm_hole_unplayed?: true}
             )

    assert count_for_rule("mystery_reveals", setup.mystery.rule.id) == 1
  end

  test "retirement at effective boundary does not resolve a later mystery target without submission" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    holes = round_holes_in_play_order(setup.round.id)
    later_mystery_hole = Enum.at(holes, 2).id

    Repo.query!(
      "UPDATE mystery_hole_rules SET round_hole_id = $1::uuid WHERE id = $2::uuid",
      [Ecto.UUID.dump!(later_mystery_hole), Ecto.UUID.dump!(setup.mystery.rule.id)]
    )

    side_a = side_id_for_entries(setup.entries)
    side_b = side_id_for_entries(setup.entries_b)
    {checkpoint_a, effective_a} = checkpoint_and_effective!(setup, setup.group, setup.entries)
    {checkpoint_b, effective_b} = checkpoint_and_effective!(setup, setup.group_b, setup.entries_b)

    assert {:ok, %{mystery_reveal_created?: false}} =
             accept(
               setup,
               side_a,
               checkpoint_a,
               effective_a,
               Ecto.UUID.generate(),
               %{playing_group_id: setup.group.id}
             )

    assert {:ok, %{mystery_reveal_created?: false}} =
             accept(
               setup,
               side_b,
               checkpoint_b,
               effective_b,
               Ecto.UUID.generate(),
               %{playing_group_id: setup.group_b.id, reason: "partner group retirement"}
             )

    assert count_for_rule("mystery_reveals", setup.mystery.rule.id) == 0
    refute accepted_submission?(setup.round.id, setup.group.id, later_mystery_hole)
    refute accepted_submission?(setup.round.id, setup.group_b.id, later_mystery_hole)
  end

  test "one still-eligible side keeps mystery unresolved without submission" do
    setup = PaperRecoveryFixtures.setup_two_group_mystery_fixture!()
    holes = round_holes_in_play_order(setup.round.id)
    mystery_hole = Enum.at(holes, 1).id

    Repo.query!(
      "UPDATE mystery_hole_rules SET round_hole_id = $1::uuid WHERE id = $2::uuid",
      [Ecto.UUID.dump!(mystery_hole), Ecto.UUID.dump!(setup.mystery.rule.id)]
    )

    side_a = side_id_for_entries(setup.entries)
    {checkpoint_a, effective_a} = checkpoint_and_effective!(setup, setup.group, setup.entries)

    assert {:ok, %{mystery_reveal_created?: false}} =
             accept(
               setup,
               side_a,
               checkpoint_a,
               effective_a,
               Ecto.UUID.generate(),
               %{playing_group_id: setup.group.id}
             )

    assert count_for_rule("mystery_reveals", setup.mystery.rule.id) == 0
  end

  test "group scoring continues on later holes after accepted retirement" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    assert {:ok, _} =
             accept(
               setup,
               side_id,
               checkpoint,
               effective,
               Ecto.UUID.generate()
             )

    revision =
      Repo.query!(
        "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
        [Ecto.UUID.dump!(setup.group.id)]
      ).rows
      |> hd()
      |> hd()

    assert {:ok, _} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: setup.group.id,
               round_hole_id: effective.hole_id,
               expected_group_score_revision: revision,
               results:
                 Enum.map(
                   setup.entries,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4}
                 ),
               captured_at: DateTime.utc_now()
             })
  end

  test "revoked staff cannot retry an accepted retirement command" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()

    assert {:ok, %{idempotent_retry?: false}} =
             accept(setup, side_id, checkpoint, effective, command_id)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE staff_user_id = $1::uuid AND event_id = $2::uuid",
      [Ecto.UUID.dump!(setup.admin.id), Ecto.UUID.dump!(setup.event.id)]
    )

    assert {:error, :forbidden} = accept(setup, side_id, checkpoint, effective, command_id)
  end

  test "cross-event staff cannot retry an accepted retirement command" do
    {setup, checkpoint, effective} = prepared_fixture!()
    other = PaperRecoveryFixtures.setup_submit_fixture!(2)
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()

    assert {:ok, _} = accept(setup, side_id, checkpoint, effective, command_id)

    assert {:error, :forbidden} =
             accept(setup, side_id, checkpoint, effective, command_id, %{actor: other.admin})
  end

  test "same command identity with changed effective boundary is a meaning conflict" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()
    holes = round_holes_in_play_order(setup.round.id)
    start_id = setup.group.starting_round_hole_id || hd(holes).id
    third_hole = rotate(holes, Enum.find_index(holes, &(&1.id == start_id))) |> Enum.at(2)

    assert {:ok, _} = accept(setup, side_id, checkpoint, effective, command_id)

    assert {:error, :command_meaning_conflict} =
             accept(setup, side_id, checkpoint, %{hole_id: third_hole.id}, command_id)
  end

  test "concurrent identical-command acceptance keeps one audit" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    command_id = Ecto.UUID.generate()
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          accept(setup, side_id, checkpoint, effective, command_id)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 30_000))
    assert Enum.all?(results, &match?({:ok, _}, &1))
    retirement_ids = Enum.map(results, fn {:ok, %{retirement_id: id}} -> id end)
    assert Enum.uniq(retirement_ids) == [hd(retirement_ids)]
    assert count_retirement_audits(hd(retirement_ids)) == 1
  end

  test "unproven effective gap rejects even without submissions or results on intervening holes" do
    {setup, checkpoint, _effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    holes = round_holes_in_play_order(setup.round.id)
    start_id = setup.group.starting_round_hole_id || hd(holes).id
    start_index = Enum.find_index(holes, &(&1.id == start_id))
    skipped_effective = rotate(holes, start_index) |> Enum.at(2)

    refute hole_submission_exists?(setup, skipped_effective.id)
    refute hole_result_exists?(setup, skipped_effective.id)

    assert {:error, :retirement_boundary_gap_unproven} =
             accept(
               setup,
               side_id,
               checkpoint,
               %{hole_id: skipped_effective.id},
               Ecto.UUID.generate()
             )
  end

  test "attention_required group state fails closed as uncertain physical play" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    Repo.query!("UPDATE playing_groups SET state = 'attention_required' WHERE id = $1::uuid", [
      Ecto.UUID.dump!(setup.group.id)
    ])

    assert {:error, :physical_play_status_uncertain} =
             accept(setup, side_id, checkpoint, effective, Ecto.UUID.generate())
  end

  test "stale checkpoint receipt rejects acceptance" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)

    revision =
      Repo.query!(
        "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
        [Ecto.UUID.dump!(setup.group.id)]
      ).rows
      |> hd()
      |> hd()

    assert {:ok, _} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: setup.group.id,
               round_hole_id: effective.hole_id,
               expected_group_score_revision: revision,
               results:
                 Enum.map(
                   setup.entries,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4}
                 ),
               captured_at: DateTime.utc_now()
             })

    assert {:error, :stale_checkpoint_receipt} =
             accept(setup, side_id, checkpoint, effective, Ecto.UUID.generate())
  end

  test "excluded sides are not placing eligible" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    mystery = PaperRecoveryFixtures.configure_single_group_mystery!(setup)
    side_id = side_id_for_entries(setup.entries)

    assert {:ok, _} =
             ExcludeCompetitionSideBeforeHole.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.competition.id,
               side_id,
               setup.group.id,
               mystery.rule.round_hole_id,
               %{reason: "pre-play exclusion", confirm_hole_unplayed?: true}
             )

    refute CompetitionSideRetirementEligibility.placing_eligible?(side_id)
  end

  test "retirement in one competition leaves another competition side placing eligible" do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(4)
    PaperRecoveryFixtures.set_round_state!(setup.round, :draft)

    secondary =
      GolfScoring.Competition.RoundCompetition
      |> Ash.Changeset.for_create(:configure_internal, %{
        event_id: setup.event.id,
        round_id: setup.round.id,
        is_primary: false
      })
      |> Ash.create!(authorize?: false)

    {:ok, secondary_side} =
      Competition.create_competition_side(
        setup.admin,
        setup.event.id,
        setup.round.id,
        secondary.id,
        :partnership
      )

    {:ok, _} =
      Competition.set_side_membership(
        setup.admin,
        setup.event.id,
        setup.round.id,
        secondary.id,
        secondary_side.id,
        Enum.map(Enum.take(setup.entries, 2), & &1.id)
      )

    PaperRecoveryFixtures.configure_mystery_for_groups!(setup, [
      {setup.group, Enum.take(setup.entries, 2)}
    ])

    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_open)

    primary_entries = Enum.take(setup.entries, 2)
    {setup, checkpoint, effective} = prepared_fixture_from!(setup, setup.entries)

    primary_side_id =
      side_id_for_competition!(setup.competition.id, Enum.map(primary_entries, & &1.id))

    assert {:ok, _} = accept(setup, primary_side_id, checkpoint, effective, Ecto.UUID.generate())
    refute CompetitionSideRetirementEligibility.placing_eligible?(primary_side_id)
    assert CompetitionSideRetirementEligibility.placing_eligible?(secondary_side.id)
  end

  test "direct Ash create in a valid scope requires coordinator proof" do
    {setup, checkpoint, effective} = prepared_fixture!()
    side_id = side_id_for_entries(setup.entries)
    result = provisional_result_for_side!(side_id)

    attrs = %{
      event_id: setup.event.id,
      round_id: setup.round.id,
      round_competition_id: setup.competition.id,
      competition_side_id: side_id,
      competition_side_result_id: result.id,
      playing_group_id: setup.group.id,
      authorized_by_staff_user_id: setup.admin.id,
      reason: @reason,
      acceptance_command_id: Ecto.UUID.generate(),
      command_meaning_fingerprint: :crypto.strong_rand_bytes(32),
      checkpoint_hole_submission_id: checkpoint.submission_id,
      checkpoint_round_hole_id: checkpoint.hole_id,
      checkpoint_play_index: 0,
      effective_round_hole_id: effective.hole_id,
      effective_play_index: 1,
      preplay_boundary_confirmed: true
    }

    assert {:error, %Ash.Error.Invalid{} = error} =
             CompetitionSideRetirement
             |> Changeset.for_create(:create_accepted_internal, attrs)
             |> Ash.create(authorize?: false)

    assert %Ash.Error.Invalid{errors: errors} = error

    assert Enum.any?(errors, fn
             %Ash.Error.Changes.InvalidChanges{message: msg} when is_binary(msg) ->
               String.contains?(msg, "coordinator")

             _ ->
               false
           end)
  end

  defp prepared_fixture! do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.configure_single_group_mystery!(setup)
    prepared_fixture_from!(setup, setup.entries)
  end

  defp prepared_fixture_from!(setup, entries) do
    holes = round_holes_in_play_order(setup.round.id)
    start_id = setup.group.starting_round_hole_id || hd(holes).id
    start_index = Enum.find_index(holes, &(&1.id == start_id))
    rotated = rotate(holes, start_index)
    checkpoint_hole = hd(rotated)
    effective_hole = Enum.at(rotated, 1)

    assert {:ok, _} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: setup.group.id,
               round_hole_id: checkpoint_hole.id,
               expected_group_score_revision: 0,
               results:
                 Enum.map(entries, fn entry ->
                   %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
                 end),
               captured_at: DateTime.utc_now()
             })

    submission_id =
      Repo.query!(
        """
        SELECT id::text FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(setup.round.id),
          Ecto.UUID.dump!(setup.group.id),
          Ecto.UUID.dump!(checkpoint_hole.id)
        ]
      ).rows
      |> hd()
      |> hd()
      |> Ecto.UUID.cast!()

    {setup, %{submission_id: submission_id, hole_id: checkpoint_hole.id},
     %{hole_id: effective_hole.id}}
  end

  defp accept(setup, side_id, checkpoint, effective, command_id, opts \\ %{}) do
    Competition.accept_competition_side_retirement(
      Map.get(opts, :actor, setup.admin),
      Map.get(opts, :event_id, setup.event.id),
      Map.get(opts, :round_id, setup.round.id),
      Map.get(opts, :round_competition_id, setup.competition.id),
      side_id,
      Map.get(opts, :playing_group_id, setup.group.id),
      %{
        reason: Map.get(opts, :reason, @reason),
        acceptance_command_id: command_id,
        checkpoint_hole_submission_id: checkpoint.submission_id,
        effective_from_round_hole_id: effective.hole_id,
        confirm_effective_hole_unplayed?: Map.get(opts, :confirm_effective_hole_unplayed?, true)
      }
    )
  end

  defp round_holes_in_play_order(round_id) do
    Repo.query!(
      "SELECT id::text, play_order::int FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, order] -> %{id: Ecto.UUID.cast!(id), play_order: order} end)
  end

  defp rotate(holes, start_index) do
    {head, tail} = Enum.split(holes, start_index)
    tail ++ head
  end

  defp side_id_for_entries(entries) do
    entry_ids = Enum.map(entries, &Ecto.UUID.dump!(&1.id))

    [[side_id]] =
      Repo.query!(
        """
        SELECT DISTINCT competition_side_id::text
        FROM competition_side_memberships
        WHERE round_entry_id = ANY($1::uuid[])
        """,
        [entry_ids]
      ).rows

    Ecto.UUID.cast!(side_id)
  end

  defp side_id_for_competition!(round_competition_id, entry_ids) do
    [[side_id]] =
      Repo.query!(
        """
        SELECT competition_side_id::text
        FROM competition_side_memberships
        WHERE round_competition_id = $1::uuid
          AND round_entry_id = ANY($2::uuid[])
        LIMIT 1
        """,
        [Ecto.UUID.dump!(round_competition_id), Enum.map(entry_ids, &Ecto.UUID.dump!/1)]
      ).rows

    Ecto.UUID.cast!(side_id)
  end

  defp provisional_result_for_side!(side_id) do
    [[id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [Ecto.UUID.dump!(side_id)]
      ).rows

    Ash.get!(CompetitionSideResult, Ecto.UUID.cast!(id), authorize?: false)
  end

  defp side_result_state(side_id) do
    [[state]] =
      Repo.query!(
        "SELECT state FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [Ecto.UUID.dump!(side_id)]
      ).rows

    state
  end

  defp retirement_row_count do
    Repo.query!("SELECT count(*)::int FROM competition_side_retirements").rows |> hd() |> hd()
  end

  defp count_retirement_audits(retirement_id) do
    Repo.query!(
      "SELECT count(*)::int FROM audit_events WHERE action = 'accept_competition_side_retirement' AND target_id = $1::uuid",
      [Ecto.UUID.dump!(retirement_id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp checkpoint_and_effective!(setup, group, entries) do
    holes = round_holes_in_play_order(setup.round.id)
    start_id = group.starting_round_hole_id || hd(holes).id
    start_index = Enum.find_index(holes, &(&1.id == start_id))
    rotated = rotate(holes, start_index)
    checkpoint_hole = hd(rotated)
    effective_hole = Enum.at(rotated, 1)

    revision =
      Repo.query!(
        "SELECT scoring_revision FROM playing_groups WHERE id = $1::uuid",
        [Ecto.UUID.dump!(group.id)]
      ).rows
      |> hd()
      |> hd()

    assert {:ok, _} =
             SubmitGroupHole.run(setup.admin, setup.event.id, setup.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: group.id,
               round_hole_id: checkpoint_hole.id,
               expected_group_score_revision: revision,
               results:
                 Enum.map(entries, fn entry ->
                   %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 5}
                 end),
               captured_at: DateTime.utc_now()
             })

    submission_id =
      Repo.query!(
        """
        SELECT id::text FROM hole_submissions
        WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(setup.round.id),
          Ecto.UUID.dump!(group.id),
          Ecto.UUID.dump!(checkpoint_hole.id)
        ]
      ).rows
      |> hd()
      |> hd()
      |> Ecto.UUID.cast!()

    {%{submission_id: submission_id, hole_id: checkpoint_hole.id}, %{hole_id: effective_hole.id}}
  end

  defp count_for_rule(table, id, column \\ "mystery_hole_rule_id") do
    Repo.query!(
      "SELECT count(*)::int FROM #{table} WHERE #{column} = $1::uuid",
      [Ecto.UUID.dump!(id)]
    ).rows
    |> hd()
    |> hd()
  end

  defp accepted_submission?(round_id, group_id, hole_id) do
    Repo.query!(
      """
      SELECT 1 FROM hole_submissions
      WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
        AND accepted_at IS NOT NULL
      """,
      [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(group_id), Ecto.UUID.dump!(hole_id)]
    ).rows != []
  end

  defp hole_submission_exists?(setup, hole_id) do
    Repo.query!(
      """
      SELECT 1 FROM hole_submissions
      WHERE round_id = $1::uuid AND playing_group_id = $2::uuid AND round_hole_id = $3::uuid
      """,
      [
        Ecto.UUID.dump!(setup.round.id),
        Ecto.UUID.dump!(setup.group.id),
        Ecto.UUID.dump!(hole_id)
      ]
    ).rows != []
  end

  defp hole_result_exists?(setup, hole_id) do
    Repo.query!(
      """
      SELECT 1 FROM hole_results hr
      WHERE hr.round_id = $1::uuid AND hr.round_hole_id = $2::uuid
      """,
      [Ecto.UUID.dump!(setup.round.id), Ecto.UUID.dump!(hole_id)]
    ).rows != []
  end
end
