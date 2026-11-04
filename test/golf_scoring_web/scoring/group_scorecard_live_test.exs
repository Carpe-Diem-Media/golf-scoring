defmodule GolfScoringWeb.Scoring.GroupScorecardLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.HoleResult
  alias GolfScoring.Scoring.HoleSubmission
  alias GolfScoring.Scoring.Scorecard
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoringWeb.Player.Session

  setup do
    Process.put(:gls34_prefix, "gls72-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    :ok
  end

  for player_count <- [2, 3, 4] do
    @tag player_count: player_count
    test "renders and submits a complete #{player_count}-player hole", %{
      conn: conn,
      player_count: player_count
    } do
      setup = PaperRecoveryFixtures.setup_submit_fixture!(player_count)
      {view, html} = open_scorecard!(conn, setup)

      assert html =~ "#{player_count} golfers"
      assert html =~ "White tee, Men rating"
      refute html =~ "White · Men"
      assert has_element?(view, "#group-scorecard")
      assert has_element?(view, "#event-round-context", "Event scorecard")
      assert has_element?(view, "#course-context", setup.course.name)
      assert has_element?(view, "#group-identity", "Group 1A")
      assert has_element?(view, "#current-hole", "Hole 1")
      assert has_element?(view, "#starting-hole", "Starting hole 1A")
      assert has_element?(view, "#holes-remaining", "18 remaining")
      refute html =~ "btn-primary"
      refute html =~ "input-bordered"
      refute html =~ "select-bordered"
      refute html =~ "progress-primary"

      for index <- 0..(player_count - 1) do
        assert has_element?(view, "#scorecard-player-#{index}")
      end

      html = render_submit(view, "submit_hole", hole_params(setup, 0, hd(setup.route).id))

      assert html =~ "Hole saved"
      assert has_element?(view, "#current-hole", "Hole 2")
      assert has_element?(view, "#holes-remaining", "17 remaining")
      assert length(hole_results(setup)) == player_count
      assert length(hole_submissions(setup)) == 1
      assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 1
    end
  end

  test "uses the shotgun starting hole in the group header", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.set_round_state!(setup.round, :draft)

    {:ok, group_b} =
      GolfScoring.Competition.create_playing_group(setup.event.id, setup.round.id,
        actor: setup.admin
      )

    start_hole_b = Enum.at(setup.route, 9)

    assert {:ok, _} =
             AssignPlayingGroupStart.run(
               setup.admin,
               setup.event.id,
               setup.round.id,
               group_b.id,
               start_hole_b.id,
               1
             )

    entries_b = PaperRecoveryFixtures.add_player_entries_to_group!(setup, group_b, 2)
    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_open)
    group_b_setup = %{setup | group: group_b, entries: entries_b, start_hole: start_hole_b}

    {view, html} = open_scorecard!(conn, group_b_setup, hd(entries_b))

    assert has_element?(view, "#group-identity", "Group 10A")
    assert has_element?(view, "#starting-hole", "Starting hole 10A")
    refute html =~ "Group A"
  end

  test "uses frozen hole and handicap facts with the existing score calculators", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    [first_hole, seventh_hole] = [Enum.at(setup.route, 0), Enum.at(setup.route, 6)]

    Repo.query!(
      """
      UPDATE round_tee_hole_snapshots
      SET par = CASE WHEN round_hole_id = $2::uuid THEN 5 ELSE par END,
          stroke_index = CASE
            WHEN round_hole_id = $2::uuid THEN 7
            WHEN round_hole_id = $3::uuid THEN 1
            ELSE stroke_index
          END,
          distance_m = CASE WHEN round_hole_id = $2::uuid THEN 432 ELSE distance_m END
      WHERE round_tee_profile_snapshot_id = $1::uuid
      """,
      [
        Ecto.UUID.dump!(setup.tee_snapshot.id),
        Ecto.UUID.dump!(first_hole.id),
        Ecto.UUID.dump!(seventh_hole.id)
      ]
    )

    Repo.query!(
      "UPDATE round_tee_profile_snapshots SET total_par = 73 WHERE id = $1::uuid",
      [Ecto.UUID.dump!(setup.tee_snapshot.id)]
    )

    assert [[5, 7, 432]] =
             Repo.query!(
               """
               SELECT par::int, stroke_index::int, distance_m::int
               FROM round_tee_hole_snapshots
               WHERE round_tee_profile_snapshot_id = $1::uuid AND round_hole_id = $2::uuid
               """,
               [Ecto.UUID.dump!(setup.tee_snapshot.id), Ecto.UUID.dump!(first_hole.id)]
             ).rows

    {view, html} = open_scorecard!(conn, setup)

    assert has_element?(view, "#scorecard-par-0", "Par 5")
    assert has_element?(view, "#scorecard-stroke-index-0", "7")
    assert html =~ "Stroke Index"
    assert html =~ "432 m"
    assert html =~ "Handicap index"
    assert html =~ "10.0"
    assert html =~ "Playing handicap"
    assert html =~ "1 stroke received"

    params = hole_params(setup, 0, first_hole.id, %{0 => %{"gross_strokes" => "5"}})
    html = render_change(view, "update_results", params)

    assert html =~ "Handicap adjusted 4"
    assert html =~ "Stableford 3"

    html = render_submit(view, "submit_hole", params)

    assert html =~ "Hole saved"
    assert length(hole_results(setup)) == 2
  end

  test "does not submit or advance while one golfer has no resolved outcome", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(3)
    {view, _html} = open_scorecard!(conn, setup)

    params =
      hole_params(setup, 0, hd(setup.route).id, %{2 => %{"outcome" => "", "gross_strokes" => ""}})

    _html = render_submit(view, "submit_hole", params)

    assert has_element?(
             view,
             "#scorecard-feedback",
             "Complete every golfer's result before submitting."
           )

    assert has_element?(view, "#current-hole", "Hole 1")
    assert hole_results(setup) == []
    assert hole_submissions(setup) == []
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 0
  end

  test "pickup becomes available only when the existing policy allows no points", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    {view, _html} = open_scorecard!(conn, setup)
    hole_id = hd(setup.route).id

    not_yet_eligible =
      hole_params(setup, 0, hole_id, %{
        0 => %{"outcome" => "", "gross_strokes" => "", "strokes_taken" => "5"}
      })

    html = render_change(view, "update_results", not_yet_eligible)
    refute html =~ "Picked up, no points"

    eligible =
      hole_params(setup, 0, hole_id, %{
        0 => %{"outcome" => "", "gross_strokes" => "", "strokes_taken" => "6"}
      })

    html = render_change(view, "update_results", eligible)
    assert html =~ "Picked up, no points"

    picked_up =
      hole_params(setup, 0, hole_id, %{
        0 => %{
          "outcome" => "picked_up",
          "gross_strokes" => "",
          "strokes_taken" => "6"
        }
      })

    html = render_submit(view, "submit_hole", picked_up)

    assert html =~ "Hole saved"

    card =
      Scorecard
      |> Ash.Query.filter(round_entry_id == ^hd(setup.entries).id)
      |> Ash.read_one!(authorize?: false)

    picked_up_result = Enum.find(hole_results(setup), &(&1.scorecard_id == card.id))

    assert picked_up_result.outcome == :picked_up
    assert picked_up_result.gross_strokes == nil
  end

  test "an accepted receipt advances once even if the old form is submitted again", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    {view, _html} = open_scorecard!(conn, setup)
    old_params = hole_params(setup, 0, hd(setup.route).id)

    render_submit(view, "submit_hole", old_params)
    assert has_element?(view, "#current-hole", "Hole 2")

    html = render_submit(view, "submit_hole", old_params)

    assert html =~ "This scorecard has moved to a newer hole."
    assert has_element?(view, "#current-hole", "Hole 2")
    assert length(hole_results(setup)) == 2
    assert length(hole_submissions(setup)) == 1
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 1
  end

  test "a second mounted scorecard cannot submit a stale group revision", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    scorer = hd(setup.entries)
    conn = scorer_conn(conn, setup, scorer)
    {view_a, _html} = live!(conn, setup)
    {view_b, _html} = live!(conn, setup)
    stale_params_a = hole_params(setup, 0, hd(setup.route).id)
    stale_params_b = hole_params(setup, 0, hd(setup.route).id)

    render_submit(view_a, "submit_hole", stale_params_a)
    html = render_submit(view_b, "submit_hole", stale_params_b)

    assert html =~ "This scorecard has moved to a newer hole."
    assert has_element?(view_b, "#current-hole", "Hole 2")
    assert length(hole_results(setup)) == 2
    assert length(hole_submissions(setup)) == 1
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 1
  end

  test "shotgun progression follows the physical route through wraparound", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_shotgun_fixture!(14)
    {view, html} = open_scorecard!(conn, setup)

    assert has_element?(view, "#current-hole", "Hole 14")
    assert html =~ "14, 15, 16, 17, 18, 1, 2"

    html =
      Enum.reduce(0..4, html, fn revision, _html ->
        hole = route_hole_at_revision!(setup, revision)
        render_submit(view, "submit_hole", hole_params(setup, revision, hole.id))
      end)

    assert html =~ "5 of 18 holes complete"
    assert has_element?(view, "#holes-remaining", "13 remaining")
    assert has_element?(view, "#current-hole", "Hole 1")
    assert length(hole_results(setup)) == 10
    assert length(hole_submissions(setup)) == 5
  end

  test "a scorer handover invalidates the mounted scorer before any write", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    [old_scorer, new_scorer] = setup.entries
    {old_view, _html} = open_scorecard!(conn, setup, old_scorer)

    assert {:ok, assignment} =
             Competition.handover_primary_scorer(
               setup.admin,
               setup.event.id,
               setup.round.id,
               setup.group.id,
               new_scorer.id
             )

    assert assignment.assignment_version == 2

    html =
      render_submit(
        old_view,
        "submit_hole",
        hole_params(setup, 0, hd(setup.route).id)
      )

    assert has_element?(old_view, "#scorecard-unavailable")
    assert html =~ "The scorer assignment changed. This scorecard is no longer active."
    assert hole_results(setup) == []
    assert hole_submissions(setup) == []

    {new_view, _html} = open_scorecard!(conn, setup, new_scorer)
    html = render_submit(new_view, "submit_hole", hole_params(setup, 0, hd(setup.route).id))

    assert html =~ "Hole saved"
    assert has_element?(new_view, "#current-hole", "Hole 2")
    assert length(hole_results(setup)) == 2
    assert length(hole_submissions(setup)) == 1
  end

  test "a round that is not open cannot mount an active scorecard", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    PaperRecoveryFixtures.set_round_state!(setup.round, :ready)
    {view, html} = open_scorecard!(conn, setup)

    assert has_element?(view, "#scorecard-unavailable")
    assert html =~ "Scoring is unavailable while this round is not open."
    refute has_element?(view, "#scorecard-entry-form")
  end

  test "closing the round after mount rejects the stale form without writes", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    {view, _html} = open_scorecard!(conn, setup)
    PaperRecoveryFixtures.set_round_state!(setup.round, :scoring_closed)

    html = render_submit(view, "submit_hole", hole_params(setup, 0, hd(setup.route).id))

    assert has_element?(view, "#scorecard-unavailable")
    assert html =~ "Scoring is unavailable while this round is not open."
    assert hole_results(setup) == []
    assert hole_submissions(setup) == []
  end

  test "the scorecard response does not expose an unrevealed Mystery rule", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    next_hole = Enum.at(setup.route, 1)
    mystery_setup = Map.put(setup, :start_hole, next_hole)
    mystery = PaperRecoveryFixtures.configure_single_group_mystery!(mystery_setup)
    {view, html} = open_scorecard!(conn, setup)

    refute html =~ "GLS-35 Mystery"
    refute html =~ "best"

    html = render_submit(view, "submit_hole", hole_params(setup, 0, hd(setup.route).id))

    assert html =~ "Hole saved"
    assert has_element?(view, "#current-hole", "Hole 2")
    refute html =~ "GLS-35 Mystery"
    refute html =~ "best"

    assert [[0]] =
             Repo.query!(
               "SELECT count(*)::int FROM mystery_reveals WHERE mystery_hole_rule_id = $1::uuid",
               [Ecto.UUID.dump!(mystery.rule.id)]
             ).rows
  end

  test "the final accepted hole moves the scorecard to group play complete", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    scorer = hd(setup.entries)
    grant_conn = scorer_conn(conn, setup, scorer)

    for revision <- 0..16 do
      hole = route_hole_at_revision!(setup, revision)

      assert {:ok, _receipt} =
               Scoring.submit_group_hole(
                 setup.admin,
                 setup.event.id,
                 setup.round.id,
                 service_command(setup, revision, hole.id)
               )
    end

    {view, _html} = live!(grant_conn, setup)
    final_hole = route_hole_at_revision!(setup, 17)
    html = render_submit(view, "submit_hole", hole_params(setup, 17, final_hole.id))

    assert html =~ "Group play complete"
    assert has_element?(view, "#group-play-complete")
    assert has_element?(view, "#holes-remaining", "0 remaining")
    assert length(hole_results(setup)) == 36
    assert length(hole_submissions(setup)) == 18
    assert Ash.get!(PlayingGroup, setup.group.id, authorize?: false).scoring_revision == 18
  end

  defp open_scorecard!(conn, setup, entry \\ nil) do
    entry = entry || hd(setup.entries)
    conn = scorer_conn(conn, setup, entry)
    live!(conn, setup)
  end

  defp scorer_conn(conn, setup, entry) do
    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, entry.player_id)

    conn
    |> init_test_session(%{})
    |> Session.put_grant_id(grant.id)
  end

  defp live!(conn, setup) do
    {:ok, view, html} = live(conn, scorecard_path(setup))
    {view, html}
  end

  defp scorecard_path(setup) do
    "/player/events/#{setup.event.id}/rounds/#{setup.round.id}/groups/#{setup.group.id}/scorecard"
  end

  defp hole_params(setup, revision, hole_id, updates \\ %{}) do
    results =
      setup.entries
      |> Enum.with_index()
      |> Map.new(fn {entry, index} ->
        result = %{
          "outcome" => "holed_out",
          "gross_strokes" => "4",
          "strokes_taken" => ""
        }

        {entry.id, Map.merge(result, Map.get(updates, index, %{}))}
      end)

    %{
      "scorecard" => %{
        "expected_group_score_revision" => Integer.to_string(revision),
        "round_hole_id" => hole_id,
        "client_submission_id" => Ecto.UUID.generate(),
        "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "results" => results
      }
    }
  end

  defp service_command(setup, revision, hole_id) do
    %{
      client_submission_id: Ecto.UUID.generate(),
      playing_group_id: setup.group.id,
      round_hole_id: hole_id,
      expected_group_score_revision: revision,
      captured_at: DateTime.utc_now(),
      results:
        Enum.map(setup.entries, fn entry ->
          %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: 4}
        end)
    }
  end

  defp route_hole_at_revision!(setup, revision) do
    start_index = Enum.find_index(setup.route, &(&1.id == setup.start_hole.id))
    rotated_route = Enum.drop(setup.route, start_index) ++ Enum.take(setup.route, start_index)
    Enum.at(rotated_route, revision)
  end

  defp hole_results(setup) do
    HoleResult
    |> Ash.Query.filter(round_id == ^setup.round.id)
    |> Ash.read!(authorize?: false)
  end

  defp hole_submissions(setup) do
    HoleSubmission
    |> Ash.Query.filter(round_id == ^setup.round.id)
    |> Ash.read!(authorize?: false)
  end
end
