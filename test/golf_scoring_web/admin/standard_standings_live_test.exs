defmodule GolfScoringWeb.Admin.StandardStandingsLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures, as: Fixtures

  setup context do
    if context[:fixture], do: setup_fixture(), else: :ok
  end

  defp setup_fixture do
    owner = Sandbox.start_owner!(Repo, shared: true, sandbox: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    verify_identity!()

    {:ok, f} =
      Repo.transaction(fn ->
        verify_identity!()
        fixture!()
      end)

    on_exit(fn ->
      verify_identity!()

      {:ok, :ok} =
        Repo.transaction(fn ->
          delete_fixture_rows!(f)
          :ok
        end)
    end)

    %{fixture: f}
  end

  test "anonymous visitors are redirected to staff sign in", %{conn: conn} do
    id = Ecto.UUID.generate()
    conn = get(conn, "/admin/events/#{id}/rounds/#{id}/standard-standings/#{id}")
    assert redirected_to(conn) == "/admin/sign-in"
  end

  @tag :fixture
  test "staff roles, refresh, privacy and revoked authority", %{conn: conn, fixture: f} do
    conn = authenticate(conn, f.admin.email)

    for role <- ["event_admin", "competition_manager"] do
      role!(f, role, "active")
      {:ok, view, _} = live(conn, path(f))
      assert has_element?(view, "#standings")
      html = render(view)
      assert html =~ "Provisional"
      assert html =~ "Unranked"
      for side <- f.sides, do: assert(html =~ side.id)
      for entry <- f.entries, do: refute(html =~ entry.id)
    end

    for role <- ["scoring_support", "registration_staff"] do
      role!(f, role, "active")
      {:ok, view, _} = live(conn, path(f))
      html = render(view)
      assert html =~ "Standings are unavailable"
      for side <- f.sides, do: refute(html =~ side.id)
    end

    role!(f, "event_admin", "active")
    {:ok, view, _} = live(conn, path(f))
    assert has_element?(view, "#standings")

    Repo.query!(
      "UPDATE competition_side_results SET state = 'review_required' WHERE competition_side_id = $1::uuid",
      [uuid(hd(f.sides).id)]
    )

    html =
      render_click(view, "refresh", %{
        "event_id" => Ecto.UUID.generate(),
        "round_id" => Ecto.UUID.generate(),
        "scoring_track_id" => Ecto.UUID.generate()
      })

    assert html =~ "Under review"
    assert html =~ hd(f.sides).id

    role!(f, "event_admin", "revoked")
    html = render_click(view, "refresh", %{})
    assert html =~ "Standings are unavailable"
    for side <- f.sides, do: refute(html =~ side.id)
    refute has_element?(view, "#standings")
    role!(f, "event_admin", "active")
    assert render_click(view, "refresh", %{}) =~ hd(f.sides).id

    Repo.query!("UPDATE staff_users SET status = 'suspended' WHERE id = $1::uuid", [
      uuid(f.admin.id)
    ])

    html = render_click(view, "refresh", %{})
    assert html =~ "Standings are unavailable"
    for side <- f.sides, do: refute(html =~ side.id)
  end

  @tag :fixture
  test "empty and incorrect scopes fail closed", %{conn: conn, fixture: f} do
    conn = authenticate(conn, f.admin.email)

    for {event, round, track} <- [
          {Ecto.UUID.generate(), f.round.id, f.track.id},
          {f.event.id, Ecto.UUID.generate(), f.track.id},
          {f.event.id, f.round.id, Ecto.UUID.generate()},
          {"bad", f.round.id, f.track.id}
        ] do
      {:ok, view, _} =
        live(conn, "/admin/events/#{event}/rounds/#{round}/standard-standings/#{track}")

      html = render(view)
      assert html =~ "Standings are unavailable"
      for side <- f.sides, do: refute(html =~ side.id)
    end

    Repo.query!(
      "DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
      [uuid(f.round.id)]
    )

    Repo.query!("DELETE FROM competition_side_memberships WHERE round_id = $1::uuid", [
      uuid(f.round.id)
    ])

    Repo.query!("DELETE FROM competition_sides WHERE round_id = $1::uuid", [uuid(f.round.id)])
    {:ok, view, _} = live(conn, path(f))
    assert render(view) =~ "There are no sides"
  end

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

  defp role!(f, role, status) do
    Repo.query!(
      "UPDATE event_staff_assignments SET role=$2, status=$3 WHERE event_id=$1::uuid AND staff_user_id=$4::uuid",
      [uuid(f.event.id), role, status, uuid(f.admin.id)]
    )
  end

  defp path(f),
    do: "/admin/events/#{f.event.id}/rounds/#{f.round.id}/standard-standings/#{f.track.id}"

  defp verify_identity! do
    rows = Repo.query!("SELECT current_database(), current_user").rows
    runner = Map.new(["CI", "GITHUB_ACTIONS", "GITHUB_REPOSITORY"], &{&1, System.get_env(&1)})

    case {Mix.env(), rows, runner} do
      {:test, [["golf_scoring_test", "golf_scoring_test"]],
       %{"CI" => nil, "GITHUB_ACTIONS" => nil, "GITHUB_REPOSITORY" => nil}} ->
        :ok

      {:test, [["golf_scoring_test", "golf_scoring_ci"]],
       %{
         "CI" => "true",
         "GITHUB_ACTIONS" => "true",
         "GITHUB_REPOSITORY" => "Carpe-Diem-Media/golf-scoring"
       }} ->
        :ok

      _ ->
        raise "refusing writes outside the allocated test database and role"
    end
  end

  defp fixture! do
    f = Fixtures.setup_submit_fixture!(2)
    Fixtures.set_round_state!(f.round, :draft)

    {:ok, _} =
      Competition.configure_round_competition(f.admin, f.event.id, f.round.id, %{
        solo_sides_permitted: true
      })

    sides =
      Enum.map(f.entries, fn entry ->
        {:ok, side} =
          Competition.create_competition_side(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            :solo
          )

        {:ok, _} =
          Fixtures.set_side_membership_for_fixture(
            f.admin,
            f.event.id,
            f.round.id,
            f.competition.id,
            side.id,
            [entry.id]
          )

        side
      end)

    {:ok, track} =
      Competition.configure_scoring_track(f.admin, f.event.id, f.round.id, f.competition.id, %{
        track_type: :standard_better_ball,
        name: "Standard Better-Ball",
        is_primary: false,
        visibility_policy_identifier: "leaderboard_v1",
        aggregation_policy_identifier: "standard_better_ball_v1",
        tie_break_policy_identifier: "standard_countback_v1"
      })

    Repo.query!("UPDATE scoring_tracks SET configuration_state = 'locked' WHERE id = $1::uuid", [
      uuid(track.id)
    ])

    Fixtures.set_round_state!(f.round, :scoring_open)
    Map.merge(f, %{sides: sides, track: track})
  end

  defp uuid(id), do: Ecto.UUID.dump!(id)

  defp delete_fixture_rows!(f) do
    round = uuid(f.round.id)

    for {sql, params} <- [
          {"DELETE FROM round_entry_participation_rulings WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM score_verifications WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM player_access_grants WHERE event_id = $1::uuid", [uuid(f.event.id)]},
          {"DELETE FROM score_revisions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM hole_results WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM hole_submissions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM audit_events WHERE context->>'round_id' = $1", [f.round.id]},
          {"DELETE FROM scorecards WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_handicaps WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM handicap_snapshots WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_side_results WHERE competition_side_id IN (SELECT id FROM competition_sides WHERE round_id = $1::uuid)",
           [round]},
          {"DELETE FROM competition_side_memberships WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM competition_sides WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM group_role_assignments WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_entries WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM playing_groups WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM scoring_tracks WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_competitions WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_tee_hole_snapshots WHERE round_tee_profile_snapshot_id IN (SELECT id FROM round_tee_profile_snapshots WHERE round_id = $1::uuid)",
           [round]},
          {"DELETE FROM round_tee_profile_snapshots WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM round_holes WHERE round_id = $1::uuid", [round]},
          {"DELETE FROM rounds WHERE id = $1::uuid", [round]},
          {"DELETE FROM tee_rating_profiles WHERE id = $1::uuid", [uuid(f.tee_profile.id)]},
          {"DELETE FROM tee_sets WHERE id = $1::uuid", [uuid(f.tee_set.id)]},
          {"DELETE FROM course_holes WHERE course_id = $1::uuid", [uuid(f.course.id)]},
          {"DELETE FROM courses WHERE id = $1::uuid", [uuid(f.course.id)]},
          {"DELETE FROM event_staff_assignments WHERE event_id = $1::uuid", [uuid(f.event.id)]},
          {"DELETE FROM events WHERE id = $1::uuid", [uuid(f.event.id)]},
          {"DELETE FROM staff_users WHERE id = $1::uuid", [uuid(f.admin.id)]}
        ],
        do: Repo.query!(sql, params)

    for entry <- f.entries,
        do: Repo.query!("DELETE FROM players WHERE id = $1::uuid", [uuid(entry.player_id)])
  end
end
