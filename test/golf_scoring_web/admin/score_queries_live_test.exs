defmodule GolfScoringWeb.Admin.ScoreQueriesLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "authorized roles see an empty queue and support is denied", %{conn: conn} do
    f = fixture!()
    conn = authenticate(conn, f.admin.email)

    for role <- ["event_admin", "competition_manager"] do
      role!(f, role, "active")
      {:ok, view, _} = live(conn, path(f))
      assert has_element?(view, "#queries-empty")
    end

    role!(f, "scoring_support", "active")
    {:ok, view, html} = live(conn, path(f))
    assert has_element?(view, "#queries-unavailable")
    refute html =~ "original private reason"
  end

  test "displays distinct states, revision evidence and picked up scores", %{conn: conn} do
    f = fixture!()
    [first, second] = f.holes
    insert_query!(f, first, "open")
    insert_query!(f, second, "escalated")
    insert_query!(f, first, "resolved")
    insert_query!(f, first, "dismissed")

    Repo.query!(
      "UPDATE hole_results SET revision = 2, outcome = 'picked_up', gross_strokes = NULL WHERE id = $1::uuid",
      [uuid(elem(first, 0))]
    )

    for {revision, status} <- [{1, "superseded"}, {2, "overridden"}] do
      Repo.query!(
        """
        INSERT INTO score_verifications (hole_result_id, hole_result_revision, scorecard_id, round_id, playing_group_id, subject_round_entry_id, status, overridden_by_staff_user_id, override_reason)
        SELECT hr.id, $2, sc.id, hr.round_id, $3::uuid, sc.round_entry_id, $4, $5::uuid, 'private override'
        FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE hr.id = $1::uuid
        """,
        [uuid(elem(first, 0)), revision, uuid(f.group.id), status, uuid(f.admin.id)]
      )
    end

    conn = authenticate(conn, f.admin.email)
    {:ok, _view, html} = live(conn, path(f))

    for text <- [
          "Open",
          "Escalated",
          "Resolved",
          "Dismissed",
          "Picked up",
          "original private reason",
          "Query revision: 1",
          "current result revision: 2",
          "Current verification: Pending",
          "Current verification: Overridden",
          "Historical verification: Superseded",
          "Resolution reason: decision"
        ] do
      assert html =~ text
    end

    assert html =~ "earlier result revision"
    refute html =~ "Resolve query"
    refute html =~ "private override"
  end

  test "revocation and suspension clear previously rendered reasons", %{conn: conn} do
    for loss <- [:revoked, :suspended] do
      f = fixture!()
      insert_query!(f, hd(f.holes), "open")
      conn = authenticate(conn, f.admin.email)
      {:ok, view, html} = live(conn, path(f))
      assert html =~ "original private reason"

      if loss == :revoked do
        role!(f, "event_admin", "revoked")
      else
        Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
          uuid(f.admin.id)
        ])
      end

      html = render_click(view, "refresh", %{})
      assert html =~ "Score queries are unavailable"
      refute html =~ "original private reason"
      refute has_element?(view, "#load-more-queries")
    end
  end

  test "load more clears all rows after staff authority is revoked", %{conn: conn} do
    f = fixture!()
    for _ <- 1..55, do: insert_query!(f, hd(f.holes), "resolved")
    conn = authenticate(conn, f.admin.email)
    {:ok, view, html} = live(conn, path(f))
    assert length(query_ids(html)) == 50
    assert has_element?(view, "#load-more-queries")

    role!(f, "event_admin", "revoked")
    html = render_click(view, "load_more", %{"cursor" => "forged"})
    assert has_element?(view, "#queries-unavailable")
    assert query_ids(html) == []
    refute html =~ "original private reason"
    refute has_element?(view, "#load-more-queries")
  end

  test "wrong event and round disclose no reasons", %{conn: conn} do
    f = fixture!()
    other = fixture!()
    insert_query!(other, hd(other.holes), "open")
    conn = authenticate(conn, f.admin.email)
    {:ok, _, html} = live(conn, path(other))
    assert html =~ "Score queries are unavailable"
    refute html =~ "original private reason"

    {:ok, _, html} =
      live(conn, "/admin/events/#{f.event.id}/rounds/#{other.round.id}/score-queries")

    refute html =~ "original private reason"
  end

  test "load more uses the server cursor, preserves all rows, and refresh replaces them", %{
    conn: conn
  } do
    f = fixture!()
    ids = for _ <- 1..55, do: insert_query!(f, hd(f.holes), "resolved")
    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))
    expected = Enum.sort(ids, :desc)
    assert query_ids(render(view)) == Enum.take(expected, 50)
    html = render_click(view, "load_more", %{"cursor" => %{"id" => "forged"}})
    assert query_ids(html) == expected
    for id <- ids, do: assert(html =~ id)
    refute has_element?(view, "#load-more-queries")
    html = render_click(view, "load_more", %{"cursor" => "forged"})
    assert query_ids(html) == expected
    html = render_click(view, "refresh", %{})
    assert query_ids(html) == Enum.take(expected, 50)
  end

  test "terminal decisions require a reason and preserve scoring facts with audit", %{conn: conn} do
    for {initial, decision, target, action} <- [
          {"open", "resolve", "resolved", "resolve_score_query_no_change"},
          {"open", "dismiss", "dismissed", "dismiss_score_query"},
          {"escalated", "resolve", "resolved", "resolve_score_query_no_change"},
          {"escalated", "dismiss", "dismissed", "dismiss_score_query"}
        ] do
      f = fixture!()
      {hole, card} = hd(f.holes)
      id = insert_query!(f, {hole, card}, initial)

      Repo.query!("UPDATE scorecards SET state = 'review_required' WHERE id = $1::uuid", [
        uuid(card)
      ])

      before =
        Repo.query!(
          "SELECT revision, outcome, gross_strokes FROM hole_results WHERE id = $1::uuid",
          [uuid(hole)]
        ).rows

      conn = authenticate(conn, f.admin.email)
      {:ok, view, _} = live(conn, path(f))
      render_click(view, "select_decision", %{"id" => id, "decision" => decision})
      assert has_element?(view, "#decision-form")

      assert render_submit(view, "confirm_decision", %{"decision" => %{"reason" => "  "}}) =~
               "Enter a reason"

      assert render_submit(view, "confirm_decision", %{
               "decision" => %{"reason" => String.duplicate("x", 4097)}
             }) =~
               "Enter a reason"

      assert Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(id)]).rows ==
               [[initial]]

      html =
        render_submit(view, "confirm_decision", %{
          "decision" => %{"reason" => "  reviewed  ", "revision" => "999"}
        })

      assert html =~ "Decision recorded"

      assert Repo.query!(
               "SELECT status, resolution_reason FROM score_queries WHERE id = $1::uuid",
               [uuid(id)]
             ).rows == [[target, "reviewed"]]

      assert Repo.query!(
               "SELECT revision, outcome, gross_strokes FROM hole_results WHERE id = $1::uuid",
               [uuid(hole)]
             ).rows == before

      assert Repo.query!(
               "SELECT count(*) FROM audit_events WHERE target_id = $1::uuid AND action = $2",
               [uuid(id), action]
             ).rows == [[1]]
    end
  end

  test "cancel clears the confirmation and its validation feedback", %{conn: conn} do
    f = fixture!()
    id = insert_query!(f, hd(f.holes), "open")
    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))
    render_click(view, "select_decision", %{"id" => id, "decision" => "dismiss"})

    assert render_submit(view, "confirm_decision", %{"decision" => %{"reason" => " "}}) =~
             "Enter a reason"

    html = render_click(view, "cancel_decision", %{})
    refute has_element?(view, "#decision-form")
    refute html =~ "Enter a reason"

    assert Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(id)]).rows ==
             [["open"]]
  end

  test "forged selections are rejected and stale revisions require review", %{conn: conn} do
    f = fixture!()
    {hole, card} = hd(f.holes)
    id = insert_query!(f, {hole, card}, "open")

    Repo.query!("UPDATE scorecards SET state = 'review_required' WHERE id = $1::uuid", [
      uuid(card)
    ])

    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))

    render_click(view, "select_decision", %{"id" => Ecto.UUID.generate(), "decision" => "dismiss"})

    refute has_element?(view, "#decision-form")
    render_click(view, "select_decision", %{"id" => id, "decision" => "other"})
    refute has_element?(view, "#decision-form")

    render_click(view, "select_decision", %{
      "id" => id,
      "decision" => "dismiss",
      "revision" => "2"
    })

    Repo.query!("UPDATE hole_results SET revision = 2 WHERE id = $1::uuid", [uuid(hole)])

    html =
      render_submit(view, "confirm_decision", %{
        "decision" => %{"reason" => "reviewed", "revision" => "2"}
      })

    assert html =~ "Review the current information"

    assert Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(id)]).rows ==
             [["open"]]

    refute has_element?(view, "#decision-form")
  end

  test "revoked or suspended staff cannot submit a pending decision", %{conn: conn} do
    for loss <- [:revoked, :suspended] do
      f = fixture!()
      {hole, card} = hd(f.holes)
      id = insert_query!(f, {hole, card}, "open")

      Repo.query!("UPDATE scorecards SET state = 'review_required' WHERE id = $1::uuid", [
        uuid(card)
      ])

      conn = authenticate(conn, f.admin.email)
      {:ok, view, _} = live(conn, path(f))
      render_click(view, "select_decision", %{"id" => id, "decision" => "dismiss"})

      if loss == :revoked do
        role!(f, "event_admin", "revoked")
      else
        Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
          uuid(f.admin.id)
        ])
      end

      html = render_submit(view, "confirm_decision", %{"decision" => %{"reason" => "reviewed"}})
      assert html =~ "Score queries are unavailable"
      refute html =~ "original private reason"
      refute has_element?(view, "#decision-form")

      assert Repo.query!("SELECT status FROM score_queries WHERE id = $1::uuid", [uuid(id)]).rows ==
               [["open"]]
    end
  end

  test "a decision already made by another reviewer cannot be repeated", %{conn: conn} do
    f = fixture!()
    {hole, card} = hd(f.holes)
    id = insert_query!(f, {hole, card}, "open")

    Repo.query!("UPDATE scorecards SET state = 'review_required' WHERE id = $1::uuid", [
      uuid(card)
    ])

    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))
    render_click(view, "select_decision", %{"id" => id, "decision" => "dismiss"})

    assert {:ok, _} =
             Scoring.resolve_score_query_no_change(f.admin, f.event.id, f.round.id, %{
               score_query_id: id,
               expected_revision: 1,
               reason: "already reviewed"
             })

    html =
      render_submit(view, "confirm_decision", %{"decision" => %{"reason" => "second decision"}})

    assert html =~ "Review the current information"

    assert Repo.query!(
             "SELECT status, resolution_reason FROM score_queries WHERE id = $1::uuid",
             [uuid(id)]
           ).rows == [["resolved", "already reviewed"]]

    refute has_element?(view, "#decision-form")
  end

  test "correction resolves current queries and renews verification with audit", %{conn: conn} do
    for status <- [:open, :escalated] do
      f = correction_fixture!(status)
      conn = authenticate(conn, f.admin.email)
      {:ok, view, _} = live(conn, path(f))
      render_click(view, "select_decision", %{"id" => f.query_id, "decision" => "correct"})
      assert has_element?(view, "#decision-form")

      html =
        render_submit(view, "confirm_decision", %{
          "decision" => %{
            "reason" => "correct count",
            "new_gross_strokes" => "6",
            "revision" => "999"
          }
        })

      assert html =~ "Score corrected"
      assert html =~ "requires verification"

      assert Repo.query!("SELECT status FROM score_queries WHERE id=$1::uuid", [uuid(f.query_id)]).rows ==
               [["resolved"]]

      assert Repo.query!("SELECT revision, gross_strokes FROM hole_results WHERE id=$1::uuid", [
               uuid(f.hole_id)
             ]).rows == [[2, 6]]

      assert Repo.query!(
               "SELECT original_revision, resulting_revision, source_query_id::text FROM score_revisions WHERE hole_result_id=$1::uuid",
               [uuid(f.hole_id)]
             ).rows == [[1, 2, f.query_id]]

      assert Repo.query!(
               "SELECT hole_result_revision, status FROM score_verifications WHERE hole_result_id=$1::uuid ORDER BY hole_result_revision",
               [uuid(f.hole_id)]
             ).rows == [[1, "superseded"], [2, "pending"]]

      assert Repo.query!(
               "SELECT action FROM audit_events WHERE (target_id=$1::uuid OR target_id=$2::uuid) AND action IN ('correct_hole_result','resolve_score_query_with_correction') ORDER BY action",
               [uuid(f.hole_id), uuid(f.query_id)]
             ).rows == [["correct_hole_result"], ["resolve_score_query_with_correction"]]

      assert Repo.query!("SELECT state FROM scorecards WHERE id=$1::uuid", [uuid(f.card_id)]).rows ==
               [["review_required"]]

      assert Repo.query!(
               "SELECT state FROM competition_side_results WHERE competition_side_id=$1::uuid",
               [uuid(f.side_id)]
             ).rows == [["review_required"]]
    end
  end

  test "correction rejects invalid values and forged or stale decisions", %{conn: conn} do
    f = correction_fixture!(:open)
    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))

    render_click(view, "select_decision", %{"id" => Ecto.UUID.generate(), "decision" => "correct"})

    refute has_element?(view, "#decision-form")
    render_click(view, "select_decision", %{"id" => f.query_id, "decision" => "correct"})

    for value <- ["", "0", "-1", "1.5", "2147483648", "4", "1x"] do
      html =
        render_submit(view, "confirm_decision", %{
          "decision" => %{"reason" => "reviewed", "new_gross_strokes" => value}
        })

      assert html =~ "Enter a different positive whole score"
    end

    assert Repo.query!("SELECT revision, gross_strokes FROM hole_results WHERE id=$1::uuid", [
             uuid(f.hole_id)
           ]).rows == [[1, 4]]

    assert {:ok, _} =
             Scoring.resolve_score_query_with_correction(f.admin, f.event.id, f.round.id, %{
               score_query_id: f.query_id,
               expected_revision: 1,
               new_gross_strokes: 5,
               reason: "another reviewer"
             })

    html =
      render_submit(view, "confirm_decision", %{
        "decision" => %{"reason" => "reviewed", "new_gross_strokes" => "6", "revision" => "2"}
      })

    assert html =~ "Review the current information"

    assert Repo.query!("SELECT revision, gross_strokes FROM hole_results WHERE id=$1::uuid", [
             uuid(f.hole_id)
           ]).rows == [[2, 5]]
  end

  test "picked-up and stale queries cannot select a correction", %{conn: conn} do
    f = fixture!()
    {hole, card} = hd(f.holes)

    Repo.query!(
      "UPDATE hole_results SET outcome='picked_up', gross_strokes=NULL WHERE id=$1::uuid",
      [uuid(hole)]
    )

    id = insert_query!(f, {hole, card}, "open")
    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))
    refute has_element?(view, "[phx-value-decision='correct']")
    render_click(view, "select_decision", %{"id" => id, "decision" => "correct"})
    refute has_element?(view, "#decision-form")

    Repo.query!(
      "UPDATE hole_results SET outcome='holed_out', gross_strokes=4, revision=2 WHERE id=$1::uuid",
      [uuid(hole)]
    )

    render_click(view, "refresh", %{})
    refute has_element?(view, "[phx-value-decision='correct']")
    render_click(view, "select_decision", %{"id" => id, "decision" => "correct"})
    refute has_element?(view, "#decision-form")
  end

  test "cross-event query selection is rejected", %{conn: conn} do
    f = correction_fixture!(:open)
    other = correction_fixture!(:open)
    conn = authenticate(conn, f.admin.email)
    {:ok, view, _} = live(conn, path(f))
    render_click(view, "select_decision", %{"id" => other.query_id, "decision" => "correct"})
    refute has_element?(view, "#decision-form")

    assert Repo.query!("SELECT revision, gross_strokes FROM hole_results WHERE id=$1::uuid", [
             uuid(other.hole_id)
           ]).rows == [[1, 4]]
  end

  test "lost staff authority cannot commit a selected correction", %{conn: conn} do
    for loss <- [:revoked, :suspended] do
      f = correction_fixture!(:open)
      conn = authenticate(conn, f.admin.email)
      {:ok, view, _} = live(conn, path(f))
      render_click(view, "select_decision", %{"id" => f.query_id, "decision" => "correct"})

      if loss == :revoked do
        role!(f, "event_admin", "revoked")
      else
        Repo.query!("UPDATE staff_users SET status='suspended' WHERE id=$1::uuid", [
          uuid(f.admin.id)
        ])
      end

      html =
        render_submit(view, "confirm_decision", %{
          "decision" => %{"reason" => "correct count", "new_gross_strokes" => "6"}
        })

      assert html =~ "Score queries are unavailable"
      refute has_element?(view, "#decision-form")

      assert Repo.query!("SELECT revision, gross_strokes FROM hole_results WHERE id=$1::uuid", [
               uuid(f.hole_id)
             ]).rows == [[1, 4]]

      assert Repo.query!("SELECT status FROM score_queries WHERE id=$1::uuid", [uuid(f.query_id)]).rows ==
               [["open"]]
    end
  end

  defp correction_fixture!(status) do
    f = Fixtures.setup_submit_fixture!(2)
    Fixtures.set_round_state!(f.round, :draft)

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
        Enum.map(f.entries, & &1.id)
      )

    {:ok, assignment} =
      Competition.assign_designated_verifier(
        f.admin,
        f.event.id,
        f.round.id,
        f.group.id,
        Enum.at(f.entries, 1).id
      )

    Fixtures.set_round_state!(f.round, :scoring_open)

    {:ok, _} =
      Scoring.submit_group_hole(f.admin, f.event.id, f.round.id, %{
        client_submission_id: Ecto.UUID.generate(),
        playing_group_id: f.group.id,
        round_hole_id: f.start_hole.id,
        expected_group_score_revision: 0,
        captured_at: DateTime.utc_now(),
        results:
          Enum.map(f.entries, &%{round_entry_id: &1.id, outcome: :holed_out, gross_strokes: 4})
      })

    [[hole, card]] =
      Repo.query!(
        "SELECT hr.id::text, hr.scorecard_id::text FROM hole_results hr JOIN scorecards sc ON sc.id=hr.scorecard_id WHERE sc.round_entry_id=$1::uuid AND hr.round_hole_id=$2::uuid",
        [uuid(hd(f.entries).id), uuid(f.start_hole.id)]
      ).rows

    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(f.admin, f.event.id, Enum.at(f.entries, 1).player_id)

    {:ok, _} =
      Scoring.verify_hole_result(grant, f.event.id, f.round.id, %{
        playing_group_id: f.group.id,
        hole_result_id: hole,
        hole_result_revision: 1,
        role_assignment_id: assignment.id,
        role_assignment_version: assignment.assignment_version
      })

    {:ok, opened} =
      Scoring.query_hole_result(f.admin, f.event.id, f.round.id, %{
        hole_result_id: hole,
        expected_revision: 1,
        reason: "score query"
      })

    if status == :escalated do
      {:ok, _} =
        Scoring.escalate_score_query(f.admin, f.event.id, f.round.id, %{
          score_query_id: opened.score_query.id,
          expected_revision: 1,
          reason: "escalated"
        })
    end

    Map.merge(f, %{
      hole_id: hole,
      card_id: card,
      query_id: opened.score_query.id,
      side_id: side.id
    })
  end

  defp query_ids(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#score-queries > li[id]")
    |> LazyHTML.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "queries-", ""))
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

    holes =
      Repo.query!(
        "SELECT id::text, scorecard_id::text FROM hole_results WHERE round_id = $1::uuid ORDER BY id",
        [uuid(f.round.id)]
      ).rows
      |> Enum.map(&List.to_tuple/1)

    Map.put(f, :holes, holes)
  end

  defp insert_query!(f, {hole, card}, status) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO score_queries (hole_result_id, scorecard_id, round_id, hole_result_revision, status, reason, requested_by_staff_user_id, resolution_reason, resolved_at, resolved_by_staff_user_id, inserted_at)
        VALUES ($1::uuid, $2::uuid, $3::uuid, 1, $4, 'original private reason', $5::uuid,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN 'decision' END,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN now() END,
          CASE WHEN $4 IN ('resolved', 'dismissed') THEN $5::uuid END, timestamp '2026-01-01')
        RETURNING id::text
        """,
        [uuid(hole), uuid(card), uuid(f.round.id), status, uuid(f.admin.id)]
      ).rows

    id
  end

  defp role!(f, role, status),
    do:
      Repo.query!(
        "UPDATE event_staff_assignments SET role=$2, status=$3 WHERE event_id=$1::uuid AND staff_user_id=$4::uuid",
        [uuid(f.event.id), role, status, uuid(f.admin.id)]
      )

  defp authenticate(conn, email) do
    {:ok, view, _} = live(conn, "/admin/sign-in")

    form =
      form(view, "#staffuser-password-sign-in-with-password", %{
        "staffuser" => %{
          "email" => to_string(email),
          "password" => "GLS-34 synthetic staff passphrase 2026"
        }
      })

    render_submit(form)
    follow_trigger_action(form, conn)
  end

  defp path(f), do: "/admin/events/#{f.event.id}/rounds/#{f.round.id}/score-queries"
  defp uuid(id), do: Ecto.UUID.dump!(id)
end
