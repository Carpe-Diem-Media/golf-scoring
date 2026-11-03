defmodule GolfScoringWeb.Player.AccessDeniedLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Access denied")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.player_guest flash={@flash} page_title={@page_title}>
        <section id="player-access-denied" class="max-w-prose space-y-6">
          <p class="text-base leading-relaxed text-base-content/80">
            This player link is invalid, expired, or has been revoked. Ask event staff for a new access link.
          </p>
        </section>
      </AppShell.player_guest>
    </Layouts.app>
    """
  end
end
