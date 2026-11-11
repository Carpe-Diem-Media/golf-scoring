defmodule GolfScoring.Scoring.Services.LoadStaffScoreQueryReviewTest do
  use GolfScoring.DataCase, async: false

  alias GolfScoring.Competition
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  test "authorized staff receive an empty page for their round" do
    f = Fixtures.setup_submit_fixture!(2)

    assert {:ok, %{items: [], next_cursor: nil}} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id, [])
  end

  test "only active event admins and competition managers may read the round" do
    f = fixture!()
    insert_query!(f, "open")
    other = fixture!()

    for role <- ["event_admin", "competition_manager"] do
      role!(f, role, "active")
      assert {:ok, %{items: [_]}} = read(f)
    end

    for role <- ["scoring_support", "registration_staff"] do
      role!(f, role, "active")
      assert {:error, :not_found_or_forbidden} = read(f)
    end

    role!(f, "event_admin", "revoked")
    assert {:error, :not_found_or_forbidden} = read(f)
    role!(f, "event_admin", "active")

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    assert {:error, :not_found_or_forbidden} = read(f)

    Repo.query!("UPDATE staff_users SET status = 'active' WHERE id = $1::uuid", [uuid(f.admin.id)])

    assert {:error, :invalid_input} =
             Scoring.load_staff_score_query_review(%{id: f.admin.id}, f.event.id, f.round.id, [])

    assert {:error, :not_found_or_forbidden} =
             Scoring.load_staff_score_query_review(f.admin, other.event.id, other.round.id, [])

    assert {:error, :not_found_or_forbidden} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, other.round.id, [])

    assert {:ok, same_event_round} =
             Competition.create_round(f.event.id, f.course.id, actor: f.admin)

    assert {:ok, %{items: []}} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, same_event_round.id, [])
  end

  test "returns current and stale evidence for all query states and terminal decisions" do
    f = fixture!()
    other = fixture!()
    open_id = insert_query!(f, "open")
    escalated_id = insert_query!(%{f | hole: f.other_hole, card: f.other_card}, "escalated")
    resolved_id = insert_query!(f, "resolved")
    dismissed_id = insert_query!(f, "dismissed")
    insert_query!(other, "resolved")
    Repo.query!("UPDATE hole_results SET revision = 2 WHERE id = $1::uuid", [uuid(f.hole)])

    Repo.query!(
      """
      INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id, status, overridden_by_staff_user_id, override_reason)
      VALUES ($1::uuid, 1, $2::uuid, $3::uuid, $4::uuid, $5::uuid, 'superseded', $6::uuid, 'private override')
      """,
      Enum.map([f.hole, f.card, f.round.id, f.group.id, hd(f.entries).id, f.admin.id], &uuid/1)
    )

    Repo.query!(
      """
      INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id, status, overridden_by_staff_user_id, override_reason)
      VALUES ($1::uuid, 1, $2::uuid, $3::uuid, $4::uuid, $5::uuid, 'overridden', $6::uuid, 'private override')
      """,
      Enum.map(
        [
          f.other_hole,
          f.other_card,
          f.round.id,
          f.group.id,
          Enum.at(f.entries, 1).id,
          f.admin.id
        ],
        &uuid/1
      )
    )

    assert {:ok, %{items: items}} = read(f)

    assert MapSet.new(items, & &1.id) ==
             MapSet.new([open_id, escalated_id, resolved_id, dismissed_id])

    open = Enum.find(items, &(&1.id == open_id))
    assert open.status == :open and open.recorded_revision == 1 and open.current_revision == 2
    assert open.reason == "original reason"
    assert open.stale? and open.verification_status == :pending
    assert open.historical_verification_status == :superseded
    refute inspect(items) =~ "private override"
    escalated = Enum.find(items, &(&1.id == escalated_id))
    assert escalated.status == :escalated
    assert escalated.verification_status == :overridden
    refute escalated.stale?

    for {id, status} <- [{resolved_id, :resolved}, {dismissed_id, :dismissed}] do
      item = Enum.find(items, &(&1.id == id))
      assert item.status == status
      assert item.resolution_reason == "decision"
      assert item.resolved_by_staff_user_id == f.admin.id
      assert item.resolved_at
    end
  end

  test "displays the subject, hole and current recorded result after correction" do
    f = fixture!()
    id = insert_query!(f, "open")

    [[name, hole_number, play_order]] =
      Repo.query!(
        """
        SELECT p.first_name || ' ' || p.surname, rh.display_hole_number, rh.play_order
        FROM hole_results hr
        JOIN scorecards sc ON sc.id = hr.scorecard_id
        JOIN round_entries re ON re.id = sc.round_entry_id
        JOIN players p ON p.id = re.player_id
        JOIN round_holes rh ON rh.id = hr.round_hole_id
        WHERE hr.id = $1::uuid
        """,
        [uuid(f.hole)]
      ).rows

    assert {:ok, %{items: [item]}} = read(f)
    assert item.id == id
    assert item.player_name == name
    assert item.playing_group_id == f.group.id
    assert item.display_hole_number == hole_number
    assert item.play_order == play_order
    assert item.current_outcome == :holed_out
    assert item.current_gross_strokes == 4

    Repo.query!("UPDATE hole_results SET revision = 2, gross_strokes = 6 WHERE id = $1::uuid", [
      uuid(f.hole)
    ])

    assert {:ok, %{items: [corrected]}} = read(f)
    assert corrected.current_revision == 2
    assert corrected.current_gross_strokes == 6
    assert corrected.stale?
  end

  test "reports picked-up results without gross strokes" do
    f = fixture!()
    insert_query!(f, "open")

    Repo.query!(
      "UPDATE hole_results SET outcome = 'picked_up', gross_strokes = NULL WHERE id = $1::uuid",
      [uuid(f.hole)]
    )

    assert {:ok, %{items: [item]}} = read(f)
    assert item.current_outcome == :picked_up
    assert item.current_gross_strokes == nil
  end

  test "keyset pagination is stable for equal timestamps and validates cursors" do
    f = fixture!()
    ids = for _ <- 1..55, do: insert_query!(f, "resolved")
    assert {:ok, first} = read(f)
    assert length(first.items) == 50
    assert first.next_cursor

    assert {:ok, second} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id,
               cursor: first.next_cursor
             )

    assert length(second.items) == 5
    assert second.next_cursor == nil
    all = Enum.map(first.items ++ second.items, & &1.id)
    assert all == Enum.sort(ids, :desc)

    assert {:error, :invalid_input} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id,
               cursor: %{id: "bad", inserted_at: ~N[2026-01-01 00:00:00]}
             )

    assert {:error, :invalid_input} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id, limit: 51)

    assert {:error, :invalid_input} =
             Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id,
               cursor: %{id: hd(ids), inserted_at: %{~N[2026-01-01 00:00:00] | month: 13}}
             )
  end

  defp read(f), do: Scoring.load_staff_score_query_review(f.admin, f.event.id, f.round.id, [])

  defp role!(f, role, status) do
    Repo.query!(
      "UPDATE event_staff_assignments SET role = $2, status = $3 WHERE event_id = $1::uuid AND staff_user_id = $4::uuid",
      [uuid(f.event.id), role, status, uuid(f.admin.id)]
    )
  end

  defp insert_query!(f, status) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, hole_result_revision, status, reason, requested_by_staff_user_id, resolution_reason, resolved_at, resolved_by_staff_user_id, inserted_at)
        VALUES ($1::uuid, $2::uuid, $3::uuid, 1, $4, 'original reason', $5::uuid,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN 'decision' END,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN now() END,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN $5::uuid END, timestamp '2026-01-01')
        RETURNING id::text
        """,
        [uuid(f.hole), uuid(f.card), uuid(f.round.id), status, uuid(f.admin.id)]
      ).rows

    id
  end

  defp fixture! do
    f = Fixtures.setup_submit_fixture!(2)

    assert {:ok, _} =
             Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
               client_submission_id: Ecto.UUID.generate(),
               playing_group_id: f.group.id,
               round_hole_id: f.start_hole.id,
               expected_group_score_revision: 0,
               captured_at: DateTime.utc_now(),
               results:
                 Enum.map(
                   f.entries,
                   &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4}
                 )
             })

    [[hole, card], [other_hole, other_card]] =
      Repo.query!(
        "SELECT hr.id::text, sc.id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE hr.round_id = $1::uuid ORDER BY sc.round_entry_id",
        [uuid(f.round.id)]
      ).rows

    [[entry_id]] =
      Repo.query!("SELECT round_entry_id::text FROM scorecards WHERE id = $1::uuid", [uuid(card)]).rows

    entries = Enum.sort_by(f.entries, &if(&1.id == entry_id, do: 0, else: 1))

    Map.merge(f, %{
      hole: hole,
      card: card,
      other_hole: other_hole,
      other_card: other_card,
      entries: entries
    })
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
