defmodule GolfScoringWeb.Scoring.GroupScorecardLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  alias Decimal, as: D
  alias GolfScoring.Competition.StartingPositionLabel
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.StablefordPoints
  alias GolfScoring.Scoring.Calculators.StrokeAllocation
  alias GolfScoring.Scoring.Policies.PickupEligibility

  @scheduled_holes 18

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
            <p class="text-sm font-medium text-success">Round complete</p>
            <h2 class="mt-1 text-xl font-semibold">Group play complete</h2>
            <p class="mt-2 text-sm text-base-content/75">All 18 holes have been recorded.</p>
            <p id="event-round-context" class="mt-4 text-sm font-medium">Event scorecard</p>
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
                  <p id="event-round-context" class="text-sm text-base-content/70">
                    Event scorecard
                  </p>
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
                  class="progress progress-primary h-2 w-full"
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
                    class="w-full select select-bordered border-base-content/50"
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
                    class="w-full input input-bordered border-base-content/50 disabled:cursor-not-allowed disabled:opacity-60"
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
                      class="w-full input input-bordered border-base-content/50"
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
                      class="w-full input input-bordered border-base-content/50"
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
                  class="btn btn-primary min-h-12 w-full whitespace-nowrap text-base text-base-content active:scale-[0.99] active:brightness-95 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-base-content motion-reduce:active:transform-none"
                >
                  Save hole for all golfers
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
    params = %{
      "event_id" => socket.assigns.event_id,
      "round_id" => socket.assigns.round_id,
      "group_id" => socket.assigns.group_id
    }

    case load_scorecard(params, socket.assigns.current_player_access_grant) do
      {:ok, data} ->
        {:noreply, assign_scorecard(socket, data) |> assign(:feedback, feedback)}

      {:error, reason} ->
        {:noreply,
         assign_unavailable(socket, reason)
         |> assign(:feedback, feedback)}
    end
  end

  defp load_scorecard(params, grant) do
    with {:ok, ids} <- route_ids(params),
         true <- ids.event_id == grant.event_id,
         {:ok, context} <- load_group_context(ids),
         :ok <- require_open_round(context.round_state),
         :ok <- require_primary_scorer(context, grant.player_id),
         {:ok, route} <- load_route(ids.round_id),
         {:ok, entries} <- load_entries(ids.round_id, ids.group_id),
         {:ok, data} <- build_scorecard_data(ids, context, route, entries) do
      {:ok, data}
    else
      false -> {:error, :not_assigned}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_ids(params) do
    with {:ok, event_id} <- Ecto.UUID.cast(params["event_id"]),
         {:ok, round_id} <- Ecto.UUID.cast(params["round_id"]),
         {:ok, group_id} <- Ecto.UUID.cast(params["group_id"]) do
      {:ok, %{event_id: event_id, round_id: round_id, group_id: group_id}}
    else
      _ -> {:error, :invalid_route}
    end
  end

  defp load_group_context(ids) do
    rows =
      Repo.query!(
        """
        SELECT r.state,
               pg.state,
               pg.scoring_revision::int,
               pg.starting_round_hole_id::text,
               pg.starting_position::int,
               assignment.id::text,
               assignment.assignment_version::int,
               scorer_entry.player_id::text,
               concat_ws(' ', scorer.first_name, scorer.surname),
               competition.pickup_policy_identifier,
               course.name
        FROM rounds r
        JOIN courses course ON course.id = r.course_id
        JOIN playing_groups pg ON pg.round_id = r.id
        LEFT JOIN group_role_assignments assignment
          ON assignment.playing_group_id = pg.id
          AND assignment.role = 'primary_scorer'
          AND assignment.state = 'active'
        LEFT JOIN round_entries scorer_entry ON scorer_entry.id = assignment.round_entry_id
        LEFT JOIN players scorer ON scorer.id = scorer_entry.player_id
        LEFT JOIN round_competitions competition
          ON competition.round_id = r.id AND competition.is_primary = true
        WHERE r.id = $1::uuid AND r.event_id = $2::uuid AND pg.id = $3::uuid
        """,
        [
          Ecto.UUID.dump!(ids.round_id),
          Ecto.UUID.dump!(ids.event_id),
          Ecto.UUID.dump!(ids.group_id)
        ]
      ).rows

    case rows do
      [
        [
          round_state,
          group_state,
          revision,
          start_hole_id,
          starting_position,
          assignment_id,
          assignment_version,
          scorer_player_id,
          scorer_name,
          pickup_policy,
          course_name
        ]
      ] ->
        {:ok,
         %{
           round_state: round_state,
           group_state: group_state,
           revision: revision,
           start_hole_id: cast_uuid(start_hole_id),
           starting_position: starting_position,
           assignment_id: cast_uuid(assignment_id),
           assignment_version: assignment_version,
           scorer_player_id: cast_uuid(scorer_player_id),
           scorer_name: scorer_name,
           pickup_policy: pickup_policy,
           course_name: course_name
         }}

      [] ->
        {:error, :not_found}

      _ ->
        {:error, :ambiguous_group_context}
    end
  end

  defp require_open_round("scoring_open"), do: :ok
  defp require_open_round(_), do: {:error, :round_not_open}

  defp require_primary_scorer(%{assignment_id: nil}, _player_id),
    do: {:error, :not_primary_scorer}

  defp require_primary_scorer(%{scorer_player_id: player_id}, player_id)
       when not is_nil(player_id),
       do: :ok

  defp require_primary_scorer(_, _), do: {:error, :not_primary_scorer}

  defp load_route(round_id) do
    holes =
      Repo.query!(
        "SELECT id::text, play_order::int, display_hole_number::int FROM round_holes WHERE round_id = $1::uuid ORDER BY play_order",
        [Ecto.UUID.dump!(round_id)]
      ).rows
      |> Enum.map(fn [id, play_order, display_hole_number] ->
        %{
          id: Ecto.UUID.cast!(id),
          play_order: play_order,
          display_hole_number: display_hole_number
        }
      end)

    if length(holes) == @scheduled_holes do
      {:ok, holes}
    else
      {:error, :invalid_route}
    end
  end

  defp load_entries(round_id, group_id) do
    rows =
      Repo.query!(
        """
        SELECT re.id::text,
               p.first_name,
               p.surname,
               re.registration_status,
               re.participation_status,
               re.round_tee_profile_snapshot_id::text,
               tee.tee_set_name,
               tee.rating_label,
               tee.course_rating::text,
               tee.slope_rating::int,
               tee.total_par::int,
               tee.applicable_par::int,
               handicap.source_handicap_index::text,
               handicap.deemed_handicap_basis::text,
               competition_handicap.playing_handicap::int
        FROM round_entries re
        JOIN players p ON p.id = re.player_id
        LEFT JOIN round_tee_profile_snapshots tee
          ON tee.id = re.round_tee_profile_snapshot_id
        LEFT JOIN LATERAL (
          SELECT hs.source_handicap_index, hs.deemed_handicap_basis
          FROM handicap_snapshots hs
          WHERE hs.round_entry_id = re.id AND hs.round_id = re.round_id
          ORDER BY hs.inserted_at DESC, hs.id
          LIMIT 1
        ) handicap ON true
        LEFT JOIN round_competitions competition
          ON competition.round_id = re.round_id AND competition.is_primary = true
        LEFT JOIN competition_handicaps competition_handicap
          ON competition_handicap.round_entry_id = re.id
          AND competition_handicap.round_competition_id = competition.id
        WHERE re.round_id = $1::uuid AND re.playing_group_id = $2::uuid
        ORDER BY re.inserted_at, re.id
        """,
        [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(group_id)]
      ).rows

    entries =
      Enum.map(rows, fn [
                          id,
                          first_name,
                          surname,
                          registration,
                          participation,
                          tee_snapshot_id,
                          tee_set_name,
                          rating_label,
                          course_rating,
                          slope_rating,
                          total_par,
                          applicable_par,
                          source_hi,
                          deemed_hi,
                          playing_handicap
                        ] ->
        %{
          id: Ecto.UUID.cast!(id),
          name: String.trim("#{first_name} #{surname}"),
          registration_status: registration,
          participation_status: participation,
          tee_snapshot_id: cast_uuid(tee_snapshot_id),
          tee_set_name: tee_set_name,
          rating_label: rating_label,
          course_rating: course_rating,
          slope_rating: slope_rating,
          total_par: total_par,
          applicable_par: applicable_par,
          handicap_index: source_hi || deemed_hi,
          playing_handicap: playing_handicap
        }
      end)

    {:ok, entries}
  end

  defp build_scorecard_data(ids, context, route, entries) do
    with {:ok, start_index} <- route_start_index(route, context.start_hole_id),
         rotated_route = rotate_route(route, start_index),
         :ok <- validate_group_state(context, entries),
         {:ok, players} <- build_players(entries, context.revision),
         true <- length(players) in 2..4 do
      complete? = context.revision >= @scheduled_holes
      current_hole = if complete?, do: nil, else: Enum.at(rotated_route, context.revision)

      if complete? or current_hole do
        {:ok,
         %{
           event_id: ids.event_id,
           round_id: ids.round_id,
           group_id: ids.group_id,
           revision: context.revision,
           assignment_version: context.assignment_version,
           scorer_name: context.scorer_name,
           pickup_policy: context.pickup_policy,
           route: route,
           rotated_route: rotated_route,
           starting_hole: Enum.at(route, start_index),
           starting_position: context.starting_position,
           group_label: StartingPositionLabel.position_letter(context.starting_position || 1),
           course_name: context.course_name,
           current_hole: current_hole,
           players: players,
           remaining_holes: max(@scheduled_holes - min(context.revision, @scheduled_holes), 0),
           lifecycle: if(complete?, do: :group_play_complete, else: :scoring_active)
         }}
      else
        {:error, :group_play_complete}
      end
    else
      false -> {:error, :invalid_group_size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_group_state(%{revision: revision}, _entries)
       when revision >= @scheduled_holes,
       do: :ok

  defp validate_group_state(%{revision: revision, group_state: state}, _entries)
       when revision >= 0 and state in ["not_started", "playing"],
       do: :ok

  defp validate_group_state(_, _), do: {:error, :group_unavailable}

  defp route_start_index(route, start_hole_id) do
    case Enum.find_index(route, &(&1.id == start_hole_id)) do
      nil -> {:error, :starting_hole_unavailable}
      index -> {:ok, index}
    end
  end

  defp rotate_route(route, index) do
    Enum.drop(route, index) ++ Enum.take(route, index)
  end

  defp build_players(entries, revision) do
    participation_statuses =
      if revision >= @scheduled_holes do
        ["completed"]
      else
        ["not_started", "active"]
      end

    entries
    |> Enum.filter(fn entry ->
      entry.registration_status in ["expected", "checked_in"] and
        entry.participation_status in participation_statuses
    end)
    |> build_all_player_facts()
  end

  defp build_all_player_facts(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case build_player_facts(entry) do
        {:ok, player} -> {:cont, {:ok, [player | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, players} ->
        players
        |> Enum.reverse()
        |> Enum.with_index()
        |> then(fn indexed ->
          {:ok, Enum.map(indexed, fn {entry, index} -> Map.put(entry, :index, index) end)}
        end)

      error ->
        error
    end
  end

  defp build_player_facts(%{tee_snapshot_id: nil}), do: {:error, :tee_not_assigned}

  defp build_player_facts(%{playing_handicap: nil}), do: {:error, :handicap_unavailable}

  defp build_player_facts(entry) do
    facts =
      Repo.query!(
        """
        SELECT round_hole_id::text, par::int, stroke_index::int, distance_m::int, plus_stroke_order::int
        FROM round_tee_hole_snapshots
        WHERE round_tee_profile_snapshot_id = $1::uuid
        ORDER BY round_hole_id
        """,
        [Ecto.UUID.dump!(entry.tee_snapshot_id)]
      ).rows
      |> Enum.map(fn [hole_id, par, stroke_index, distance_m, plus_order] ->
        %{
          round_hole_id: Ecto.UUID.cast!(hole_id),
          par: par,
          stroke_index: stroke_index,
          distance_m: distance_m,
          plus_stroke_order: plus_order
        }
      end)

    case StrokeAllocation.allocate(entry.playing_handicap, facts) do
      {:ok, %{strokes_by_round_hole_id: strokes}} ->
        {:ok,
         entry
         |> Map.put(:hole_facts, Map.new(facts, &{&1.round_hole_id, &1}))
         |> Map.put(:strokes_by_hole, strokes)
         |> Map.put(:handicap_index_label, format_handicap_index(entry.handicap_index))
         |> Map.put(:handicap_strokes_by_hole, strokes)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assign_scorecard(socket, data) do
    current_path =
      ~p"/player/events/#{data.event_id}/rounds/#{data.round_id}/groups/#{data.group_id}/scorecard"

    entries =
      if data.current_hole do
        prepare_players(data.players, data.current_hole, data.pickup_policy, %{})
      else
        data.players
      end

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
    |> assign(:entries, entries)
    |> assign(:entry_count, length(entries))
    |> assign(:current_hole, data.current_hole)
    |> assign(
      :starting_hole_label,
      starting_hole_label(data.starting_hole, data.starting_position)
    )
    |> assign(:completed_holes, min(data.revision, @scheduled_holes))
    |> assign(
      :route_display,
      Enum.map_join(data.rotated_route, ", ", &Integer.to_string(&1.display_hole_number))
    )
    |> assign(:pickup_policy, data.pickup_policy)
    |> assign(:result_values, default_result_values(entries))
    |> assign(:scorecard_form, to_form(%{}, as: "scorecard"))
    |> assign(:client_submission_id, Ecto.UUID.generate())
    |> assign(:captured_at, DateTime.utc_now() |> DateTime.to_iso8601())
    |> assign(:feedback, nil)
  end

  defp starting_hole_label(starting_hole, starting_position) do
    StartingPositionLabel.format(starting_hole.display_hole_number, starting_position || 1)
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

  defp prepare_previews(socket) do
    entries =
      prepare_players(
        socket.assigns.entries,
        socket.assigns.current_hole,
        socket.assigns.pickup_policy,
        socket.assigns.result_values
      )

    assign(socket, :entries, entries)
  end

  defp refresh_previews(%{assigns: %{lifecycle: :scoring_active}} = socket),
    do: prepare_previews(socket)

  defp refresh_previews(socket), do: socket

  defp prepare_players(players, current_hole, pickup_policy, result_values) do
    Enum.map(players, fn player ->
      result_value = Map.get(result_values, player.id, %{})
      fact = Map.fetch!(player.hole_facts, current_hole.id)
      allocated = Map.fetch!(player.strokes_by_hole, current_hole.id)
      strokes_taken = parse_optional_integer(result_value["strokes_taken"])

      pickup_eligible? =
        case strokes_taken do
          {:ok, taken} ->
            match?(
              {:ok, %{eligible?: true}},
              PickupEligibility.decide(%{
                pickup_policy_identifier: pickup_policy,
                par: fact.par,
                allocated_strokes: allocated,
                strokes_taken: taken
              })
            )

          _ ->
            false
        end

      preview = preview_result(result_value, fact.par, allocated, pickup_eligible?)

      player
      |> Map.put(:current_fact, fact)
      |> Map.put(:result_value, result_value)
      |> Map.put(:pickup_eligible?, pickup_eligible?)
      |> Map.put(:handicap_strokes_label, handicap_strokes_label(allocated))
      |> Map.put(:outcome_options, outcome_options(pickup_eligible?, result_value["outcome"]))
      |> Map.put(:preview, preview)
    end)
  end

  defp preview_result(%{"outcome" => "holed_out"} = result, par, allocated, _pickup_eligible?) do
    with {:ok, gross} <- parse_integer(result["gross_strokes"]),
         true <- gross > 0,
         {:ok, %{competition_points: points, competition_net_strokes: net}} <-
           StablefordPoints.calculate(%{
             outcome: :holed_out,
             gross_strokes: gross,
             par: par,
             allocated_strokes: allocated
           }) do
      %{handicap_adjusted: net, points: points}
    else
      _ -> nil
    end
  end

  defp preview_result(%{"outcome" => "picked_up"}, _par, _allocated, true),
    do: %{handicap_adjusted: nil, points: 0}

  defp preview_result(_, _, _, _), do: nil

  defp outcome_options(pickup_eligible?, selected_outcome) do
    base = [{"Holed out", "holed_out"}]

    if pickup_eligible? or selected_outcome == "picked_up" do
      base ++ [{"Picked up, no points", "picked_up"}]
    else
      base
    end
  end

  defp default_result_values(entries) do
    Map.new(entries, fn entry ->
      {entry.id, %{"outcome" => "", "gross_strokes" => "", "strokes_taken" => ""}}
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

  defp parse_optional_integer(nil), do: :empty
  defp parse_optional_integer(""), do: :empty
  defp parse_optional_integer(value), do: parse_integer(value)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp blank?(value), do: value in [nil, ""]

  defp handicap_strokes_label(strokes) when strokes > 0 do
    label = if strokes == 1, do: "stroke", else: "strokes"
    "#{strokes} #{label} received"
  end

  defp handicap_strokes_label(strokes) when strokes < 0 do
    count = abs(strokes)
    label = if count == 1, do: "stroke", else: "strokes"
    "#{count} #{label} given back"
  end

  defp handicap_strokes_label(_), do: "No handicap stroke"

  defp format_handicap_index(nil), do: "Not recorded"

  defp format_handicap_index(value) do
    value
    |> D.new()
    |> D.to_string(:normal)
  end

  defp cast_uuid(nil), do: nil

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
