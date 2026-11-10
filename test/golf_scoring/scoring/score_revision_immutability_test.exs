defmodule GolfScoring.Scoring.ScoreRevisionImmutabilityTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures

  test "both immutable guards are installed and always enabled" do
    assert [
             ["score_revisions_immutable_rows", "A", 27],
             ["score_revisions_immutable_truncate", "A", 34]
           ] ==
             Repo.query!("""
             SELECT tgname, tgenabled::text, tgtype::integer
             FROM pg_trigger
             WHERE tgrelid = 'public.score_revisions'::regclass AND NOT tgisinternal
               AND tgname IN ('score_revisions_immutable_rows', 'score_revisions_immutable_truncate')
             ORDER BY tgname
             """).rows
  end

  test "inserted evidence rejects no-op updates, rewrites, deletion and truncation" do
    f = PaperRecoveryFixtures.setup_submit_fixture!(2)

    command = %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: f.group.id,
      round_hole_id: f.start_hole.id,
      expected_group_score_revision: 0,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
    }

    assert {:ok, _} =
             GolfScoring.Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, command)

    [[id]] =
      Repo.query!(
        """
        INSERT INTO score_revisions
          (hole_result_id, scorecard_id, round_id, actor_staff_user_id, original_revision,
           resulting_revision, original_outcome, original_gross_strokes, new_outcome, new_gross_strokes, reason)
        SELECT hr.id, hr.scorecard_id, hr.round_id, $1::uuid, 1, 2, 'holed_out', 4, 'holed_out', 5, 'test evidence'
        FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id
        WHERE sc.round_entry_id = $2::uuid RETURNING id
        """,
        [Ecto.UUID.dump!(f.admin.id), Ecto.UUID.dump!(hd(f.entries).id)]
      ).rows

    before = Repo.query!("SELECT * FROM score_revisions WHERE id = $1::uuid", [id]).rows

    for sql <- [
          "UPDATE public.score_revisions SET reason = reason WHERE id = $1::uuid",
          "UPDATE public.score_revisions SET reason = 'rewritten' WHERE id = $1::uuid",
          "UPDATE public.score_revisions SET original_gross_strokes = 9 WHERE id = $1::uuid",
          "DELETE FROM public.score_revisions WHERE id = $1::uuid"
        ] do
      assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000"}}} =
               Repo.query(sql, [id], mode: :savepoint)

      assert Repo.query!("SELECT * FROM score_revisions WHERE id = $1::uuid", [id]).rows == before
    end

    # Sandbox owns the transaction even if this assertion detects a missing guard.
    assert {:error, %Postgrex.Error{postgres: %{pg_code: "55000"}}} =
             Repo.query("TRUNCATE public.score_revisions", [], mode: :savepoint)

    assert Repo.query!("SELECT * FROM score_revisions WHERE id = $1::uuid", [id]).rows == before
  end
end
