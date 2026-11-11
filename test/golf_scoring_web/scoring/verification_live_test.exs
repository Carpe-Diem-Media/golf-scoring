defmodule GolfScoringWeb.Scoring.VerificationLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures
  alias GolfScoringWeb.Player.Session

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    assert Repo.query!("SELECT current_database(), current_user").rows == [
             ["golf_scoring_test", "golf_scoring_test"]
           ]

    :ok
  end

  test "designated verifier reviews and verifies another player's result", %{conn: conn} do
    f = fixture!()
    {view, html} = open!(conn, f, f.verifier_grant)
    assert html =~ "Hole 1"
    assert has_element?(view, "#verify-#{f.scorer_result}")
    refute has_element?(view, "#verify-#{f.verifier_result}")
    assert view |> element("#verify-#{f.scorer_result}") |> render_click() =~ "Verified"
  end

  test "primary scorer may verify the designated verifier, not themselves or a third player", %{
    conn: conn
  } do
    f = fixture!(3)
    {view, _} = open!(conn, f, f.scorer_grant)
    assert has_element?(view, "#verify-#{f.verifier_result}")
    refute has_element?(view, "#verify-#{f.scorer_result}")
    assert length(Regex.scan(~r/id="verify-/, render(view))) == 1
    assert view |> element("#verify-#{f.verifier_result}") |> render_click() =~ "Verified"
  end

  test "forged target and route cannot reveal or certify another result", %{conn: conn} do
    f = fixture!()
    other = fixture!()
    {view, _} = open!(conn, f, f.verifier_grant)

    assert render_hook(view, "verify", %{"id" => other.scorer_result}) =~
             "not available to verify"

    assert Repo.query!(
             "SELECT count(*) FROM score_verifications WHERE hole_result_id = $1::uuid",
             [uuid(other.scorer_result)]
           ).rows == [[0]]

    forged = %{f | group: other.group}
    {wrong_view, html} = open!(conn, forged, f.verifier_grant)
    assert has_element?(wrong_view, "#verification-unavailable")
    refute html =~ other.scorer_result
  end

  test "revocation or expiration after render clears results", %{conn: conn} do
    for kind <- [:revoked, :expired] do
      f = fixture!()
      {view, _} = open!(conn, f, f.verifier_grant)

      if kind == :revoked do
        assert {:ok, _} =
                 Accounts.revoke_player_access(
                   f.admin,
                   f.event.id,
                   Enum.at(f.entries, 1).player_id
                 )
      else
        Repo.query!(
          "UPDATE player_access_grants SET expires_at = now() - interval '1 second' WHERE id = $1::uuid",
          [uuid(f.verifier_grant.id)]
        )
      end

      html = render_click(view, "verify", %{"id" => f.scorer_result})
      assert html =~ "Verification unavailable"
      refute html =~ f.scorer_result
      refute has_element?(view, "#verification-results")
    end
  end

  test "an invalid target also clears the view when authority is revoked", %{conn: conn} do
    f = fixture!()
    {view, _} = open!(conn, f, f.verifier_grant)

    assert {:ok, _} =
             Accounts.revoke_player_access(f.admin, f.event.id, Enum.at(f.entries, 1).player_id)

    html = render_hook(view, "verify", %{"id" => Ecto.UUID.generate()})
    assert html =~ "Verification unavailable"
    refute html =~ f.scorer_result
  end

  test "handover after render invalidates the old verifier", %{conn: conn} do
    f = fixture!(3)
    {view, _} = open!(conn, f, f.verifier_grant)

    assert {:ok, _} =
             Competition.handover_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               f.group.id,
               Enum.at(f.entries, 2).id
             )

    html = render_click(view, "verify", %{"id" => f.scorer_result})
    assert html =~ "Verification unavailable"
    refute html =~ f.scorer_result
  end

  test "a correction after render requires reviewing the new revision before verification", %{
    conn: conn
  } do
    f = fixture!(2, true)
    {view, html} = open!(conn, f, f.verifier_grant)
    assert html =~ "revision 1"

    assert {:ok, _} =
             Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "correct count"
             })

    html = render_hook(view, "verify", %{"id" => f.scorer_result, "revision" => "2"})
    assert html =~ "revision 2"
    assert html =~ "Review the current information"

    assert Repo.query!(
             "SELECT status FROM score_verifications WHERE hole_result_id = $1::uuid AND hole_result_revision = 2",
             [uuid(f.scorer_result)]
           ).rows == [["pending"]]

    assert view |> element("#verify-#{f.scorer_result}") |> render_click() =~ "Verified"
  end

  test "shows current and historical certification without private reasons", %{conn: conn} do
    f = fixture!(2, true)
    {view, _} = open!(conn, f, f.verifier_grant)
    assert view |> element("#verify-#{f.scorer_result}") |> render_click() =~ "Verified"

    assert {:ok, _} =
             Scoring.correct_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result,
               expected_revision: 1,
               new_gross_strokes: 6,
               reason: "private correction"
             })

    {_fresh, html} = open!(conn, f, f.verifier_grant)
    assert html =~ "Earlier verification evidence is historical"
    assert html =~ "Verification required"
    refute html =~ "private correction"
  end

  test "shows an independent query indicator without exposing its reason", %{conn: conn} do
    f = fixture!()

    assert {:ok, _} =
             Scoring.query_hole_result(f.admin, f.event.id, f.round.id, %{
               hole_result_id: f.scorer_result,
               expected_revision: 1,
               reason: "private query reason"
             })

    {view, html} = open!(conn, f, f.verifier_grant)
    assert has_element?(view, "#result-#{f.scorer_result}", "Score query under review")
    assert has_element?(view, "#result-#{f.scorer_result}", "Verification required")
    refute html =~ "private query reason"
  end

  test "populated groups in the same round cannot access each other's results", %{conn: conn} do
    f = fixture!()
    Fixtures.set_round_state!(f.round, :draft)

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

    entries_b = Fixtures.add_player_entries_to_group!(f, group_b, 2)
    verifier = Enum.at(entries_b, 1)

    Repo.query!(
      "UPDATE players SET first_name = 'GroupBSecret', surname = 'Golfer' WHERE id = $1::uuid",
      [uuid(verifier.player_id)]
    )

    assert {:ok, _} =
             Competition.assign_designated_verifier(
               f.admin,
               f.event.id,
               f.round.id,
               group_b.id,
               verifier.id
             )

    Fixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, %{grant: grant_b}} =
             Accounts.issue_player_access(f.admin, f.event.id, verifier.player_id)

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

    {view_a, html_a} = open!(conn, f, f.verifier_grant)
    refute html_a =~ "GroupBSecret Golfer"
    group_b_f = %{f | group: group_b}
    {_forbidden, forbidden_html} = open!(conn, group_b_f, f.verifier_grant)
    assert forbidden_html =~ "Verification unavailable"
    refute forbidden_html =~ "GroupBSecret"
    {view_b, html_b} = open!(conn, group_b_f, grant_b)
    assert html_b =~ "GroupBSecret Golfer"
    refute has_element?(view_b, "#result-#{f.scorer_result}")
    refute has_element?(view_a, "#verification-unavailable")
  end

  defp fixture!(count \\ 2, with_side? \\ false) do
    f = Fixtures.setup_submit_fixture!(count)
    [scorer, verifier | _] = f.entries
    Fixtures.set_round_state!(f.round, :draft)

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

    Fixtures.set_round_state!(f.round, :scoring_open)

    assert {:ok, %{grant: scorer_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, scorer.player_id)

    assert {:ok, %{grant: verifier_grant}} =
             Accounts.issue_player_access(f.admin, f.event.id, verifier.player_id)

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

    [scorer_result, verifier_result] =
      Enum.map([scorer, verifier], fn entry ->
        [[id]] =
          Repo.query!(
            "SELECT hr.id::text FROM hole_results hr JOIN scorecards sc ON sc.id = hr.scorecard_id WHERE sc.round_entry_id = $1::uuid",
            [Ecto.UUID.dump!(entry.id)]
          ).rows

        id
      end)

    Map.merge(f, %{
      scorer_grant: scorer_grant,
      verifier_grant: verifier_grant,
      scorer_result: scorer_result,
      verifier_result: verifier_result,
      verifier_assignment: assignment
    })
  end

  defp open!(conn, f, grant) do
    conn = conn |> init_test_session(%{}) |> Session.put_grant_id(grant.id)
    {:ok, view, html} = live(conn, path(f))
    {view, html}
  end

  defp path(f),
    do: "/player/events/#{f.event.id}/rounds/#{f.round.id}/groups/#{f.group.id}/verify"

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
