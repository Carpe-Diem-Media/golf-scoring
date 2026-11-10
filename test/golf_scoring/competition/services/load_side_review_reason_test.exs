defmodule GolfScoring.Competition.Services.LoadSideReviewReasonTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.LoadSideReviewReason
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "authorizes current staff and rejects cross-event, invalid and excluded scopes" do
    f = fixture!()
    other = fixture!()

    assert {:ok,
            %{status: :no_correction_blocker, blockers: [], other_blockers_evaluated?: false}} =
             read(f)

    for {actor, event, round, result} <- [
          {nil, f.event.id, f.round.id, f.result_id},
          {other.admin, f.event.id, f.round.id, f.result_id},
          {f.admin, other.event.id, other.round.id, other.result_id},
          {f.admin, f.event.id, other.round.id, f.result_id},
          {f.admin, f.event.id, f.round.id, other.result_id}
        ] do
      assert {:error, :not_found_or_forbidden} =
               LoadSideReviewReason.run(actor, event, round, result)
    end

    Repo.query!(
      "UPDATE event_staff_assignments SET role = 'competition_manager' WHERE staff_user_id = $1::uuid AND event_id = $2::uuid",
      [uuid(f.admin.id), uuid(f.event.id)]
    )

    assert {:ok, _} = read(f)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'revoked' WHERE staff_user_id = $1::uuid AND event_id = $2::uuid",
      [uuid(f.admin.id), uuid(f.event.id)]
    )

    assert {:error, :not_found_or_forbidden} = read(f)

    Repo.query!(
      "UPDATE event_staff_assignments SET status = 'active' WHERE staff_user_id = $1::uuid AND event_id = $2::uuid",
      [uuid(f.admin.id), uuid(f.event.id)]
    )

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, :not_found_or_forbidden} = read(f)
  end

  test "reports only current correction revisions with pending verification and does not write" do
    f = fixture!()
    submit!(f)
    [entry | _] = f.entries

    [[hole, card, rev]] =
      Repo.query!(
        "SELECT hr.id::text, sc.id::text, hr.revision FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid AND hr.round_hole_id = $2::uuid",
        [uuid(entry.id), uuid(f.start_hole.id)]
      ).rows

    verification!(f, hole, card, entry.id, 1)
    assert {:ok, %{status: :no_correction_blocker}} = read(f)

    Repo.query!(
      "UPDATE competition_side_results SET state = 'review_required' WHERE id = $1::uuid",
      [uuid(f.result_id)]
    )

    assert {:ok,
            %{
              status: :review_reason_not_evaluated,
              blockers: [],
              other_blockers_evaluated?: false
            }} = read(f)

    Repo.query!("UPDATE competition_side_results SET state = 'provisional' WHERE id = $1::uuid", [
      uuid(f.result_id)
    ])

    correction!(f, hole, card)
    verification!(f, hole, card, entry.id, 2)

    before =
      Repo.query!("SELECT state, updated_at FROM competition_side_results WHERE id = $1::uuid", [
        uuid(f.result_id)
      ]).rows

    assert {:ok,
            %{
              status: :corrected_score_awaiting_verification,
              blockers: [%{hole_result_id: ^hole, revision: 2}],
              other_blockers_evaluated?: false
            }} = read(f)

    Repo.query!(
      "UPDATE score_verifications SET playing_group_id = $2::uuid WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
      [uuid(hole), uuid(f.other_group.id)]
    )

    assert {:ok, %{status: :no_correction_blocker, blockers: []}} = read(f)

    Repo.query!(
      "UPDATE score_verifications SET playing_group_id = $2::uuid WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
      [uuid(hole), uuid(f.group.id)]
    )

    assert {:ok, %{status: :no_correction_blocker, blockers: []}} =
             LoadSideReviewReason.run(f.admin, f.event.id, f.round.id, f.other_result_id)

    assert before ==
             Repo.query!(
               "SELECT state, updated_at FROM competition_side_results WHERE id = $1::uuid",
               [uuid(f.result_id)]
             ).rows

    Repo.query!("UPDATE hole_results SET revision = 3 WHERE id = $1::uuid", [uuid(hole)])
    assert {:ok, %{status: :no_correction_blocker}} = read(f)

    Repo.query!("UPDATE hole_results SET revision = $2 WHERE id = $1::uuid", [uuid(hole), rev + 1])

    Repo.query!(
      "UPDATE score_verifications SET status = 'overridden', overridden_by_staff_user_id = $2::uuid, override_reason = 'test' WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
      [uuid(hole), uuid(f.admin.id)]
    )

    Repo.query!(
      "UPDATE competition_side_results SET state = 'review_required' WHERE id = $1::uuid",
      [uuid(f.result_id)]
    )

    assert {:ok,
            %{
              status: :review_reason_not_evaluated,
              blockers: [],
              other_blockers_evaluated?: false
            }} = read(f)

    Repo.query!(
      "UPDATE score_verifications SET status = 'superseded' WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
      [uuid(hole)]
    )

    assert {:ok, %{status: :review_reason_not_evaluated, blockers: []}} = read(f)

    Repo.query!(
      "UPDATE score_verifications SET status = 'verified', overridden_by_staff_user_id = NULL, override_reason = NULL, verifier_round_entry_id = $2::uuid, role_assignment_id = $3::uuid, role_assignment_version = $4 WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
      [
        uuid(hole),
        uuid(Enum.at(f.entries, 1).id),
        uuid(f.verifier.id),
        f.verifier.assignment_version
      ]
    )

    assert {:ok, %{status: :review_reason_not_evaluated, blockers: []}} = read(f)

    Repo.query!("DELETE FROM competition_side_memberships WHERE competition_side_id = $1::uuid", [
      uuid(f.side_id)
    ])

    assert {:error, :not_found_or_forbidden} = read(f)
  end

  test "excluded results do not expose review information" do
    f = fixture!()

    [[excluded_at]] =
      Repo.query!(
        "UPDATE competition_side_results SET state = 'excluded', excluded_by_staff_user_id = $2::uuid, exclusion_reason = 'preplay', excluded_at = (now() AT TIME ZONE 'utc'), excluded_playing_group_id = $3::uuid, excluded_effective_round_hole_id = $4::uuid, excluded_effective_play_index = 0, excluded_preplay_confirmed = true WHERE id = $1::uuid RETURNING excluded_at",
        [uuid(f.result_id), uuid(f.admin.id), uuid(f.group.id), uuid(f.start_hole.id)]
      ).rows

    assert %NaiveDateTime{} = excluded_at
    assert {:error, :not_found_or_forbidden} = read(f)
  end

  test "a corrected entry exposes the same blocker in both competitions and none in an unrelated side" do
    f = fixture!()
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)

    secondary_competition =
      GolfScoring.Competition.RoundCompetition
      |> Ash.Changeset.for_create(:configure_internal, %{
        event_id: f.event.id,
        round_id: f.round.id,
        is_primary: false
      })
      |> Ash.create!(authorize?: false)

    assert secondary_competition.id != f.competition.id

    {:ok, secondary_side} =
      Competition.create_competition_side(
        f.admin,
        f.event.id,
        f.round.id,
        secondary_competition.id,
        :partnership
      )

    {:ok, _} =
      Competition.set_side_membership(
        f.admin,
        f.event.id,
        f.round.id,
        secondary_competition.id,
        secondary_side.id,
        Enum.map(Enum.take(f.entries, 2), & &1.id)
      )

    [[secondary_result_id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [uuid(secondary_side.id)]
      ).rows

    [entry | _] = f.entries

    assert Repo.query!(
             "SELECT round_competition_id::text FROM competition_side_memberships WHERE round_entry_id = $1::uuid ORDER BY round_competition_id",
             [uuid(entry.id)]
           ).rows == Enum.sort([[f.competition.id], [secondary_competition.id]])

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)
    submit!(f)

    [[hole, card]] =
      Repo.query!(
        "SELECT hr.id::text, hr.scorecard_id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid AND hr.round_hole_id = $2::uuid",
        [uuid(entry.id), uuid(f.start_hole.id)]
      ).rows

    correction!(f, hole, card)
    verification!(f, hole, card, entry.id, 2)

    assert {:ok,
            %{
              status: :corrected_score_awaiting_verification,
              blockers: [blocker],
              other_blockers_evaluated?: false
            }} = read(f)

    assert %{hole_result_id: ^hole, revision: 2} = blocker

    assert {:ok,
            %{
              status: :corrected_score_awaiting_verification,
              blockers: [^blocker],
              other_blockers_evaluated?: false
            }} = LoadSideReviewReason.run(f.admin, f.event.id, f.round.id, secondary_result_id)

    assert {:ok,
            %{status: :no_correction_blocker, blockers: [], other_blockers_evaluated?: false}} =
             LoadSideReviewReason.run(f.admin, f.event.id, f.round.id, f.other_result_id)
  end

  defp fixture! do
    f = PaperRecoveryFixtures.setup_submit_fixture!(4)
    PaperRecoveryFixtures.set_round_state!(f.round, :draft)
    {:ok, other_group} = Competition.create_playing_group(f.event.id, f.round.id, actor: f.admin)

    {:ok, side} =
      Competition.create_competition_side(
        f.admin,
        f.event.id,
        f.round.id,
        f.competition.id,
        :partnership
      )

    {:ok, _} =
      Competition.set_side_membership(
        f.admin,
        f.event.id,
        f.round.id,
        f.competition.id,
        side.id,
        Enum.map(Enum.take(f.entries, 2), & &1.id)
      )

    {:ok, other_side} =
      Competition.create_competition_side(
        f.admin,
        f.event.id,
        f.round.id,
        f.competition.id,
        :partnership
      )

    {:ok, _} =
      Competition.set_side_membership(
        f.admin,
        f.event.id,
        f.round.id,
        f.competition.id,
        other_side.id,
        Enum.map(Enum.drop(f.entries, 2), & &1.id)
      )

    {:ok, verifier} =
      Competition.assign_designated_verifier(
        f.admin,
        f.event.id,
        f.round.id,
        f.group.id,
        Enum.at(f.entries, 1).id
      )

    [[id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [uuid(side.id)]
      ).rows

    [[other_id]] =
      Repo.query!(
        "SELECT id::text FROM competition_side_results WHERE competition_side_id = $1::uuid",
        [uuid(other_side.id)]
      ).rows

    PaperRecoveryFixtures.set_round_state!(f.round, :scoring_open)

    Map.merge(f, %{
      result_id: id,
      other_result_id: other_id,
      side_id: side.id,
      verifier: verifier,
      other_group: other_group
    })
  end

  defp submit!(f) do
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
  end

  defp verification!(f, hole, card, entry, revision) do
    Repo.query!(
      "INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id) VALUES ($1::uuid, $2, $3::uuid, $4::uuid, $5::uuid, $6::uuid) ON CONFLICT (hole_result_id, hole_result_revision) DO NOTHING",
      [uuid(hole), revision, uuid(card), uuid(f.round.id), uuid(f.group.id), uuid(entry)]
    )
  end

  defp correction!(f, hole, card) do
    Repo.query!("UPDATE hole_results SET revision = 2 WHERE id = $1::uuid", [uuid(hole)])

    Repo.query!(
      "INSERT INTO score_revisions (hole_result_id, scorecard_id, round_id, actor_staff_user_id, original_revision, resulting_revision, original_outcome, original_gross_strokes, new_outcome, new_gross_strokes, reason) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, 2, 'holed_out', 4, 'holed_out', 5, 'test')",
      [uuid(hole), uuid(card), uuid(f.round.id), uuid(f.admin.id)]
    )
  end

  defp read(f), do: LoadSideReviewReason.run(f.admin, f.event.id, f.round.id, f.result_id)
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
