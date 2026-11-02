defmodule GolfScoringWeb.Player.HomeLiveTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoringWeb.Player.Session

  @password "GLS-UX player home synthetic staff passphrase 2026"

  setup do
    Process.put(:gls_ux_player_prefix, "gls-ux-player-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls_ux_player_prefix) end)

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

    assert html =~ "Pat Player"
    assert has_element?(view, "#player-application-shell")
    assert has_element?(view, "#player-shell-nav")
    assert has_element?(view, "#player-home")
    assert has_element?(view, "#player-nav-home[aria-current=\"page\"]")
    refute html =~ setup.event.id
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
end
