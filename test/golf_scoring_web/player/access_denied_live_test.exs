defmodule GolfScoringWeb.Player.AccessDeniedLiveTest do
  use GolfScoringWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "access denied page renders without authenticated player navigation", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/player/access-denied")

    assert html =~ ~s(id="player-access-denied")
    assert has_element?(view, "#player-access-denied-shell")
    refute has_element?(view, "#player-shell-nav")
    refute has_element?(view, "#player-nav-home")
    refute has_element?(view, "#player-application-shell")
  end

  test "invalid player session lands on access denied without home navigation", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/player/access-denied"}}} = live(conn, ~p"/player")

    {:ok, denied_view, _html} = live(conn, ~p"/player/access-denied")

    assert has_element?(denied_view, "#player-access-denied")
    refute has_element?(denied_view, "#player-nav-home")
    refute has_element?(denied_view, "#player-shell-nav")
  end
end
