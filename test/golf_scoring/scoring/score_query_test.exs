defmodule GolfScoring.Scoring.ScoreQueryTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "score query is registered without public mutation actions" do
    resource = GolfScoring.Scoring.ScoreQuery
    assert resource in Ash.Domain.Info.resources(Scoring)

    refute Enum.any?(
             Ash.Resource.Info.actions(resource),
             &(&1.public? and &1.type in [:create, :update, :destroy])
           )
  end

  test "database enforces unresolved uniqueness and evidence shape" do
    f = PaperRecoveryFixtures.setup_submit_fixture!(2)

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

    [[result_id, card_id]] =
      Repo.query!(
        "SELECT hr.id, hr.scorecard_id FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid",
        [Ecto.UUID.dump!(hd(f.entries).id)]
      ).rows

    round = Ecto.UUID.dump!(f.round.id)
    staff = Ecto.UUID.dump!(f.admin.id)
    args = [result_id, card_id, round, staff]

    sql =
      "INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, requested_by_staff_user_id, hole_result_revision, reason) VALUES ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 1, 'disputed') RETURNING id"

    assert {:ok, %{rows: [[id]]}} = Repo.query(sql, args)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, args, mode: :savepoint)

    assert {:ok, _} =
             Repo.query("UPDATE score_queries SET status = 'escalated' WHERE id = $1::uuid", [id])

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             Repo.query(sql, args, mode: :savepoint)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET requested_by_round_entry_id = $2::uuid WHERE id = $1::uuid",
               [id, Ecto.UUID.dump!(hd(f.entries).id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE score_queries SET status = 'unknown' WHERE id = $1::uuid", [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE score_queries SET status = 'resolved' WHERE id = $1::uuid", [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET hole_result_revision = 0 WHERE id = $1::uuid",
               [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE score_queries SET reason = ' ' WHERE id = $1::uuid", [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_queries SET scorecard_id = $2::uuid WHERE id = $1::uuid",
               [id, Ecto.UUID.dump!(Ecto.UUID.generate())],
               mode: :savepoint
             )

    player = Ecto.UUID.dump!(hd(f.entries).id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET resolved_by_round_entry_id = $2::uuid WHERE id = $1::uuid",
               [id, player],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET status = 'resolved', resolution_reason = 'agreed', resolved_at = now() WHERE id = $1::uuid",
               [id],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET status = 'resolved', resolved_by_round_entry_id = $2::uuid, resolved_by_staff_user_id = $3::uuid, resolution_reason = 'agreed', resolved_at = now() WHERE id = $1::uuid",
               [id, player, staff],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               "UPDATE score_queries SET status = 'dismissed', resolved_by_round_entry_id = $2::uuid, resolution_reason = 'dismissed', resolved_at = now() WHERE id = $1::uuid",
               [id, player],
               mode: :savepoint
             )

    other = PaperRecoveryFixtures.setup_submit_fixture!(2)
    other_player = Ecto.UUID.dump!(hd(other.entries).id)

    assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
             Repo.query(
               "UPDATE score_queries SET status = 'resolved', resolved_by_round_entry_id = $2::uuid, resolution_reason = 'agreed', resolved_at = now() WHERE id = $1::uuid",
               [id, other_player],
               mode: :savepoint
             )

    assert {:ok, _} =
             Repo.query(
               "UPDATE score_queries SET status = 'resolved', resolved_by_round_entry_id = $2::uuid, resolution_reason = 'agreed', resolved_at = now() WHERE id = $1::uuid",
               [id, player]
             )

    assert {:ok, _} =
             Repo.query(
               "UPDATE score_queries SET status = 'resolved', resolved_by_round_entry_id = NULL, resolved_by_staff_user_id = $2::uuid, resolution_reason = 'confirmed', resolved_at = now() WHERE id = $1::uuid",
               [id, staff]
             )

    assert {:ok, %{rows: [[second_id]]}} = Repo.query(sql, args)

    assert {:ok, _} =
             Repo.query(
               "UPDATE score_queries SET status = 'dismissed', resolved_by_staff_user_id = $2::uuid, resolution_reason = 'dismissed', resolved_at = now() WHERE id = $1::uuid",
               [second_id, staff]
             )
  end
end
