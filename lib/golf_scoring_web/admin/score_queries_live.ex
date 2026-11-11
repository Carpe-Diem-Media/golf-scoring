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
     |> assign(:loaded, %{})
     |> assign(:selection, nil)
     |> assign(:message, nil)
     |> assign(:reason_form, to_form(%{"reason" => ""}, as: :decision))
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

  def handle_event("select_decision", %{"id" => id, "decision" => decision}, socket)
      when decision in ["resolve", "dismiss"] do
    case socket.assigns.loaded[id] do
      %{status: status, stale?: false} = query when status in [:open, :escalated] ->
        selection = %{query: query, decision: decision}

        {:noreply,
         socket
         |> assign(:selection, selection)
         |> assign(:message, nil)
         |> assign(:reason_form, to_form(%{"reason" => ""}, as: :decision))}

      _ ->
        {:noreply,
         socket
         |> assign(:selection, nil)
         |> assign(:message, "This decision is unavailable. Refresh and review the query.")}
    end
  end

  def handle_event("select_decision", _params, socket),
    do: {:noreply, assign(socket, :selection, nil)}

  def handle_event("cancel_decision", _params, socket),
    do: {:noreply, socket |> maybe_clear_selection(true) |> assign(:message, nil)}

  def handle_event(
        "confirm_decision",
        %{"decision" => %{"reason" => reason}},
        %{assigns: %{selection: %{query: query, decision: decision}}} = socket
      ) do
    if valid_reason?(reason) do
      command = %{
        score_query_id: query.id,
        expected_revision: query.recorded_revision,
        reason: String.trim(reason)
      }

      result = decide(socket, decision, command)

      case result do
        {:ok, _} ->
          {:noreply, socket |> assign(:message, "Decision recorded.") |> refresh()}

        {:error, :not_found_or_forbidden} ->
          {:noreply, unavailable(socket)}

        {:error, _} ->
          {:noreply,
           socket
           |> assign(
             :message,
             "The query or its review state changed. Review the current information before trying again."
           )
           |> refresh()}
      end
    else
      {:noreply,
       socket
       |> assign(:message, "Enter a reason of at most 4096 bytes.")
       |> assign(
         :reason_form,
         to_form(
           %{"reason" => if(is_binary(reason) and String.valid?(reason), do: reason, else: "")},
           as: :decision
         )
       )}
    end
  end

  def handle_event("confirm_decision", _params, socket),
    do: {:noreply, assign(socket, :selection, nil)}

  defp decide(socket, decision, command) do
    case decision do
      "resolve" ->
        Scoring.resolve_score_query_no_change(
          socket.assigns.staff,
          socket.assigns.event_id,
          socket.assigns.round_id,
          command
        )

      "dismiss" ->
        Scoring.dismiss_score_query(
          socket.assigns.staff,
          socket.assigns.event_id,
          socket.assigns.round_id,
          command
        )
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp maybe_clear_selection(socket, true) do
    socket
    |> assign(:selection, nil)
    |> assign(:reason_form, to_form(%{"reason" => ""}, as: :decision))
  end

  defp maybe_clear_selection(socket, false), do: socket

  defp valid_reason?(reason),
    do:
      is_binary(reason) and byte_size(reason) <= 4096 and String.valid?(reason) and
        String.trim(reason) != ""

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
        loaded = if reset?, do: %{}, else: socket.assigns.loaded

        loaded =
          Enum.reduce(page.items, loaded, fn query, acc ->
            Map.put(
              acc,
              query.id,
              Map.take(query, [
                :id,
                :status,
                :stale?,
                :recorded_revision,
                :player_name,
                :display_hole_number,
                :current_outcome,
                :current_gross_strokes
              ])
            )
          end)

        socket
        |> assign(:loaded, loaded)
        |> maybe_clear_selection(reset?)
        |> assign(:available?, true)
        |> assign(:next_cursor, page.next_cursor)
        |> assign(:empty?, reset? and page.items == [])
        |> stream(:queries, page.items, reset: reset?)

      {:error, _} ->
        unavailable(socket)
    end
  end

  defp unavailable(socket) do
    socket
    |> assign(:available?, false)
    |> assign(:next_cursor, nil)
    |> assign(:empty?, true)
    |> assign(:loaded, %{})
    |> assign(:selection, nil)
    |> assign(:message, nil)
    |> assign(:reason_form, to_form(%{"reason" => ""}, as: :decision))
    |> stream(:queries, [], reset: true)
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
          <p :if={@message} id="decision-message" role="status">{@message}</p>
          <section
            :if={@selection}
            aria-labelledby="decision-heading"
            class="space-y-3 border border-base-300 p-4"
          >
            <h2 id="decision-heading" class="font-semibold">
              Confirm {if @selection.decision == "resolve",
                do: "resolve without score change",
                else: "dismissal"}
            </h2>
            <p>
              {@selection.query.player_name}, hole {@selection.query.display_hole_number}: {score(
                @selection.query
              )}, revision {@selection.query.recorded_revision}
            </p>
            <.form
              for={@reason_form}
              id="decision-form"
              phx-submit="confirm_decision"
              class="space-y-3"
            >
              <.input
                field={@reason_form[:reason]}
                type="textarea"
                label="Decision reason"
                class="w-full rounded-lg border border-base-content bg-base-100 px-3 py-2 text-base-content focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                required
              />
              <button
                type="submit"
                class="min-h-11 rounded-lg border border-base-content px-4 py-2 font-semibold focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
              >Confirm decision</button>
              <button
                type="button"
                phx-click="cancel_decision"
                class="min-h-11 rounded-lg border border-base-content px-4 py-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
              >Cancel</button>
            </.form>
          </section>
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
              <div
                :if={query.status in [:open, :escalated] and !query.stale?}
                class="flex flex-wrap gap-2"
              >
                <button
                  type="button"
                  phx-click="select_decision"
                  phx-value-id={query.id}
                  phx-value-decision="resolve"
                  aria-label={"Resolve without score change for #{query.player_name}, hole #{query.display_hole_number}"}
                  class="min-h-11 rounded-lg border border-base-content px-4 py-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                >Resolve — no score change</button>
                <button
                  type="button"
                  phx-click="select_decision"
                  phx-value-id={query.id}
                  phx-value-decision="dismiss"
                  aria-label={"Dismiss query for #{query.player_name}, hole #{query.display_hole_number}"}
                  class="min-h-11 rounded-lg border border-base-content px-4 py-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                >Dismiss</button>
              </div>
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
