defmodule GolfScoring.Scoring.ScoreRevisionTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "revision evidence is registered without update or destroy actions" do
    resource = GolfScoring.Scoring.ScoreRevision
    assert resource in Ash.Domain.Info.resources(Scoring)
    refute Enum.any?(Ash.Resource.Info.actions(resource), &(&1.type in [:update, :destroy]))
  end

  test "database checks revision evidence and scopes its optional query and actor" do
    f = PaperRecoveryFixtures.setup_submit_fixture!(2)
    other = PaperRecoveryFixtures.setup_submit_fixture!(2)

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
    [first, second] = f.entries

    [[result, card]] =
      Repo.query!(
        "SELECT hr.id, hr.scorecard_id FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(first.id)]
      ).rows

    [[other_result, other_card]] =
      Repo.query!(
        "SELECT hr.id, hr.scorecard_id FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(second.id)]
      ).rows

    round = Ecto.UUID.dump!(f.round.id)
    staff = Ecto.UUID.dump!(f.admin.id)
    player = Ecto.UUID.dump!(first.id)

    query_sql =
      "INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, requested_by_staff_user_id, hole_result_revision, reason) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, 'dispute') RETURNING id"

    [[query]] = Repo.query!(query_sql, [result, card, round, staff]).rows
    [[other_query]] = Repo.query!(query_sql, [other_result, other_card, round, staff]).rows

    sql =
      "INSERT INTO score_revisions (hole_result_id, scorecard_id, round_id, actor_staff_user_id, original_revision, resulting_revision, original_outcome, original_gross_strokes, new_outcome, new_gross_strokes, reason, source_query_id) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, 2, 'holed_out', 4, 'picked_up', NULL, 'correction', $5::uuid) RETURNING id"

    args = [result, card, round, staff, query]
    assert {:ok, %{rows: [[id]]}} = Repo.query(sql, args)

    assert {:ok, _} = Repo.query(sql, [other_result, other_card, round, staff, nil])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, args, mode: :savepoint)

    for invalid <- [
          "original_revision = 0",
          "resulting_revision = 3",
          "original_gross_strokes = NULL",
          "original_outcome = 'picked_up'",
          "new_gross_strokes = 2",
          "new_outcome = 'unknown'",
          "reason = ' '",
          "actor_staff_user_id = NULL",
          "actor_round_entry_id = '#{first.id}'::uuid"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query("UPDATE score_revisions SET #{invalid} WHERE id = $1::uuid", [id],
                 mode: :savepoint
               )
    end

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_revisions SET source_query_id = $2::uuid WHERE id = $1::uuid",
               [id, other_query],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_revisions SET original_revision = 2, resulting_revision = 3 WHERE id = $1::uuid",
               [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_revisions SET actor_staff_user_id = NULL, actor_round_entry_id = $2::uuid WHERE id = $1::uuid",
               [id, Ecto.UUID.dump!(hd(other.entries).id)],
               mode: :savepoint
             )

    assert {:ok, _} =
             Repo.query(
               "UPDATE score_revisions SET actor_staff_user_id = NULL, actor_round_entry_id = $2::uuid WHERE id = $1::uuid",
               [id, player]
             )

    assert {:ok, _} =
             Repo.query(
               "UPDATE score_revisions SET original_outcome = 'picked_up', original_gross_strokes = NULL, new_outcome = 'holed_out', new_gross_strokes = 5 WHERE id = $1::uuid",
               [id]
             )
  end
end
