defmodule GolfScoringWeb.Admin.ScoreQueriesLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
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
