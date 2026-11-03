defmodule GolfScoringWeb.Player.AccessControllerTest do
  use GolfScoringWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoringWeb.Player.Session

  @password "GLS-21 web synthetic staff passphrase 2026"

  setup do
    Process.put(:gls21_web_prefix, "gls21-web-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls21_web_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, setup: setup_event_player!()}
  end

  test "exchange redirect and body contain no bearer token", %{conn: conn, setup: setup} do
    {:ok, %{token: token}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn = get(conn, "/player/access?token=#{URI.encode(token)}")

    refute get_resp_header(conn, "location") |> Enum.join("") =~ token
    refute conn.resp_body =~ token
    assert redirected_to(conn) == ~p"/player"
  end

  test "signed session stores grant reference only", %{conn: conn, setup: setup} do
    {:ok, %{grant: grant, token: token}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> get("/player/access?token=#{URI.encode(token)}")
      |> fetch_session()

    assert Session.grant_id(conn) == grant.id
    refute get_session(conn, "token")
    refute get_session(conn, "token_digest")
    refute get_session(conn, "player_id")
    refute get_session(conn, "primary_scorer")
  end

  test "invalid token is rejected generically", %{conn: conn} do
    conn = get(conn, "/player/access?token=#{URI.encode("not-a-valid-grant")}")
    assert conn.status == 401
    assert conn.resp_body == "Authentication failed"
  end

  test "token parameter is filtered from request logs", %{conn: conn, setup: setup} do
    {:ok, %{token: token}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    log =
      capture_log(fn ->
        get(conn, "/player/access?token=#{URI.encode(token)}")
      end)

    refute log =~ token
  end

  test "valid player session cannot satisfy admin route authorization", %{
    conn: conn,
    setup: setup
  } do
    {:ok, %{token: token}} =
      Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> get("/player/access?token=#{URI.encode(token)}")
      |> get("/admin")

    assert redirected_to(conn) == "/admin/sign-in"
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
    email = "#{Process.get(:gls21_web_prefix)}-#{System.unique_integer([:positive])}@example.com"

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
