defmodule GolfScoringWeb.Scoring.GroupScorecardLive do
  @moduledoc """
  Presents the authorized online group scorecard and adapts hole results to
  `GolfScoring.Scoring`.

  Scoring-state interpretation, authorization, and score previews belong to
  the Scoring domain; accepted whole-hole submissions go through its existing
  `SubmitGroupHole` service.
  """

  use GolfScoringWeb, :live_view

  alias GolfScoring.Scoring

  @impl true
  def mount(params, _session, socket) do
    case load_scorecard(params, socket.assigns.current_player_access_grant) do
      {:ok, data} ->
        {:ok, assign_scorecard(socket, data)}

      {:error, reason} ->
        {:ok, assign_unavailable(socket, reason)}
    end
  end

  @impl true
  def handle_event("update_results", %{"scorecard" => params}, socket) do
    values = Map.get(params, "results", %{})

    {:noreply,
     socket
     |> assign(:result_values, values)
     |> assign(:feedback, nil)
     |> refresh_previews()}
  end

  @impl true
  def handle_event(
        "submit_hole",
        %{"scorecard" => params},
        %{assigns: %{lifecycle: :scoring_active}} = socket
      ) do
    values = Map.get(params, "results", %{})
    socket = socket |> assign(:result_values, values) |> refresh_previews()

    with {:ok, expected_revision} <- parse_integer(params["expected_group_score_revision"]),
         {:ok, hole_id} <- Ecto.UUID.cast(params["round_hole_id"]),
         {:ok, client_submission_id} <- Ecto.UUID.cast(params["client_submission_id"]),
         {:ok, captured_at} <- parse_datetime(params["captured_at"]),
         {:ok, results} <- normalize_results(socket.assigns.entries, values) do
      command = %{
        client_submission_id: client_submission_id,
        playing_group_id: socket.assigns.group_id,
        round_hole_id: hole_id,
        expected_group_score_revision: expected_revision,
        role_assignment_version: socket.assigns.assignment_version,
        captured_at: captured_at,
        results: results
      }

      submit_hole(socket, command)
    else
      {:error, :incomplete_results} ->
        {:noreply, assign(socket, :feedback, "Complete every golfer's result before submitting.")}

      _ ->
        {:noreply, assign(socket, :feedback, "Refresh the scorecard before submitting.")}
    end
  end

  def handle_event("submit_hole", _params, socket) do
    {:noreply, assign(socket, :feedback, "Scoring is unavailable for this group.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.player
        flash={@flash}
        page_title="Group scorecard"
        player_name={@player_name}
        current_path={@current_path}
      >
        <section id="group-scorecard" class="space-y-5">
          <section
            :if={@lifecycle == :unavailable}
            id="scorecard-unavailable"
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            role="status"
          >
            <h2 class="text-lg font-semibold">Scorecard unavailable</h2>
            <p class="mt-2 text-sm text-base-content/75">{@unavailable_message}</p>
          </section>

          <section
            :if={@lifecycle == :group_play_complete}
            id="group-play-complete"
            class="rounded-2xl border border-success/30 bg-success/5 p-5 shadow-sm"
            role="status"
          >
            <p class="text-sm font-medium text-base-content">Round complete</p>
            <h2 class="mt-1 text-xl font-semibold">Group play complete</h2>
            <p class="mt-2 text-sm text-base-content/75">All 18 holes have been recorded.</p>
            <dl
              id="event-round-context"
              class="mt-4 grid grid-cols-[4.25rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-xs leading-5 text-base-content/70"
            >
              <dt class="font-medium text-base-content">Event ID</dt>
              <dd class="break-all font-mono">{@event_id}</dd>
              <dt class="font-medium text-base-content">Round ID</dt>
              <dd class="break-all font-mono">{@round_id}</dd>
            </dl>
            <p id="course-context" class="mt-1 text-sm text-base-content/75">{@course_name}</p>
            <p id="group-identity" class="mt-1 text-sm text-base-content/75">
              Group {@group_label}
            </p>
            <p class="mt-4 text-sm font-medium">18 holes complete</p>
            <p id="holes-remaining" class="mt-1 text-sm text-base-content/75">
              {@remaining_holes} remaining
            </p>
          </section>

          <div :if={@lifecycle == :scoring_active} class="space-y-5">
            <header class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <dl
                    id="event-round-context"
                    class="grid grid-cols-[4.25rem_minmax(0,1fr)] gap-x-2 gap-y-1 text-xs leading-5 text-base-content/70"
                  >
                    <dt class="font-medium text-base-content">Event ID</dt>
                    <dd class="break-all font-mono">{@event_id}</dd>
                    <dt class="font-medium text-base-content">Round ID</dt>
                    <dd class="break-all font-mono">{@round_id}</dd>
                  </dl>
                  <p id="course-context" class="mt-1 truncate text-sm font-medium">
                    {@course_name}
                  </p>
                  <p id="group-identity" class="mt-1 text-xs text-base-content/70">
                    Group {@group_label}
                  </p>
                  <h2 id="current-hole" class="mt-2 text-2xl font-semibold tracking-tight">
                    Hole {@current_hole.display_hole_number}
                  </h2>
                  <p id="starting-hole" class="mt-1 text-sm text-base-content/75">
                    Starting hole {@starting_hole_label}
                  </p>
                </div>
                <span class="rounded-full bg-base-200 px-3 py-1 text-sm font-semibold">
                  {@completed_holes} of 18
                </span>
              </div>

              <div class="mt-4 space-y-2">
                <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-sm">
                  <span class="font-medium">{@entry_count} golfers</span>
                  <span class="text-base-content/70">{@completed_holes} of 18 holes complete</span>
                  <span id="holes-remaining" class="text-base-content/70">
                    {@remaining_holes} remaining
                  </span>
                </div>
                <progress
                  class="block h-2 w-full accent-primary"
                  value={@completed_holes}
                  max="18"
                  aria-label="Holes complete"
                />
              </div>

              <p class="mt-3 text-xs text-base-content/70">
                Physical route: <span id="physical-route">{@route_display}</span>
              </p>
            </header>

            <.form
              for={@scorecard_form}
              id="scorecard-entry-form"
              phx-change="update_results"
              phx-submit="submit_hole"
              class="space-y-4"
            >
              <.input
                type="hidden"
                name="scorecard[expected_group_score_revision]"
                value={@group_revision}
              />
              <.input
                type="hidden"
                name="scorecard[round_hole_id]"
                value={@current_hole.id}
              />
              <.input
                type="hidden"
                name="scorecard[client_submission_id]"
                value={@client_submission_id}
              />
              <.input
                type="hidden"
                name="scorecard[captured_at]"
                value={@captured_at}
              />

              <article
                :for={entry <- @entries}
                id={"scorecard-player-#{entry.index}"}
                class="rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <h3 class="truncate text-lg font-semibold">{entry.name}</h3>
                    <p class="mt-1 text-xs text-base-content/70">
                      {entry.tee_set_name} tee, {entry.rating_label} rating
                    </p>
                  </div>
                  <div class="shrink-0 rounded-xl bg-base-200 px-3 py-2 text-center">
                    <p
                      id={"scorecard-par-#{entry.index}"}
                      class="text-sm font-semibold"
                    >
                      Par {entry.current_fact.par}
                    </p>
                  </div>
                </div>

                <dl class="mt-4 grid grid-cols-2 gap-x-4 gap-y-3 text-sm">
                  <div>
                    <dt class="text-xs text-base-content/65">Stroke Index</dt>
                    <dd
                      id={"scorecard-stroke-index-#{entry.index}"}
                      class="mt-0.5 font-medium"
                    >
                      {entry.current_fact.stroke_index}
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs text-base-content/65">Distance</dt>
                    <dd class="mt-0.5 font-medium">
                      <%= if entry.current_fact.distance_m do %>
                        {entry.current_fact.distance_m} m
                      <% else %>
                        Not recorded
                      <% end %>
                    </dd>
                  </div>
                  <div>
                    <dt class="text-xs text-base-content/65">Handicap index</dt>
                    <dd class="mt-0.5 font-medium">{entry.handicap_index_label}</dd>
                  </div>
                  <div>
                    <dt class="text-xs text-base-content/65">Playing handicap</dt>
                    <dd class="mt-0.5 font-medium">{entry.playing_handicap}</dd>
                  </div>
                  <div class="col-span-2">
                    <dt class="text-xs text-base-content/65">Handicap strokes</dt>
                    <dd class="mt-0.5 font-medium">{entry.handicap_strokes_label}</dd>
                  </div>
                </dl>

                <div class="mt-4 grid grid-cols-2 gap-3">
                  <.input
                    type="select"
                    id={"scorecard-result-#{entry.id}"}
                    name={"scorecard[results][#{entry.id}][outcome]"}
                    label="Outcome"
                    prompt="Choose result"
                    value={entry.result_value["outcome"]}
                    options={entry.outcome_options}
                    class="w-full rounded-lg border border-base-content/50 bg-base-100 px-3 py-2 text-base text-base-content shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                  />
                  <.input
                    type="number"
                    id={"scorecard-gross-#{entry.id}"}
                    name={"scorecard[results][#{entry.id}][gross_strokes]"}
                    label="Gross strokes"
                    value={entry.result_value["gross_strokes"]}
                    min="1"
                    step="1"
                    inputmode="numeric"
                    placeholder="Strokes"
                    class="w-full rounded-lg border border-base-content/50 bg-base-100 px-3 py-2 text-base text-base-content shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content disabled:cursor-not-allowed disabled:opacity-60"
                    disabled={entry.result_value["outcome"] == "picked_up"}
                  />
                  <div :if={entry.result_value["outcome"] == "picked_up"} class="col-span-2">
                    <.input
                      type="number"
                      id={"scorecard-strokes-taken-#{entry.id}"}
                      name={"scorecard[results][#{entry.id}][strokes_taken]"}
                      label="Strokes taken before pickup"
                      value={entry.result_value["strokes_taken"]}
                      min="0"
                      step="1"
                      inputmode="numeric"
                      placeholder="Strokes before picking up"
                      class="w-full rounded-lg border border-base-content/50 bg-base-100 px-3 py-2 text-base text-base-content shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                    />
                  </div>
                  <div :if={entry.result_value["outcome"] != "picked_up"} class="col-span-2">
                    <.input
                      type="number"
                      id={"scorecard-strokes-taken-#{entry.id}"}
                      name={"scorecard[results][#{entry.id}][strokes_taken]"}
                      label="Strokes taken before pickup"
                      value={entry.result_value["strokes_taken"]}
                      min="0"
                      step="1"
                      inputmode="numeric"
                      placeholder="Enter strokes to check pickup"
                      class="w-full rounded-lg border border-base-content/50 bg-base-100 px-3 py-2 text-base text-base-content shadow-sm focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content"
                    />
                  </div>
                </div>

                <p :if={entry.pickup_eligible?} class="mt-1 text-sm font-medium text-success">
                  Pickup is available. This result scores no points.
                </p>
                <p
                  :if={entry.result_value["outcome"] == "picked_up" and !entry.pickup_eligible?}
                  class="mt-1 text-sm text-warning"
                >
                  Pickup is not eligible yet. Check the strokes taken.
                </p>

                <div
                  :if={entry.preview}
                  class="mt-4 flex items-center justify-between rounded-xl bg-base-200/70 px-3 py-2 text-sm"
                >
                  <span :if={entry.preview.handicap_adjusted}>
                    Handicap adjusted {entry.preview.handicap_adjusted}
                  </span>
                  <span :if={entry.preview.points != nil} class="font-semibold">
                    Stableford {entry.preview.points}
                  </span>
                </div>
              </article>

              <div class="mt-4 space-y-2">
                <p
                  :if={@feedback}
                  id="scorecard-feedback"
                  class="text-center text-sm font-medium text-error"
                  role="status"
                >
                  {@feedback}
                </p>
                <button
                  type="submit"
                  id="submit-group-hole"
                  class="inline-flex min-h-12 w-full items-center justify-center whitespace-nowrap rounded-xl bg-primary px-4 text-base font-semibold text-base-content shadow-sm transition hover:brightness-95 active:scale-[0.99] active:brightness-95 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content motion-reduce:transform-none"
                >
                  Save hole for group
                </button>
              </div>
            </.form>
          </div>
        </section>
      </AppShell.player>
    </Layouts.app>
    """
  end

  defp submit_hole(socket, command) do
    result =
      Scoring.submit_group_hole(
        socket.assigns.current_player_access_grant,
        socket.assigns.event_id,
        socket.assigns.round_id,
        command
      )

    handle_submission_result(socket, result)
  end

  defp handle_submission_result(socket, {:ok, receipt}) do
    feedback =
      if receipt.expected_group_score_revision < socket.assigns.group_revision do
        "This scorecard has moved to a newer hole."
      else
        "Hole saved"
      end

    refresh_scorecard(socket, feedback)
  end

  defp handle_submission_result(socket, {:error, reason}) do
    handle_submission_error(socket, reason)
  end

  defp handle_submission_error(socket, reason)
       when reason in [:stale_role_assignment, :not_primary_scorer] do
    {:noreply,
     assign_unavailable(socket, :scorer_changed)
     |> assign(:feedback, "The scorer assignment changed. This scorecard is no longer active.")}
  end

  defp handle_submission_error(socket, reason)
       when reason in [:stale_scoring_revision, :wrong_round_hole] do
    refresh_scorecard(socket, "This scorecard has moved to a newer hole.")
  end

  defp handle_submission_error(socket, :group_scoring_complete) do
    refresh_scorecard(socket, "This group has completed all 18 holes.")
  end

  defp handle_submission_error(socket, {:invalid_round_state, _state}) do
    {:noreply,
     assign_unavailable(socket, :round_not_open)
     |> assign(:feedback, "Scoring is unavailable while this round is not open.")}
  end

  defp handle_submission_error(socket, :pickup_not_eligible) do
    {:noreply,
     assign(socket, :feedback, "Pickup is available only when no Stableford point remains.")}
  end

  defp handle_submission_error(socket, :strokes_taken_required) do
    {:noreply, assign(socket, :feedback, "Enter strokes taken before selecting a pickup.")}
  end

  defp handle_submission_error(socket, _reason) do
    {:noreply,
     assign(socket, :feedback, "This hole could not be saved. Check every golfer's result.")}
  end

  defp refresh_scorecard(socket, feedback) do
    case Scoring.load_group_scorecard(
           socket.assigns.current_player_access_grant,
           socket.assigns.event_id,
           socket.assigns.round_id,
           socket.assigns.group_id
         ) do
      {:ok, data} ->
        {:noreply, assign_scorecard(socket, data) |> assign(:feedback, feedback)}

      {:error, reason} ->
        {:noreply, assign_unavailable(socket, reason) |> assign(:feedback, feedback)}
    end
  end

  defp load_scorecard(params, grant) do
    Scoring.load_group_scorecard(
      grant,
      params["event_id"],
      params["round_id"],
      params["group_id"]
    )
  end

  defp assign_scorecard(socket, data) do
    current_path =
      ~p"/player/events/#{data.event_id}/rounds/#{data.round_id}/groups/#{data.group_id}/scorecard"

    result_values = default_result_values(data.players)

    socket
    |> assign(:page_title, "Group scorecard")
    |> assign(:current_path, current_path)
    |> assign(:event_id, data.event_id)
    |> assign(:round_id, data.round_id)
    |> assign(:group_id, data.group_id)
    |> assign(:group_revision, data.revision)
    |> assign(:assignment_version, data.assignment_version)
    |> assign(:player_name, data.scorer_name)
    |> assign(:lifecycle, data.lifecycle)
    |> assign(:course_name, data.course_name)
    |> assign(:group_label, data.group_label)
    |> assign(:remaining_holes, data.remaining_holes)
    |> assign(:unavailable_message, nil)
    |> assign(:scorecard_data, data)
    |> assign(:entries, Scoring.preview_group_scorecard(data, result_values))
    |> assign(:entry_count, data.entry_count)
    |> assign(:current_hole, data.current_hole)
    |> assign(:starting_hole_label, data.starting_hole_label)
    |> assign(:completed_holes, data.completed_holes)
    |> assign(:route_display, data.route_display)
    |> assign(:result_values, result_values)
    |> assign(:scorecard_form, to_form(%{}, as: "scorecard"))
    |> assign(:client_submission_id, Ecto.UUID.generate())
    |> assign(:captured_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> assign(:feedback, nil)
  end

  defp assign_unavailable(socket, reason) do
    message =
      case reason do
        :round_not_open -> "Scoring is unavailable while this round is not open."
        :scorer_changed -> "The scorer assignment changed. This scorecard is no longer active."
        :not_primary_scorer -> "Only the active primary scorer can open this scorecard."
        _ -> "This scorecard is not available for your player access."
      end

    socket
    |> assign(:page_title, "Group scorecard")
    |> assign(:current_path, "/player")
    |> assign(:player_name, nil)
    |> assign(:lifecycle, :unavailable)
    |> assign(:unavailable_message, message)
    |> assign(:feedback, nil)
    |> assign(:scorecard_form, to_form(%{}, as: "scorecard"))
  end

  defp refresh_previews(%{assigns: %{lifecycle: :scoring_active}} = socket) do
    entries =
      Scoring.preview_group_scorecard(
        socket.assigns.scorecard_data,
        socket.assigns.result_values
      )

    assign(socket, :entries, entries)
  end

  defp refresh_previews(socket), do: socket

  defp default_result_values(players) do
    Map.new(players, fn player ->
      {player.id, %{"outcome" => "", "gross_strokes" => "", "strokes_taken" => ""}}
    end)
  end

  defp normalize_results(entries, values) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      result_value = Map.get(values, entry.id, %{})

      case normalize_result(entry, result_value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp normalize_result(entry, %{"outcome" => "holed_out"} = values) do
    with {:ok, gross} <- parse_integer(values["gross_strokes"]),
         true <- gross > 0 do
      {:ok, %{round_entry_id: entry.id, outcome: :holed_out, gross_strokes: gross}}
    else
      _ -> {:error, :incomplete_results}
    end
  end

  defp normalize_result(entry, %{"outcome" => "picked_up"} = values) do
    with true <- blank?(values["gross_strokes"]),
         {:ok, strokes_taken} <- parse_integer(values["strokes_taken"]),
         true <- strokes_taken >= 0 do
      {:ok,
       %{
         round_entry_id: entry.id,
         outcome: :picked_up,
         gross_strokes: nil,
         strokes_taken: strokes_taken
       }}
    else
      _ -> {:error, :incomplete_results}
    end
  end

  defp normalize_result(_entry, _values), do: {:error, :incomplete_results}

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_integer(_), do: {:error, :invalid_integer}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp blank?(value), do: value in [nil, ""]
end
