defmodule GolfScoringWeb.Player.HomeLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  alias GolfScoring.Competition.Player
  alias GolfScoring.Repo

  @impl true
  def mount(_params, _session, socket) do
    grant = socket.assigns.current_player_access_grant
    player = Ash.get!(Player, grant.player_id, authorize?: false)
    context = load_event_context(grant.event_id, grant.player_id)

    {:ok,
     socket
     |> assign(:page_title, "Home")
     |> assign(:current_path, ~p"/player")
     |> assign(:player, player)
     |> assign(:player_name, player_display_name(player))
     |> assign(:event_context, context)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.player
        flash={@flash}
        page_title={@page_title}
        player_name={@player_name}
        current_path={@current_path}
      >
        <section id="player-home" class="space-y-6">
          <div class="space-y-2">
            <h2 class="text-xl font-semibold tracking-tight">Welcome, {@player_name}</h2>
            <p class="text-sm text-base-content/80">
              You are signed in for your event. Live scoring opens here when the competition begins.
            </p>
          </div>

          <dl class="divide-y divide-base-300 rounded-xl border border-base-300 bg-base-100">
            <div class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Event</dt>
              <dd class="text-base font-medium">Your assigned event</dd>
            </div>
            <div :if={@event_context.round_label} class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Round</dt>
              <dd class="text-base font-medium">{@event_context.round_label}</dd>
            </div>
            <div :if={@event_context.group_label} class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Group</dt>
              <dd class="text-base font-medium">{@event_context.group_label}</dd>
            </div>
            <div class="grid gap-1 px-4 py-3">
              <dt class="text-sm text-base-content/70">Scoring status</dt>
              <dd class="text-base font-medium">{@event_context.scoring_status}</dd>
            </div>
          </dl>

          <section
            id="player-future-scoring"
            class="rounded-xl border border-dashed border-base-300 bg-base-200/30 px-4 py-5"
          >
            <h3 class="text-base font-semibold">Scorecard</h3>
            <p class="mt-2 text-sm text-base-content/80">
              Hole-by-hole entry is not available yet. It will appear here when scoring opens for your group.
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

  defp load_event_context(event_id, player_id) do
    case Repo.query(
           """
           SELECT r.state, pg.starting_position, pg.state
           FROM round_entries re
           INNER JOIN rounds r ON r.id = re.round_id
           LEFT JOIN playing_groups pg ON pg.id = re.playing_group_id
           WHERE re.event_id = $1::uuid AND re.player_id = $2::uuid
           ORDER BY r.inserted_at ASC
           LIMIT 1
           """,
           [Ecto.UUID.dump!(event_id), Ecto.UUID.dump!(player_id)]
         ) do
      {:ok, %{rows: [[round_state, starting_position, group_state]]}} ->
        %{
          round_label: round_state_label(round_state),
          group_label: group_label(starting_position),
          scoring_status: scoring_status_label(round_state, group_state)
        }

      _ ->
        %{
          round_label: nil,
          group_label: nil,
          scoring_status: "Registration only"
        }
    end
  end

  defp round_state_label(state) when is_binary(state) do
    state |> String.replace("_", " ") |> String.capitalize()
  end

  defp round_state_label(_), do: "Scheduled round"

  defp group_label(position) when is_integer(position), do: "Starting group #{position}"
  defp group_label(_), do: nil

  defp scoring_status_label("scoring_open", _), do: "Scoring open"
  defp scoring_status_label("finalized", _), do: "Round finalized"
  defp scoring_status_label(_, "playing"), do: "On course"
  defp scoring_status_label(_, _), do: "Not started"

  defp player_display_name(%Player{first_name: first, surname: surname}) do
    String.trim("#{first} #{surname}")
  end
end
