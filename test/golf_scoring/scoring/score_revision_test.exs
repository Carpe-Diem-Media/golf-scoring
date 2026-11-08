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

    attrs = %{
      hole_result_id: result,
      scorecard_id: card,
      round_id: round,
      actor_staff_user_id: staff,
      actor_round_entry_id: nil,
      original_revision: 1,
      resulting_revision: 2,
      original_outcome: "holed_out",
      original_gross_strokes: 4,
      new_outcome: "picked_up",
      new_gross_strokes: nil,
      reason: "correction",
      source_query_id: query
    }

    for invalid <- [
          %{original_revision: 0},
          %{resulting_revision: 3},
          %{original_gross_strokes: nil},
          %{original_outcome: "picked_up"},
          %{new_gross_strokes: 2},
          %{new_outcome: "unknown"},
          %{reason: " "},
          %{actor_staff_user_id: nil},
          %{actor_round_entry_id: player}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               insert_revision(Map.merge(attrs, invalid))
    end

    for invalid <- [
          %{source_query_id: other_query},
          %{original_revision: 2, resulting_revision: 3},
          %{
            actor_staff_user_id: nil,
            actor_round_entry_id: Ecto.UUID.dump!(hd(other.entries).id)
          },
          %{scorecard_id: other_card},
          %{round_id: Ecto.UUID.dump!(other.round.id)}
        ] do
      assert {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} =
               insert_revision(Map.merge(attrs, invalid))
    end

    assert {:ok, _} = insert_revision(attrs)

    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
             insert_revision(attrs)

    assert {:ok, _} =
             insert_revision(
               Map.merge(attrs, %{
                 hole_result_id: other_result,
                 scorecard_id: other_card,
                 source_query_id: nil,
                 actor_staff_user_id: nil,
                 actor_round_entry_id: player,
                 original_outcome: "picked_up",
                 original_gross_strokes: nil,
                 new_outcome: "holed_out",
                 new_gross_strokes: 5
               })
             )
  end

  defp insert_revision(attrs) do
    columns = [
      :hole_result_id,
      :scorecard_id,
      :round_id,
      :actor_staff_user_id,
      :actor_round_entry_id,
      :original_revision,
      :resulting_revision,
      :original_outcome,
      :original_gross_strokes,
      :new_outcome,
      :new_gross_strokes,
      :reason,
      :source_query_id
    ]

    params = Enum.map(columns, &Map.fetch!(attrs, &1))
    placeholders = Enum.map_join(1..length(columns), ", ", &"$#{&1}")

    Repo.query(
      "INSERT INTO score_revisions (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) RETURNING id",
      params,
      mode: :savepoint
    )
  end
end
