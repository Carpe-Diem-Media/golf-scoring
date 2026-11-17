defmodule GolfScoringWeb.Admin.StandardStandingsLive do
  @moduledoc false
  use GolfScoringWeb, :live_view

  alias GolfScoring.Scoring

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:staff, socket.assigns[:current_staffuser]) |> assign(:rows, [])}
  end

  @impl true
  def handle_params(
        %{"event_id" => event, "round_id" => round, "scoring_track_id" => track},
        _uri,
        socket
      ) do
    scope = {event, round, track}
    if connected?(socket), do: send(self(), {:load_standings, scope})

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> assign(:event_id, event)
     |> assign(:round_id, round)
     |> assign(
       :current_path,
       ~p"/admin/events/#{event}/rounds/#{round}/standard-standings/#{track}"
     )
     |> assign(:state, :loading)
     |> assign(:rows, [])}
  end

  @impl true
  def handle_info({:load_standings, scope}, %{assigns: %{scope: scope}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:load_standings, _scope}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    {event, round, track} = socket.assigns.scope

    case Scoring.load_standard_standings_for_staff(socket.assigns.staff, event, round, track) do
      {:ok, []} -> socket |> assign(:rows, []) |> assign(:state, :empty)
      {:ok, rows} -> socket |> assign(:rows, rows) |> assign(:state, :ready)
      {:error, _} -> socket |> assign(:rows, []) |> assign(:state, :unavailable)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.staff
        flash={@flash}
        page_title="Standard standings"
        current_staff_user={@staff}
        current_path={@current_path}
        event_id={@event_id}
        round_id={@round_id}
      >
        <section class="space-y-5" aria-labelledby="standings-heading">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 id="standings-heading" class="text-xl font-semibold">Standard standings</h2>
              <p>Provisional</p>
            </div>
            <button
              id="refresh-standings"
              type="button"
              phx-click="refresh"
              class="min-h-11 rounded-lg border border-base-content px-4 py-2 text-sm font-semibold hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >Refresh</button>
          </div>
          <p :if={@state == :loading} id="standings-loading" role="status">Loading standings...</p>
          <p :if={@state == :empty} id="standings-empty" role="status">
            There are no sides in these standings.
          </p>
          <p :if={@state == :unavailable} id="standings-unavailable" role="status">
            Standings are unavailable.
          </p>
          <div :if={@state == :ready} class="overflow-x-auto">
            <table id="standings" class="w-full text-left text-sm">
              <caption class="sr-only">Provisional Standard standings</caption>
              <thead>
                <tr class="border-b border-base-300">
                  <th scope="col">Position</th><th scope="col">Side</th><th scope="col">Subtotal</th><th scope="col">
                    Holes completed
                  </th><th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rows} class="border-b border-base-300">
                  <td class="py-3">{row.position || "Unranked"}</td><th
                    scope="row"
                    class="break-all font-normal"
                  >
                    {row.side_id}
                  </th><td>{row.subtotal}</td><td>{row.holes_completed}</td><td>
                    {status(row.display_status)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </AppShell.staff>
    </Layouts.app>
    """
  end

  defp status(:under_review), do: "Under review"
  defp status(:unranked), do: "Unranked"
  defp status(:provisional), do: "Provisional"
end
