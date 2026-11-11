defmodule GolfScoringWeb.Admin.ScoreQueriesLive do
  @moduledoc false
  use GolfScoringWeb, :live_view

  alias GolfScoring.Scoring

  @impl true
  def mount(%{"event_id" => event_id, "round_id" => round_id}, _session, socket) do
    {:ok,
     socket
     |> assign(:staff, socket.assigns[:current_staffuser])
     |> assign(:event_id, event_id)
     |> assign(:round_id, round_id)
     |> assign(:current_path, ~p"/admin/events/#{event_id}/rounds/#{round_id}/score-queries")
     |> assign(:next_cursor, nil)
     |> assign(:available?, false)
     |> assign(:empty?, true)
     |> stream(:queries, [])
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("load_more", _params, %{assigns: %{next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    {:noreply, load(socket, [cursor: socket.assigns.next_cursor], false)}
  end

  defp refresh(socket), do: load(socket, [], true)

  defp load(socket, opts, reset?) do
    result =
      try do
        Scoring.load_staff_score_query_review(
          socket.assigns.staff,
          socket.assigns.event_id,
          socket.assigns.round_id,
          opts
        )
      rescue
        _ -> {:error, :unavailable}
      end

    case result do
      {:ok, page} ->
        socket
        |> assign(:available?, true)
        |> assign(:next_cursor, page.next_cursor)
        |> assign(:empty?, reset? and page.items == [])
        |> stream(:queries, page.items, reset: reset?)

      {:error, _} ->
        socket
        |> assign(:available?, false)
        |> assign(:next_cursor, nil)
        |> assign(:empty?, true)
        |> stream(:queries, [], reset: true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.staff
        flash={@flash}
        page_title="Score queries"
        current_staff_user={@staff}
        current_path={@current_path}
        event_id={@event_id}
        round_id={@round_id}
      >
        <section :if={!@available?} id="queries-unavailable" role="status">
          <p>Score queries are unavailable for this round.</p>
        </section>
        <section :if={@available?} id="score-query-review" class="space-y-5">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <p>Review recorded queries and their current score evidence.</p>
            <button
              type="button"
              id="refresh-queries"
              phx-click="refresh"
              class="min-h-11 rounded-lg border border-base-content px-4 py-2 text-sm font-semibold hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
            >Refresh</button>
          </div>
          <p :if={@empty?} id="queries-empty">There are no score queries for this round.</p>
          <ul
            id="score-queries"
            phx-update="stream"
            class="divide-y divide-base-300 border-y border-base-300"
          >
            <li :for={{dom_id, query} <- @streams.queries} id={dom_id} class="space-y-2 py-4">
              <div class="flex flex-wrap justify-between gap-2">
                <h2 class="font-semibold">{query.player_name} — Hole {query.display_hole_number}</h2>
                <p class="font-semibold">{label(query.status)}</p>
              </div>
              <p>Current score: {score(query)}</p>
              <p>Query reason: {query.reason}</p>
              <p>
                Query revision: {query.recorded_revision}; current result revision: {query.current_revision}
              </p>
              <p :if={query.stale?}>This query refers to an earlier result revision.</p>
              <p>Current verification: {label(query.verification_status)}</p>
              <p :if={query.historical_verification_status}>
                Historical verification: {label(query.historical_verification_status)}
              </p>
              <div :if={query.status in [:resolved, :dismissed]}>
                <p>Resolution reason: {query.resolution_reason}</p>
                <p>Recorded at: {to_string(query.resolved_at)}</p>
                <p :if={query.resolved_by_staff_user_id}>
                  Recorded by staff: {query.resolved_by_staff_user_id}
                </p>
                <p :if={query.resolved_by_round_entry_id}>
                  Recorded by player entry: {query.resolved_by_round_entry_id}
                </p>
              </div>
            </li>
          </ul>
          <button
            :if={@next_cursor}
            type="button"
            id="load-more-queries"
            phx-click="load_more"
            class="min-h-11 rounded-lg border border-base-content px-4 py-2 text-sm font-semibold hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
          >Load more</button>
        </section>
      </AppShell.staff>
    </Layouts.app>
    """
  end

  defp score(%{current_outcome: :picked_up}), do: "Picked up"
  defp score(%{current_gross_strokes: strokes}), do: "#{strokes} strokes"

  defp label(value),
    do: value |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
end
