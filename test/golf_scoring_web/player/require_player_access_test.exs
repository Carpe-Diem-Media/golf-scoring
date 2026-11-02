defmodule GolfScoringWeb.Player.RequirePlayerAccessTest do
  use GolfScoringWeb.ConnCase, async: false

  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts
  alias GolfScoring.Competition
  alias GolfScoring.Repo
  alias GolfScoringWeb.Player.RequirePlayerAccess
  alias GolfScoringWeb.Player.Session

  @password "GLS-21 require plug synthetic staff passphrase 2026"

  setup do
    Process.put(:gls21_req_prefix, "gls21-req-#{Ecto.UUID.generate()}")
    on_exit(fn -> Process.delete(:gls21_req_prefix) end)

    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    {:ok, setup: setup_event_player!()}
  end

  test "accepts valid active grant session and assigns event and player", %{
    conn: conn,
    setup: setup
  } do
    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)
      |> invoke_require_player_access()

    refute conn.halted
    assert conn.assigns.current_player_access_grant.id == grant.id
    assert conn.assigns.current_player_id == setup.player.id
    assert conn.assigns.current_player_event_id == setup.event.id
  end

  test "rejects revoked grant session and clears player session reference", %{
    conn: conn,
    setup: setup
  } do
    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, _} = Accounts.revoke_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)
      |> invoke_require_player_access()

    assert conn.halted
    assert redirected_to(conn) == "/player/access-denied"
    assert is_nil(Session.grant_id(conn))
  end

  test "rejects superseded grant session and clears player session reference", %{
    conn: conn,
    setup: setup
  } do
    assert {:ok, %{grant: original}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id)

    assert {:ok, _} = Accounts.reissue_player_access(setup.admin, setup.event.id, setup.player.id)

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(original.id)
      |> invoke_require_player_access()

    assert conn.halted
    assert redirected_to(conn) == "/player/access-denied"
    assert is_nil(Session.grant_id(conn))
  end

  test "rejects expired grant session and clears player session reference", %{
    conn: conn,
    setup: setup
  } do
    past = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {:ok, %{grant: grant}} =
             Accounts.issue_player_access(setup.admin, setup.event.id, setup.player.id,
               expires_at: past
             )

    conn =
      conn
      |> init_test_session(%{})
      |> Session.put_grant_id(grant.id)
      |> invoke_require_player_access()

    assert conn.halted
    assert redirected_to(conn) == "/player/access-denied"
    assert is_nil(Session.grant_id(conn))
  end

  defp invoke_require_player_access(conn) do
    conn
    |> fetch_session()
    |> RequirePlayerAccess.call(RequirePlayerAccess.init([]))
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
    email = "#{Process.get(:gls21_req_prefix)}-#{System.unique_integer([:positive])}@example.com"

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
