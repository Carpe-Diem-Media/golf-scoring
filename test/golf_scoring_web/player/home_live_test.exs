defmodule GolfScoringWeb.Player.HomeLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoring.Scoring.Services.PaperRecoveryFixtures
  alias GolfScoringWeb.Player.Session

  @password "GLS-UX player home synthetic staff passphrase 2026"

  setup do
    Process.put(:gls_ux_player_prefix, "gls-ux-player-#{Ecto.UUID.generate()}")
    Process.put(:gls34_prefix, "gls72-home-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls_ux_player_prefix) end)
    on_exit(fn -> Process.delete(:gls34_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, setup: setup_event_player!()}
  end

  test "token exchange redirects to player home", %{conn: conn, setup: setup} do
    {:ok, %{token: token}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn = get(conn, "/player/access?token=#{URI.encode(token)}")
    assert redirected_to(conn) == ~p"/player"
  end

  test "player home requires a valid grant session", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/player/access-denied"}}} = live(conn, ~p"/player")
  end

  test "valid grant mounts player home with shell landmarks", %{conn: conn, setup: setup} do
    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)

    {:ok, view, html} = live(conn, ~p"/player")

    assert html =~ "Your player access is active"
    assert has_element?(view, "#player-application-shell")
    assert has_element?(view, "#player-shell-nav")
    assert has_element?(view, "#player-home")
    assert has_element?(view, "#player-nav-home[aria-current=\"page\"]")
    assert html =~ "focus-visible:outline-base-content"
    refute html =~ "focus-visible:outline-primary"
    refute html =~ "Hole-by-hole entry is not available yet"
    refute html =~ setup.event.id
    refute html =~ setup.player.id
  end

  test "current primary scorer can navigate to their assigned group scorecard", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    scorer = hd(setup.entries)
    grant = issue_grant!(setup, scorer.player_id)
    conn = grant_conn(conn, grant.id)
    scorecard_path = scorecard_path(setup.event.id, setup.round.id, setup.group.id)

    {:ok, home, html} = live(conn, ~p"/player")

    assert has_element?(home, "#player-scorecard-link[href='#{scorecard_path}']")
    refute html =~ "Hole-by-hole entry is not available yet"

    {:ok, scorecard, scorecard_html} = live(conn, scorecard_path)
    assert has_element?(scorecard, "#group-scorecard")
    assert scorecard_html =~ "Save hole for group"
  end

  test "a non-scorer gets no home link and cannot open a guessed scorecard route", %{conn: conn} do
    setup = PaperRecoveryFixtures.setup_submit_fixture!(2)
    non_scorer = Enum.at(setup.entries, 1)
    grant = issue_grant!(setup, non_scorer.player_id)
    conn = grant_conn(conn, grant.id)
    scorecard_path = scorecard_path(setup.event.id, setup.round.id, setup.group.id)

    {:ok, home, _html} = live(conn, ~p"/player")
    refute has_element?(home, "#player-scorecard-link")

    {:ok, scorecard, html} = live(conn, scorecard_path)
    assert has_element?(scorecard, "#scorecard-unavailable")
    refute has_element?(scorecard, "#scorecard-entry-form")
    refute html =~ "Pat Golfer"
  end

  test "revoked grant cannot mount player home", %{conn: conn, setup: setup} do
    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)

    assert {:error, {:redirect, %{to: "/player/access-denied"}}} = live(conn, ~p"/player")
  end

  test "player home exposes no score mutation controls", %{conn: conn, setup: setup} do
    {:ok, %{grant: grant}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)

    {:ok, view, _html} = live(conn, ~p"/player")
    html = render(view)
    refute html =~ "phx-submit"
    refute html =~ "SubmitGroupHole"
  end

  defp setup_event_player! do
    event =
      GolfScoring.Competition.Event
      |> Ash.Changeset.for_create(:create_internal, %{})
      |> Ash.create!(authorize?: false)

    admin = create_event_admin!(event)
    course = create_course!(event, admin)
    {:ok, round} = Competition.create_round(event.id, course.id, actor: admin)

    player =
      GolfScoring.Competition.Player
      |> Ash.Changeset.for_create(:create_internal, %{
        first_name: "Pat",
        surname: "Player"
      })
      |> Ash.create!(authorize?: false)

    {:ok, _entry} =
      Competition.add_round_entry(event.id, round.id, player.id, actor: admin)

    %{event: event, round: round, admin: admin, player: player}
  end

  defp create_event_admin!(event) do
    staff = create_staff_user!()

    Repo.query!(
      "INSERT INTO event_staff_assignments (event_id, staff_user_id, role, status) VALUES ($1::uuid, $2::uuid, 'event_admin', 'active')",
      [Ecto.UUID.dump!(event.id), Ecto.UUID.dump!(staff.id)]
    )

    staff
  end

  defp create_staff_user! do
    email =
      "#{Process.get(:gls_ux_player_prefix)}-#{System.unique_integer([:positive])}@example.com"

    GolfScoring.Accounts.StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_course!(event, admin, suffix \\ "Main") do
    {:ok, course} =
      GolfScoring.GolfCatalog.create_course(
        event.id,
        %{name: "Test Course #{suffix}", location: "Here"},
        actor: admin
      )

    course
  end

  defp issue_grant!(setup, player_id) do
    {:ok, %{grant: grant}} = Accounts.issue_player_access(setup.admin, setup.event.id, player_id)
    grant
  end

  defp grant_conn(conn, grant_id) do
    conn
    |> init_test_session(%{})
    |> Session.put_grant_id(grant_id)
  end

  defp scorecard_path(event_id, round_id, group_id) do
    "/player/events/#{event_id}/rounds/#{round_id}/groups/#{group_id}/scorecard"
  end
end
