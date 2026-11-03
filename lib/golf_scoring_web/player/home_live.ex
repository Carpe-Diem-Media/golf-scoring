defmodule GolfScoringWeb.Player.HomeLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:current_path, ~p"/player")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.player
        flash={@flash}
        page_title={@page_title}
        current_path={@current_path}
      >
        <section id="player-home" class="space-y-10">
          <div class="space-y-2">
            <h2 class="text-xl font-semibold tracking-tight">Welcome</h2>
            <p class="text-sm text-base-content/80">
              Your player access is active. Live scoring and results will appear here when the event
              opens them for you.
            </p>
          </div>

          <dl class="divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100">
            <div class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Event</dt>
              <dd class="text-base font-medium">Your assigned event</dd>
            </div>
            <div class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Status</dt>
              <dd class="text-base font-medium">Access confirmed</dd>
            </div>
          </dl>

          <section
            id="player-future-scoring"
            class="rounded-xl border border-dashed border-base-300 bg-base-200/30 px-4 py-5"
          >
            <h3 class="text-base font-semibold">Scorecard</h3>
            <p class="mt-2 text-sm text-base-content/80">
              Hole-by-hole entry is not available yet. It will appear here when scoring opens.
            </p>
          </section>

          <section
            id="player-future-leaderboard"
            class="rounded-xl border border-dashed border-base-300 bg-base-200/30 px-4 py-5"
          >
            <h3 class="text-base font-semibold">Leaderboard and results</h3>
            <p class="mt-2 text-sm text-base-content/80">
              Results will be published here when the event makes them available.
            </p>
          </section>
        </section>
      </AppShell.player>
    </Layouts.app>
    """
  end
end
