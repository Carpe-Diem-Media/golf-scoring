defmodule GolfScoringWeb.StaffMobileNavHookTest do
  use GolfScoringWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Repo

  @password "GLS-78 hook test synthetic staff passphrase 2026"
  @sign_in_form "#staffuser-password-sign-in-with-password"

  setup do
    owner = Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
    :ok
  end

  test "staff shell exposes mobile menu control with closed aria-expanded and hook", %{conn: conn} do
    staff = create_staff_user!()
    conn = authenticate(conn, staff.email)

    {:ok, view, html} = live(conn, "/admin")

    assert html =~ "StaffMobileNav"
    assert html =~ ~s(id="staff-shell-menu-toggle")
    assert html =~ ~s(aria-expanded="false")
    assert has_element?(view, "#staff-mobile-nav[hidden]")
    refute html =~ ~s(id="staff-shell-header" class="btn)
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
    email = "gls78-hook-#{System.unique_integer([:positive])}@example.com"

    StaffUser
    |> Ash.Changeset.for_create(:provision_staff_user, %{
      email: email,
      password: @password,
      password_confirmation: @password
    })
    |> Ash.create!(authorize?: false)
  end
end
