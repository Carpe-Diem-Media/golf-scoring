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

  @type replay_rejection_reason ::
          :invalid_submission
          | :stale_authority
          | :stale_group_revision
          | :wrong_hole
          | :round_closed
          | :group_complete
          | :scoring_unavailable

  @type replay_receipt :: %{
          required(:id) => Ecto.UUID.t(),
          required(:client_submission_id) => Ecto.UUID.t(),
          required(:round_id) => Ecto.UUID.t(),
          required(:playing_group_id) => Ecto.UUID.t(),
          required(:round_hole_id) => Ecto.UUID.t(),
          required(:expected_group_score_revision) => non_neg_integer(),
          required(:group_role_assignment_id) => Ecto.UUID.t(),
          required(:role_assignment_version) => pos_integer(),
          required(:submitted_by_round_entry_id) => Ecto.UUID.t(),
          required(:captured_at) => String.t(),
          required(:payload_fingerprint) => String.t(),
          required(:submitted_payload) => map(),
          required(:source) => String.t()
        }

  @type replay_response ::
          %{required(:status) => :accepted, required(:receipt) => replay_receipt()}
          | %{required(:status) => :rejected, required(:reason) => replay_rejection_reason()}

  @type event_reply ::
          {:noreply, Phoenix.LiveView.Socket.t()}
          | {:reply, replay_response(), Phoenix.LiveView.Socket.t()}

  @impl true
  def mount(params, _session, socket) do
    case load_scorecard(params, socket.assigns.current_player_access_grant) do
      {:ok, data} ->
        {:ok, assign_scorecard(socket, data)}

      {:error, reason} ->
        {:ok, assign_unavailable(socket, reason)}
    end
  end

  @spec handle_event(binary(), map(), Phoenix.LiveView.Socket.t()) :: event_reply()
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
        "submit_queued_hole",
        %{"command" => command},
        %{assigns: %{lifecycle: lifecycle}} = socket
      )
      when lifecycle in [:scoring_active, :group_play_complete] do
    handle_queued_command(command, socket)
  end

  def handle_event("submit_queued_hole", _params, socket) do
    {:reply, %{status: :rejected, reason: :scoring_unavailable}, socket}
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
        <section
          id="group-scorecard"
          phx-hook={if @lifecycle in [:scoring_active, :group_play_complete], do: "ScoringQueue"}
          data-scorecard-lifecycle={@lifecycle}
          data-scoring-queue-projection={
            if @lifecycle in [:scoring_active, :group_play_complete], do: @offline_projection
          }
          class="space-y-5"
        >
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
              <dd class="scorecard-id break-all"><code class="font-mono">{@event_id}</code></dd>
              <dt class="font-medium text-base-content">Round ID</dt>
              <dd class="scorecard-id break-all"><code class="font-mono">{@round_id}</code></dd>
            </dl>
            <p id="course-context" class="mt-1 text-sm text-base-content/75">{@course_name}</p>
            <p id="group-identity" class="mt-1 text-sm text-base-content/75">
              Group {@group_label}
            </p>
            <p class="mt-4 text-sm font-medium">18 holes complete</p>
            <p id="holes-remaining" class="mt-1 text-sm text-base-content/75">
              {@remaining_holes} remaining
            </p>
            <p
              id="scoring-sync-status"
              class="mt-4 text-sm font-medium text-base-content/75"
              role="status"
              aria-live="polite"
            >
              <span id="scoring-sync-label">Checking sync</span>
              <span id="scoring-pending-count" class="ml-1" hidden>0 pending</span>
            </p>
            <p
              id="scorecard-feedback"
              class="mt-2 text-sm font-medium text-error"
              role="status"
              hidden
            >
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
                    <dd class="scorecard-id break-all"><code class="font-mono">{@event_id}</code></dd>
                    <dt class="font-medium text-base-content">Round ID</dt>
                    <dd class="scorecard-id break-all"><code class="font-mono">{@round_id}</code></dd>
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
                  <span id="completed-holes-label" class="text-base-content/70">
                    {@completed_holes} of 18 holes complete
                  </span>
                  <span id="holes-remaining" class="text-base-content/70">
                    {@remaining_holes} remaining
                  </span>
                </div>
                <progress
                  id="holes-complete-progress"
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
                data-scorecard-entry-id={entry.id}
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
                    <dd id={"scorecard-distance-#{entry.index}"} class="mt-0.5 font-medium">
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
                    <dd
                      id={"scorecard-handicap-strokes-#{entry.index}"}
                      class="mt-0.5 font-medium"
                    >
                      {entry.handicap_strokes_label}
                    </dd>
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
                  id="scoring-sync-status"
                  class="text-center text-sm font-medium text-base-content/75"
                  role="status"
                  aria-live="polite"
                >
                  <span id="scoring-sync-label">Checking sync</span>
                  <span id="scoring-pending-count" class="ml-1" hidden>0 pending</span>
                </p>
                <p
                  id="scorecard-feedback"
                  class="text-center text-sm font-medium text-error"
                  role="status"
                  hidden={is_nil(@feedback)}
                >
                  {@feedback || ""}
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

  defp normalize_queued_command(command, socket) when is_map(command) do
    allowed_keys = [
      "client_submission_id",
      "playing_group_id",
      "round_hole_id",
      "expected_group_score_revision",
      "role_assignment_version",
      "captured_at",
      "results"
    ]

    with true <- Enum.all?(Map.keys(command), &(&1 in allowed_keys)),
         {:ok, client_submission_id} <- Ecto.UUID.cast(command["client_submission_id"]),
         {:ok, playing_group_id} <- Ecto.UUID.cast(command["playing_group_id"]),
         true <- playing_group_id == socket.assigns.group_id,
         {:ok, round_hole_id} <- Ecto.UUID.cast(command["round_hole_id"]),
         {:ok, expected_group_score_revision} <-
           parse_non_negative_integer(command["expected_group_score_revision"]),
         {:ok, role_assignment_version} <-
           parse_positive_integer(command["role_assignment_version"]),
         {:ok, captured_at} <- parse_datetime(command["captured_at"]),
         {:ok, results} <- normalize_queued_results(socket.assigns.entries, command["results"]) do
      {:ok,
       %{
         client_submission_id: client_submission_id,
         playing_group_id: playing_group_id,
         round_hole_id: round_hole_id,
         expected_group_score_revision: expected_group_score_revision,
         role_assignment_version: role_assignment_version,
         captured_at: captured_at,
         results: results
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp normalize_queued_command(_command, _socket), do: {:error, :invalid_input}

  defp handle_queued_command(command, socket) do
    case normalize_queued_command(command, socket) do
      {:ok, command} -> submit_if_replayable(command, socket)
      {:error, reason} -> rejected_reply(socket, normalize_rejection_reason(reason))
    end
  end

  defp submit_if_replayable(command, socket) do
    if replayable_command?(command, socket) do
      submit_queued_command(command, socket)
    else
      rejected_reply(socket, :group_complete)
    end
  end

  defp rejected_reply(socket, reason) do
    {:reply, %{status: :rejected, reason: reason}, socket}
  end

  defp replayable_command?(_command, %{assigns: %{lifecycle: :scoring_active}}), do: true

  defp replayable_command?(command, %{assigns: %{lifecycle: :group_play_complete} = assigns}) do
    route = assigns.scorecard_data.rotated_route

    length(route) == 18 and
      assigns.scorecard_data.revision == 18 and
      command.expected_group_score_revision == 17 and
      same_uuid?(command.round_hole_id, List.last(route).id)
  end

  defp replayable_command?(_command, _socket), do: false

  defp submit_queued_command(command, socket) do
    case Scoring.submit_group_hole(
           socket.assigns.current_player_access_grant,
           socket.assigns.event_id,
           socket.assigns.round_id,
           command
         ) do
      {:ok, receipt} ->
        reply = %{status: :accepted, receipt: project_receipt(receipt)}
        {:reply, reply, refreshed_scorecard_socket(socket, "Hole saved")}

      {:error, reason} ->
        {:reply, %{status: :rejected, reason: normalize_rejection_reason(reason)}, socket}
    end
  end

  defp same_uuid?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(left) == String.downcase(right)
  end

  defp same_uuid?(_left, _right), do: false

  defp normalize_queued_results(entries, values)
       when is_list(values) and length(values) in 2..4 do
    entries_by_id = Map.new(entries, &{String.downcase(&1.id), &1})

    with {:ok, results} <-
           Enum.reduce_while(
             values,
             {:ok, %{}},
             &collect_queued_result(&1, &2, entries_by_id)
           ),
         true <- MapSet.new(Map.keys(results)) == MapSet.new(Map.keys(entries_by_id)) do
      {:ok, Enum.map(entries, &Map.fetch!(results, String.downcase(&1.id)))}
    else
      _ -> {:error, :incomplete_results}
    end
  end

  defp normalize_queued_results(_entries, _values), do: {:error, :incomplete_results}

  defp collect_queued_result(value, {:ok, results_by_id}, entries_by_id) do
    case normalize_queued_result(value, entries_by_id) do
      {:ok, entry_id, result} when not is_map_key(results_by_id, entry_id) ->
        {:cont, {:ok, Map.put(results_by_id, entry_id, result)}}

      _ ->
        {:halt, {:error, :incomplete_results}}
    end
  end

  defp normalize_queued_result(value, entries_by_id) when is_map(value) do
    allowed_keys = ["round_entry_id", "outcome", "gross_strokes", "strokes_taken"]

    with true <- Enum.all?(Map.keys(value), &(&1 in allowed_keys)),
         {:ok, entry_id} <- Ecto.UUID.cast(value["round_entry_id"]),
         normalized_id = String.downcase(entry_id),
         %{} = entry <- Map.get(entries_by_id, normalized_id),
         {:ok, result} <- normalize_result(entry, value) do
      {:ok, normalized_id, result}
    else
      _ -> {:error, :incomplete_results}
    end
  end

  defp normalize_queued_result(_value, _entries_by_id), do: {:error, :incomplete_results}

  defp project_receipt(receipt) do
    %{
      id: receipt.id,
      client_submission_id: receipt.client_submission_id,
      round_id: receipt.round_id,
      playing_group_id: receipt.playing_group_id,
      round_hole_id: receipt.round_hole_id,
      expected_group_score_revision: receipt.expected_group_score_revision,
      group_role_assignment_id: receipt.group_role_assignment_id,
      role_assignment_version: receipt.role_assignment_version,
      submitted_by_round_entry_id: receipt.submitted_by_round_entry_id,
      captured_at: DateTime.to_iso8601(receipt.captured_at),
      payload_fingerprint: Base.encode16(receipt.payload_fingerprint, case: :lower),
      submitted_payload: project_submitted_payload(receipt.submitted_payload),
      source: receipt.source
    }
  end

  defp project_submitted_payload(payload) do
    actor = payload_field(payload, :actor)

    %{
      playing_group_id: payload_field(payload, :playing_group_id),
      round_hole_id: payload_field(payload, :round_hole_id),
      expected_group_score_revision: payload_field(payload, :expected_group_score_revision),
      role_assignment_version: payload_field(payload, :role_assignment_version),
      captured_at: payload_field(payload, :captured_at),
      actor: %{
        type: payload_field(actor, :type),
        round_entry_id: payload_field(actor, :round_entry_id),
        role_assignment_version: payload_field(actor, :role_assignment_version)
      },
      results:
        payload
        |> payload_field(:results)
        |> Enum.map(fn result ->
          %{
            round_entry_id: payload_field(result, :round_entry_id),
            outcome: payload_field(result, :outcome),
            gross_strokes: payload_field(result, :gross_strokes),
            strokes_taken: payload_field(result, :strokes_taken)
          }
        end)
    }
  end

  defp payload_field(value, key) when is_map(value) do
    Map.get(value, key, Map.get(value, Atom.to_string(key)))
  end

  defp payload_field(_value, _key), do: nil

  defp normalize_rejection_reason(reason)
       when reason in [:stale_role_assignment, :not_primary_scorer, :not_assigned],
       do: :stale_authority

  defp normalize_rejection_reason(:stale_scoring_revision), do: :stale_group_revision
  defp normalize_rejection_reason(:wrong_round_hole), do: :wrong_hole
  defp normalize_rejection_reason(:group_scoring_complete), do: :group_complete

  defp normalize_rejection_reason({:invalid_group_state, state})
       when state in [:finished_playing, "finished_playing"], do: :group_complete

  defp normalize_rejection_reason({:invalid_round_state, _state}), do: :round_closed
  defp normalize_rejection_reason(_reason), do: :invalid_submission

  defp parse_non_negative_integer(value) do
    with {:ok, parsed} <- parse_integer(value), true <- parsed >= 0 do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_integer}
    end
  end

  defp parse_positive_integer(value) do
    with {:ok, parsed} <- parse_integer(value), true <- parsed > 0 do
      {:ok, parsed}
    else
      _ -> {:error, :invalid_integer}
    end
  end

  defp refreshed_scorecard_socket(socket, feedback) do
    case Scoring.load_group_scorecard(
           socket.assigns.current_player_access_grant,
           socket.assigns.event_id,
           socket.assigns.round_id,
           socket.assigns.group_id
         ) do
      {:ok, data} ->
        assign_scorecard(socket, data) |> assign(:feedback, feedback)

      {:error, reason} ->
        assign_unavailable(socket, reason) |> assign(:feedback, feedback)
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
    |> assign(:offline_projection, Jason.encode!(offline_projection(data)))
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

  defp offline_projection(data) do
    blank_results = default_result_values(data.players)

    route =
      Enum.map(data.rotated_route, fn hole ->
        players =
          Scoring.preview_group_scorecard(%{data | current_hole: hole}, blank_results)
          |> Enum.map(fn player ->
            %{
              round_entry_id: player.id,
              par: player.current_fact.par,
              stroke_index: player.current_fact.stroke_index,
              distance_m: player.current_fact.distance_m,
              handicap_strokes_label: player.handicap_strokes_label
            }
          end)

        %{
          id: hole.id,
          display_hole_number: hole.display_hole_number,
          players: players
        }
      end)

    %{
      scope: %{
        event_id: data.event_id,
        round_id: data.round_id,
        playing_group_id: data.group_id,
        scorer: %{type: "player", round_entry_id: data.scorer_round_entry_id}
      },
      assignment: %{
        id: data.primary_scorer_assignment_id,
        round_entry_id: data.scorer_round_entry_id,
        assignment_version: data.assignment_version
      },
      active_round_entry_ids: Enum.map(data.players, & &1.id),
      revision: data.revision,
      route: route
    }
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
