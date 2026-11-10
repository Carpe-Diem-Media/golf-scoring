defmodule GolfScoring.Scoring.Services.LoadPlayerVerificationContextTest do
  use GolfScoring.DataCase, async: false

  require Ash.Query
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.GroupRoleAssignment
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "designated verifier sees current group results and cannot certify their own" do
    f = fixture!()
    assert {:ok, context} = load(f, f.verifier_grant)
    assert context.assignment.id == f.verifier_assignment.id
    assert context.assignment.version == f.verifier_assignment.assignment_version
    scorer = Enum.find(context.results, &(&1.hole_result_id == f.scorer_result.id))
    own = Enum.find(context.results, &(&1.hole_result_id == f.verifier_result.id))
    assert scorer.revision == f.scorer_result.revision
    assert scorer.verification_status == :pending
    assert scorer.actionable?
    refute own.actionable?
  end

  test "primary scorer can only verify the designated verifier" do
    f = fixture!(false, 3)
    assert {:ok, context} = load(f, f.scorer_grant)
    assert Enum.find(context.results, &(&1.hole_result_id == f.verifier_result.id)).actionable?
    refute Enum.find(context.results, &(&1.hole_result_id == f.scorer_result.id)).actionable?
    third_id = Enum.at(f.entries, 2).id
    refute Enum.find(context.results, &(&1.subject_round_entry_id == third_id)).actionable?
  end

  test "rejects wrong event or group and forged actor shapes" do
    f = fixture!()

    assert {:error, :not_authorized} =
             Scoring.load_player_verification_context(
               f.verifier_grant,
               Ecto.UUID.generate(),
               f.round.id,
               f.group.id
             )

    assert {:error, :not_authorized} =
             Scoring.load_player_verification_context(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               Ecto.UUID.generate()
             )

    assert {:error, :not_authorized} =
             Scoring.load_player_verification_context(
               %{id: f.verifier_grant.id},
               f.event.id,
               f.round.id,
               f.group.id
             )
  end

  test "revoked and expired grants fail without lazy expiry writes" do
    f = fixture!()

    Repo.query!(
      "UPDATE player_access_grants SET expires_at = now() - interval '1 second' WHERE id = $1::uuid",
      [Ecto.UUID.dump!(f.verifier_grant.id)]
    )

    assert {:error, :not_authorized} = load(f, f.verifier_grant)

    assert %{rows: [["active"]]} =
             Repo.query!("SELECT state FROM player_access_grants WHERE id = $1::uuid", [
               Ecto.UUID.dump!(f.verifier_grant.id)
             ])

    Repo.query!("UPDATE player_access_grants SET expires_at = NULL WHERE id = $1::uuid", [
      Ecto.UUID.dump!(f.verifier_grant.id)
    ])

    assert {:ok, _} =
             Accounts.revoke_player_access(f.admin, f.event.id, Enum.at(f.entries, 1).player_id)

    assert {:error, :not_authorized} = load(f, f.verifier_grant)
  end

  test "handover invalidates the old verifier and returns the current assignment" do
    f = fixture!(false, 3)
    replacement = Enum.at(f.entries, 2)

    assert {:ok, assignment} =
             Competition.handover_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               replacement.id
             )

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, replacement.player_id)

    assert {:error, :not_authorized} = load(f, f.verifier_grant)
    assert {:ok, context} = load(f, grant)
    assert context.assignment.id == assignment.id
    assert context.assignment.version == assignment.assignment_version
  end

  test "reports verified and overridden current evidence without staff-only details" do
    f = fixture!()

    assert {:ok, _} =
             Scoring.verify_hole_result(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               command(f, f.scorer_result, f.verifier_assignment)
             )

    assert {:ok, _} =
             Scoring.override_hole_verification(
               f.admin,
               f.event.id,
               f.round.id,
               Map.put(
                 command(f, f.verifier_result, f.scorer_assignment),
                 :reason,
                 "private staff reason"
               )
             )

    assert {:ok, context} = load(f, f.verifier_grant)

    assert Enum.find(context.results, &(&1.hole_result_id == f.scorer_result.id)).verification_status ==
             :verified

    assert Enum.find(context.results, &(&1.hole_result_id == f.verifier_result.id)).verification_status ==
             :overridden

    refute inspect(context) =~ "private staff reason"
    refute inspect(context) =~ "token_digest"
    refute inspect(context) =~ "mystery"
  end

  test "the query indicator does not expose its staff reason or another group's result" do
    f = fixture!()
    other = fixture!()

    assert {:ok, _} =
             Scoring.query_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result.id,
               expected_revision: f.scorer_result.revision,
               reason: "staff-only query detail"
             })

    assert {:ok, context} = load(f, f.verifier_grant)
    assert Enum.find(context.results, &(&1.hole_result_id == f.scorer_result.id)).query_review?
    refute Enum.any?(context.results, &(&1.hole_result_id == other.scorer_result.id))
    refute inspect(context) =~ "staff-only query detail"
  end

  test "players cannot read another populated group in the same event and round" do
    f = fixture!()
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)

    assert {:ok, group_b} =
             Competition.create_playing_group(f.event.id, f.round.id, actor: f.admin)

    assert {:ok, _} =
             AssignPlayingGroupStart.run(
               f.admin,
               f.event.id,
               f.round.id,
               group_b.id,
               f.start_hole.id,
               2
             )

    entries_b = PaperRecoveryFixtures.add_player_entries_to_group!(f, group_b, 2)
    verifier_b = Enum.at(entries_b, 1)

    assert {:ok, _} =
             Competition.assign_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               group_b.id,
               verifier_b.id
             )

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, %{grant: grant_b}} =
             Accounts.issue_player_access(f.admin, f.event.id, verifier_b.player_id)

    assert {:ok, _} =
             Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: group_b.id,
               round_hole_id: f.start_hole.id,
               expected_group_score_revision: 0,
               captured_at: DateTime.utc_now(),
               results:
                 Enum.map(
                   entries_b,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 5}
                 )
             })

    group_a_results = Enum.map(f.entries, &result!(&1.id).id) |> MapSet.new()
    group_b_results = Enum.map(entries_b, &result!(&1.id).id) |> MapSet.new()
    assert MapSet.size(group_a_results) == 2
    assert MapSet.size(group_b_results) == 2
    assert MapSet.disjoint?(group_a_results, group_b_results)

    assert {:error, :not_authorized} =
             Scoring.load_player_verification_context(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               group_b.id
             )

    assert {:ok, context_a} = load(f, f.verifier_grant)

    assert {:ok, context_b} =
             Scoring.load_player_verification_context(grant_b, f.event.id, f.round.id, group_b.id)

    assert MapSet.new(context_a.results, & &1.hole_result_id) == group_a_results
    assert MapSet.new(context_b.results, & &1.hole_result_id) == group_b_results
  end

  test "a correction exposes pending current evidence and superseded historical evidence" do
    f = fixture!(true)

    assert {:ok, _} =
             Scoring.verify_hole_result(
               f.verifier_grant,
               f.event.id,
               f.round.id,
               command(f, f.scorer_result, f.verifier_assignment)
             )

    assert {:ok, _} =
             Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result.id,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "count correction"
             })

    assert {:ok, context} = load(f, f.verifier_grant)
    result = Enum.find(context.results, &(&1.hole_result_id == f.scorer_result.id))
    assert result.revision == 2
    assert result.verification_status == :pending
    assert result.historical_verification_status == :superseded
    assert result.actionable?
  end

  defp command(f, result, assignment),
    do: %{
      playing_group_id: f.group.id,
      hole_result_id: result.id,
      hole_result_revision: result.revision,
      role_assignment_id: assignment.id,
      role_assignment_version: assignment.assignment_version
    }

  defp load(f, grant),
    do: Scoring.load_player_verification_context(grant, f.event.id, f.round.id, f.group.id)

  defp fixture!(with_side? \\ false, count \\ 2) do
    f = PaperRecoveryFixtures.setup_submit_fixture!(count)
    [scorer, verifier | _] = f.entries
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)

    if with_side? do
      assert {:ok, side} =
               Competition.create_competition_side(
                 f.admin,
                 f.event.id,
                 f.round.id,
                 f.competition.id,
                 :partnership
               )

      assert {:ok, _} =
               Competition.set_side_membership(
                 f.admin,
                 f.event.id,
                 f.round.id,
                 f.competition.id,
                 side.id,
                 Enum.map(f.entries, & &1.id)
               )
    end

    assert {:ok, assignment} =
             Competition.assign_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               verifier.id
             )

    scorer_assignment =
      GroupRoleAssignment
      |> Ash.Query.filter(
        playing_group_id == ^f.group.id and role == :primary_scorer and state == :active
      )
      |> Ash.read_one!(authorize?: false)

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, %{grant: scorer_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, scorer.player_id)

    assert {:ok, %{grant: verifier_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, verifier.player_id)

    submission = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: f.group.id,
      round_hole_id: f.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }

    assert {:ok, _} = Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, submission)

    Map.merge(f, %{
      scorer_grant: scorer_grant,
      verifier_grant: verifier_grant,
      scorer_assignment: scorer_assignment,
      verifier_assignment: assignment,
      scorer_result: result!(scorer.id),
      verifier_result: result!(verifier.id)
    })
  end

  defp result!(entry_id) do
    card =
      Scorecard
      |> Ash.Query.filter(round_entry_id == ^entry_id)
      |> Ash.read_one!(authorize?: false)

    HoleResult |> Ash.Query.filter(scorecard_id == ^card.id) |> Ash.read_one!(authorize?: false)
  end
end
