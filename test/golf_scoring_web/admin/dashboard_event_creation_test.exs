defmodule GolfScoringWeb.Admin.DashboardEventCreationTest do
  use GolfScoringWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts.EventStaffAssignment
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Audit.AuditEvent
  alias GolfScoring.Competition.Event
  alias GolfScoring.Repo

  require Ash.Query

  @password "GLS-13 synthetic staff passphrase 2026"
  @sign_in_form "#staffuser-password-sign-in-with-password"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "active SYSTEM_ADMIN can create an Event from the admin dashboard", %{conn: conn} do
    admin = create_system_admin!()
    conn = authenticate(conn, admin.email)

    events_before = event_count()

    {:ok, view, html} = live(conn, "/admin")
    assert html =~ ~s(id="staff-application-shell")
    assert has_element?(view, "#staff-shell-nav")
    assert has_element?(view, "#staff-nav-dashboard[aria-current=\"page\"]")
    assert has_element?(view, "#create-event-button")
    assert render_click(element(view, "#create-event-button")) =~ "Event created"

    assert event_count() == events_before + 1

    event =
      Event
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(authorize?: false)

    assert event.state == :draft
    assert has_element?(view, "#last-created-event[data-event-id=\"#{event.id}\"]")

    assert [assignment] =
             EventStaffAssignment
             |> Ash.Query.filter(event_id == ^event.id and staff_user_id == ^admin.id)
             |> Ash.read!(authorize?: false)

    assert assignment.role == :event_admin
    assert assignment.status == :active

    assert [audit] =
             AuditEvent
             |> Ash.Query.filter(
               target_type == "event" and target_id == ^event.id and action == "event_created"
             )
             |> Ash.read!(authorize?: false)

    assert audit.actor_staff_user_id == admin.id
  end

  test "ordinary active staff cannot create an Event from the admin dashboard", %{conn: conn} do
    staff = create_staff_user!()
    conn = authenticate(conn, staff.email)
    events_before = event_count()

    {:ok, view, _html} = live(conn, "/admin")
    refute has_element?(view, "#create-event-button")
    assert has_element?(view, "#create-event-unavailable")
    assert event_count() == events_before
  end

  test "unauthenticated browsers cannot reach the admin dashboard", %{conn: conn} do
    conn = get(conn, "/admin")
    assert redirected_to(conn) == "/admin/sign-in"
  end

  defp authenticate(conn, email) do
    {:ok, view, _html} = live(conn, "/admin/sign-in")

    form =
      form(view, @sign_in_form, %{
        "staffuser" => %{"email" => to_string(email), "password" => @password}
      })

    assert render_submit(form) =~ "phx-trigger-action"
    conn = follow_trigger_action(form, conn)
    assert redirected_to(conn) == "/admin"
    conn
  end

  defp create_staff_user! do
    email = "gls13-web-#{System.unique_integer([:positive])}@example.com"

    StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end

  defp create_system_admin! do
    staff = create_staff_user!()

    Repo.query!("UPDATE staff_users SET system_admin = TRUE WHERE id = $1::uuid", [
      Ecto.UUID.dump!(staff.id)
    ])

    Repo.get!(StaffUser, staff.id)
  end

  defp event_count do
    [[count]] = Repo.query!("SELECT count(*) FROM events").rows
    count
  end
end
