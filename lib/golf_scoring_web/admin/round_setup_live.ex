defmodule GolfScoringWeb.Admin.RoundSetupLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  require Ash.Query

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition
  alias GolfScoring.Competition.MysteryHoleRule
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Competition.ScoringTrack
  alias GolfScoring.Competition.Services.ClearRoundTeeSnapshots
  alias GolfScoring.Competition.Services.ConfigureRoundLayout
  alias GolfScoring.Competition.Services.SnapshotRoundTeeProfiles
  alias GolfScoring.Repo
  alias GolfScoring.Scoring
  alias GolfScoring.Scoring.Calculators.CourseHandicap
  alias GolfScoring.Scoring.Calculators.PlayingHandicap
  alias GolfScoringWeb.Admin.InputParsing

  alias Decimal, as: D

  @setup_roles [:event_admin, :competition_manager]
  @playing_handicap_policy "whs_golfrsa_2026_v1"

  @standard_track_attrs %{
    track_type: :standard_better_ball,
    name: "Standard Better-Ball",
    is_primary: false,
    visibility_policy_identifier: "leaderboard_v1",
    aggregation_policy_identifier: "standard_better_ball_v1",
    tie_break_policy_identifier: "standard_countback_v1"
  }

  @mystery_track_attrs %{
    track_type: :mystery,
    name: "Mystery Leaderboard",
    is_primary: true,
    visibility_policy_identifier: "staff_only_v1",
    aggregation_policy_identifier: "mystery_v1",
    tie_break_policy_identifier: "mystery_holes_then_countback_v1"
  }

  @scoring_track_v1_fields [
    :track_type,
    :name,
    :is_primary,
    :visibility_policy_identifier,
    :aggregation_policy_identifier,
    :tie_break_policy_identifier
  ]

  @mystery_rule_options [
    {"None", "NONE"},
    {"Best", "BEST"},
    {"Worst", "WORST"},
    {"Both", "BOTH"}
  ]

  @starting_entry_starter_filter """
  re.registration_status IN ('expected', 'checked_in')
  AND re.participation_status = 'not_started'
  """

  @list_starting_entries_with_competition """
  SELECT
    re.id::text,
    re.round_tee_profile_snapshot_id::text,
    p.first_name,
    p.surname,
    p.latest_handicap_index::text,
    hs.source_handicap_index::text,
    hs.deemed_handicap_basis::text,
    hs.confirmed_at,
    hs.built_at,
    hs.course_handicap_unrounded::text,
    hs.course_handicap_rounded,
    ch.playing_handicap,
    ch.handicap_allowance_percent
  FROM round_entries re
  INNER JOIN players p ON p.id = re.player_id
  LEFT JOIN handicap_snapshots hs ON hs.round_entry_id = re.id
  LEFT JOIN competition_handicaps ch
    ON ch.round_entry_id = re.id
    AND ch.round_competition_id = $2::uuid
  WHERE re.round_id = $1::uuid
    AND #{@starting_entry_starter_filter}
  ORDER BY p.surname, p.first_name, re.id
  """

  @list_starting_entries_without_competition """
  SELECT
    re.id::text,
    re.round_tee_profile_snapshot_id::text,
    p.first_name,
    p.surname,
    p.latest_handicap_index::text,
    hs.source_handicap_index::text,
    hs.deemed_handicap_basis::text,
    hs.confirmed_at,
    hs.built_at,
    hs.course_handicap_unrounded::text,
    hs.course_handicap_rounded,
    ch.playing_handicap,
    ch.handicap_allowance_percent
  FROM round_entries re
  INNER JOIN players p ON p.id = re.player_id
  LEFT JOIN handicap_snapshots hs ON hs.round_entry_id = re.id
  LEFT JOIN competition_handicaps ch ON false
  WHERE re.round_id = $1::uuid
    AND #{@starting_entry_starter_filter}
  ORDER BY p.surname, p.first_name, re.id
  """

  @impl true
  def mount(%{"event_id" => event_id, "round_id" => round_id}, _session, socket) do
    with %StaffUser{status: :active} = staff <- socket.assigns[:current_staffuser],
         {:ok, event_uuid} <- Ecto.UUID.cast(event_id),
         {:ok, round_uuid} <- Ecto.UUID.cast(round_id),
         {:ok, round} <- fetch_round(round_uuid),
         true <- round.event_id == event_uuid,
         true <- ActiveEventRole.authorized?(staff.id, event_uuid, @setup_roles) do
      fresh = Repo.get!(StaffUser, staff.id)

      {:ok,
       socket
       |> assign(:current_staff_user, fresh)
       |> assign(:page_title, "Round setup")
       |> assign(:event_id, event_uuid)
       |> assign(:round, round)
       |> assign(:can_mutate, pre_open?(round))
       |> refresh_round_state(round)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You are not allowed to configure this Round.")
         |> push_navigate(to: ~p"/admin")}
    end
  end

  @impl true
  def handle_event("save_route", %{"route" => route_params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_save_route(route_params, socket)
    end
  end

  @impl true
  def handle_event("snapshot_tees", %{"snapshot" => params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_snapshot_tees(params, socket)
    end
  end

  def handle_event("clear_snapshots", _params, socket) do
    if socket.assigns.can_mutate do
      staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
      round = socket.assigns.round

      case ClearRoundTeeSnapshots.run(staff, round.id) do
        {:ok, []} ->
          {:noreply,
           socket
           |> put_flash(:info, "Cleared all tee profile snapshots.")
           |> refresh_round_state(round)}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to clear tee snapshots.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Clear snapshots failed: #{format_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "This Round is read-only.")}
    end
  end

  def handle_event("save_allowance", %{"allowance" => params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_save_allowance(params, socket)
    end
  end

  def handle_event("assign_entry_tee", %{"entry" => params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_assign_entry_tee(params, socket)
    end
  end

  def handle_event("confirm_handicap", %{"handicap" => params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_confirm_handicap(params, socket)
    end
  end

  def handle_event("apply_no_hi", %{"no_hi" => params}, socket) do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> handle_apply_no_hi(params, socket)
    end
  end

  def handle_event("build_course_handicap", %{"round_entry_id" => entry_id_raw}, socket) do
    if socket.assigns.can_mutate do
      round = socket.assigns.round

      with {:ok, entry_id} <- InputParsing.parse_uuid(entry_id_raw),
           {:ok, entry} <- fetch_starting_entry(socket.assigns.starting_entries, entry_id),
           {:ok, hi} <- entry_handicap_index(entry),
           {:ok, tee} <- load_tee_ratings(entry.round_tee_profile_snapshot_id, round.id),
           {:ok, course} <-
             CourseHandicap.calculate(
               hi,
               tee.slope_rating,
               tee.course_rating,
               tee.applicable_par
             ),
           {:ok, _} <-
             Scoring.build_handicap_snapshot(entry_id, %{
               course_handicap_unrounded: course.course_handicap_unrounded,
               course_handicap_rounded: course.course_handicap_rounded
             }) do
        {:noreply,
         socket
         |> put_flash(:info, "Course handicap built.")
         |> refresh_round_state(round)}
      else
        {:error, :invalid_input} ->
          {:noreply, put_flash(socket, :error, "Entry must be valid.")}

        {:error, :entry_not_found} ->
          {:noreply, put_flash(socket, :error, "Starting entry not found.")}

        {:error, :handicap_basis_missing} ->
          {:noreply,
           put_flash(socket, :error, "Confirm handicap basis before building course handicap.")}

        {:error, :tee_not_assigned} ->
          {:noreply, put_flash(socket, :error, "Assign a tee before building course handicap.")}

        {:error, :stale_handicap_output} ->
          {:noreply,
           socket
           |> put_flash(:error, format_error(:stale_handicap_output))
           |> refresh_round_state(round)}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Course handicap build failed: #{format_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "This Round is read-only.")}
    end
  end

  def handle_event("build_playing_handicap", %{"round_entry_id" => entry_id_raw}, socket) do
    if socket.assigns.can_mutate do
      round = socket.assigns.round
      competition = socket.assigns.round_competition

      with {:ok, entry_id} <- InputParsing.parse_uuid(entry_id_raw),
           %RoundCompetition{id: competition_id} <- competition,
           {:ok, entry} <- fetch_starting_entry(socket.assigns.starting_entries, entry_id),
           true <- not is_nil(entry.course_handicap_unrounded),
           {:ok, playing} <-
             PlayingHandicap.calculate(
               entry.course_handicap_unrounded,
               socket.assigns.handicap_allowance_percent
             ),
           {:ok, _} <-
             Scoring.build_competition_handicap(entry_id, competition_id, %{
               playing_handicap: playing.playing_handicap,
               policy_identifier: @playing_handicap_policy,
               allowance_applied: true,
               unrounded_allowed_handicap: playing.unrounded_allowed_handicap
             }) do
        {:noreply,
         socket
         |> put_flash(:info, "Playing handicap built.")
         |> refresh_round_state(round)}
      else
        false ->
          {:noreply, put_flash(socket, :error, "Build course handicap before playing handicap.")}

        nil ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Configure primary competition before building playing handicaps."
           )}

        {:error, :invalid_input} ->
          {:noreply, put_flash(socket, :error, "Entry must be valid.")}

        {:error, :entry_not_found} ->
          {:noreply, put_flash(socket, :error, "Starting entry not found.")}

        {:error, :stale_handicap_output} ->
          {:noreply,
           socket
           |> put_flash(:error, format_error(:stale_handicap_output))
           |> refresh_round_state(round)}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Playing handicap build failed: #{format_error(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "This Round is read-only.")}
    end
  end

  def handle_event("save_standard_track", _params, socket) do
    save_scoring_track(socket, :standard)
  end

  def handle_event("save_mystery_track", _params, socket) do
    save_scoring_track(socket, :mystery)
  end

  def handle_event("save_mystery_rule", %{"rule" => params}, socket) do
    cond do
      not socket.assigns.can_mutate ->
        {:noreply, put_flash(socket, :error, "This Round is read-only.")}

      not socket.assigns.can_configure_mystery ->
        {:noreply,
         put_flash(socket, :error, "You are not allowed to configure mystery hole rules.")}

      is_nil(socket.assigns.mystery_track) ->
        {:noreply, put_flash(socket, :error, "Configure the mystery scoring track first.")}

      not scoring_track_editable?(socket.assigns.mystery_track) ->
        {:noreply, put_flash(socket, :error, format_error(:configuration_locked))}

      true ->
        staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
        round = socket.assigns.round
        event_id = socket.assigns.event_id

        with %ScoringTrack{id: track_id} <- socket.assigns.mystery_track,
             {:ok, round_hole_id} <- InputParsing.parse_uuid(Map.get(params, "round_hole_id")),
             selection <- Map.get(params, "selection", "NONE") do
          respond_mystery_rule(staff, event_id, round, track_id, round_hole_id, selection, socket)
        else
          {:error, :invalid_input} ->
            {:noreply, put_flash(socket, :error, "Round hole must be valid.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <section id="round-setup" class="space-y-6">
        <header class="space-y-2">
          <p class="text-sm font-medium text-base-content/70">
            Event {@event_id} · Round {@round.id}
          </p>
          <h1 class="text-2xl font-semibold tracking-tight">Round setup</h1>
          <p id="round-state" class="text-sm text-base-content/70">State: {@round.state}</p>
        </header>

        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
          <h2 class="text-lg font-semibold">Competition configuration</h2>

          <ul id="competition-configuration-status" class="text-sm space-y-1">
            <li :for={item <- @configuration_checklist} id={"competition-check-#{item.key}"}>
              <span class={if(item.done, do: "text-success", else: "text-warning")}>
                {if item.done, do: "✓", else: "○"}
              </span>
              {item.label}
            </li>
          </ul>

          <%= if @allowance_invalidation_notice do %>
            <p id="allowance-invalidation-notice" class="text-sm text-warning">
              {@allowance_invalidation_notice}
            </p>
          <% end %>

          <.form
            id="competition-allowance-form"
            for={%{}}
            phx-submit="save_allowance"
            class="flex flex-wrap items-end gap-3"
          >
            <.input
              id="competition-handicap-allowance"
              name="allowance[handicap_allowance_percent]"
              type="number"
              label="Handicap allowance (%)"
              value={@handicap_allowance_percent}
              min="0"
              max="100"
              disabled={not @can_mutate}
            />
            <button
              id="competition-allowance-save"
              type="submit"
              class="btn btn-primary"
              disabled={not @can_mutate}
            >
              Save allowance
            </button>
          </.form>
        </div>

        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
          <h2 class="text-lg font-semibold">Starting entries</h2>
          <p class="text-sm text-base-content/70">
            {length(@starting_entries)} starter(s) in this Round.
          </p>

          <div id="starting-entries-list" class="space-y-6">
            <article
              :for={entry <- @starting_entries}
              id={"starting-entry-#{entry.id}"}
              class="rounded-xl border border-base-200 p-4 space-y-3"
            >
              <h3 class="font-medium">{entry.display_name}</h3>
              <p class="text-xs text-base-content/60">Entry {entry.id}</p>

              <.form
                id={"entry-tee-form-#{entry.id}"}
                for={%{}}
                phx-submit="assign_entry_tee"
                class="flex flex-wrap items-end gap-2"
              >
                <input type="hidden" name="entry[round_entry_id]" value={entry.id} />
                <.input
                  id={"entry-tee-#{entry.id}"}
                  name="entry[snapshot_id]"
                  type="select"
                  label="Tee snapshot"
                  value={entry.round_tee_profile_snapshot_id || ""}
                  options={@snapshot_options}
                  prompt="Select snapshot"
                  disabled={not @can_mutate}
                />
                <button type="submit" class="btn btn-sm btn-outline" disabled={not @can_mutate}>
                  Assign tee
                </button>
              </.form>

              <%= if entry.player_has_handicap_index? do %>
                <.form
                  id={"entry-handicap-form-#{entry.id}"}
                  for={%{}}
                  phx-submit="confirm_handicap"
                  class="flex flex-wrap items-end gap-2"
                >
                  <input type="hidden" name="handicap[round_entry_id]" value={entry.id} />
                  <.input
                    id={"entry-hi-#{entry.id}"}
                    name="handicap[source_handicap_index]"
                    type="text"
                    label="Handicap index"
                    value={entry.source_handicap_index_input}
                    disabled={not @can_mutate}
                  />
                  <button type="submit" class="btn btn-sm btn-outline" disabled={not @can_mutate}>
                    Confirm HI
                  </button>
                </.form>
              <% else %>
                <.form
                  id={"entry-no-hi-form-#{entry.id}"}
                  for={%{}}
                  phx-submit="apply_no_hi"
                  class="flex flex-wrap items-end gap-2"
                >
                  <input type="hidden" name="no_hi[round_entry_id]" value={entry.id} />
                  <.input
                    id={"entry-deemed-#{entry.id}"}
                    name="no_hi[deemed_handicap_basis]"
                    type="text"
                    label="Deemed handicap basis (no HI)"
                    value={entry.deemed_handicap_basis_input}
                    disabled={not @can_mutate}
                  />
                  <.input
                    id={"entry-no-hi-provenance-#{entry.id}"}
                    name="no_hi[source_reference]"
                    type="text"
                    label="Committee provenance reference"
                    value={entry.no_hi_source_reference_input}
                    disabled={not @can_mutate}
                  />
                  <button type="submit" class="btn btn-sm btn-outline" disabled={not @can_mutate}>
                    Apply no-HI
                  </button>
                </.form>
              <% end %>

              <div class="flex flex-wrap gap-2 text-sm">
                <span>Tee: {entry.tee_status_label}</span>
                <span>Basis: {entry.basis_status_label}</span>
                <span>Course HI: {entry.course_handicap_label}</span>
                <span>Playing HI: {entry.playing_handicap_label}</span>
              </div>

              <div class="flex flex-wrap gap-2">
                <button
                  id={"build-course-handicap-#{entry.id}"}
                  type="button"
                  class="btn btn-sm btn-secondary"
                  phx-click="build_course_handicap"
                  phx-value-round_entry_id={entry.id}
                  disabled={not @can_mutate}
                >
                  Build course handicap
                </button>
                <button
                  id={"build-playing-handicap-#{entry.id}"}
                  type="button"
                  class="btn btn-sm btn-secondary"
                  phx-click="build_playing_handicap"
                  phx-value-round_entry_id={entry.id}
                  disabled={not @can_mutate}
                >
                  Build playing handicap
                </button>
              </div>
            </article>
          </div>
        </div>

        <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
          <h2 class="text-lg font-semibold">Scoring tracks</h2>
          <%= if scoring_track_locked?(@standard_track) or scoring_track_locked?(@mystery_track) do %>
            <p id="scoring-tracks-locked-notice" class="text-sm text-base-content/70">
              Locked scoring tracks are read-only on this screen.
            </p>
          <% end %>
          <div class="flex flex-wrap gap-3">
            <button
              id="save-standard-track"
              type="button"
              class="btn btn-outline"
              phx-click="save_standard_track"
              disabled={not scoring_track_configurable?(@can_mutate, @standard_track)}
            >
              {track_button_label(@standard_track, "Standard better-ball")}
            </button>
            <button
              id="save-mystery-track"
              type="button"
              class="btn btn-outline"
              phx-click="save_mystery_track"
              disabled={not scoring_track_configurable?(@can_mutate, @mystery_track)}
            >
              {track_button_label(@mystery_track, "Mystery leaderboard")}
            </button>
          </div>
        </div>

        <%= if @can_configure_mystery and @mystery_track do %>
          <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-semibold">Mystery hole rules</h2>
            <div id="mystery-hole-rules" class="grid gap-3 sm:grid-cols-2">
              <%= for hole <- @round_holes do %>
                <.form
                  id={"mystery-rule-form-#{hole.id}"}
                  for={%{}}
                  phx-submit="save_mystery_rule"
                  class="flex items-end gap-2"
                >
                  <input type="hidden" name="rule[round_hole_id]" value={hole.id} />
                  <.input
                    id={"mystery-rule-#{hole.id}"}
                    name="rule[selection]"
                    type="select"
                    label={"Hole #{hole.display_hole_number} (play #{hole.play_order})"}
                    value={Map.get(@mystery_rule_selections, hole.id, "NONE")}
                    options={@mystery_rule_options}
                    disabled={
                      not mystery_rules_configurable?(
                        @can_mutate,
                        @can_configure_mystery,
                        @mystery_track
                      )
                    }
                  />
                  <button
                    id={"mystery-rule-save-#{hole.id}"}
                    type="submit"
                    class="btn btn-sm btn-primary"
                    disabled={
                      not mystery_rules_configurable?(
                        @can_mutate,
                        @can_configure_mystery,
                        @mystery_track
                      )
                    }
                  >
                    Save
                  </button>
                </.form>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @can_mutate do %>
          <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-semibold">Round route</h2>
            <ol id="round-route-list" class="list-decimal pl-5 text-sm space-y-1">
              <li :for={hole <- @round_holes}>
                play {hole.play_order} · course hole {hole.course_hole_id}
              </li>
            </ol>
            <.form id="round-route-form" for={%{}} phx-submit="save_route">
              <div id="round-route-selectors" class="grid gap-3 sm:grid-cols-2">
                <%= for play_order <- 1..18 do %>
                  <.input
                    id={"round-route-hole-#{play_order}"}
                    name={"route[hole_#{play_order}]"}
                    type="select"
                    label={"Play #{play_order}"}
                    value={Map.get(@route_selections, play_order, "")}
                    options={@course_hole_options}
                    prompt="Select course hole"
                  />
                <% end %>
              </div>
              <button id="round-route-save-button" type="submit" class="btn btn-primary mt-3">
                Save route
              </button>
            </.form>
          </div>

          <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
            <h2 class="text-lg font-semibold">Tee profile snapshots</h2>
            <ul id="snapshot-status-list" class="text-sm space-y-1">
              <li :for={snapshot <- @snapshots}>
                {snapshot.rating_label} · source {snapshot.source_tee_rating_profile_id}
              </li>
            </ul>
            <.form id="round-snapshot-form" for={%{}} phx-submit="snapshot_tees">
              <div id="tee-profile-options" class="space-y-2">
                <%= for profile <- @available_profiles do %>
                  <label class="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      name="snapshot[profile_ids][]"
                      value={profile.id}
                      checked={profile.id in @selected_profile_ids}
                    />
                    {profile.rating_label} ({profile.tee_set_name})
                  </label>
                <% end %>
              </div>
              <button id="round-snapshot-button" type="submit" class="btn btn-primary mt-3">
                Snapshot selected profiles
              </button>
            </.form>
            <button
              id="round-clear-snapshots-button"
              type="button"
              class="btn btn-outline mt-3"
              phx-click="clear_snapshots"
            >
              Clear all snapshots
            </button>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp track_button_label(%ScoringTrack{configuration_state: :locked}, default),
    do: "#{default} (locked)"

  defp track_button_label(%ScoringTrack{configuration_state: :draft}, default),
    do: "Update #{default}"

  defp track_button_label(%ScoringTrack{}, default), do: "Configure #{default}"
  defp track_button_label(nil, default), do: "Configure #{default}"

  defp scoring_track_locked?(%ScoringTrack{configuration_state: :locked}), do: true
  defp scoring_track_locked?(_), do: false

  defp scoring_track_configurable?(true, track), do: scoring_track_editable?(track)
  defp scoring_track_configurable?(_, _), do: false

  defp scoring_track_editable?(nil), do: true

  defp scoring_track_editable?(%ScoringTrack{configuration_state: :draft}), do: true
  defp scoring_track_editable?(%ScoringTrack{configuration_state: :locked}), do: false
  defp scoring_track_editable?(_), do: false

  defp mystery_rules_configurable?(true, true, track),
    do: not is_nil(track) and scoring_track_editable?(track)

  defp mystery_rules_configurable?(_, _, _), do: false

  defp standard_track_configured?(track), do: track_matches_v1?(track, @standard_track_attrs)

  defp mystery_track_configured?(track), do: track_matches_v1?(track, @mystery_track_attrs)

  defp track_matches_v1?(nil, _expected), do: false

  defp track_matches_v1?(%ScoringTrack{} = track, expected_attrs) do
    Enum.all?(@scoring_track_v1_fields, fn field ->
      Map.fetch!(track, field) == Map.fetch!(expected_attrs, field)
    end)
  end

  defp mutate_allowed(%{assigns: %{can_mutate: true}}), do: :ok
  defp mutate_allowed(_), do: :read_only

  defp noreply_read_only(socket) do
    {:noreply, put_flash(socket, :error, "This Round is read-only.")}
  end

  defp handle_save_route(route_params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round

    case parse_route_selections(route_params) do
      {:error, :invalid_input} ->
        {:noreply,
         put_flash(socket, :error, "Choose a valid course hole for every play position.")}

      {:ok, course_hole_ids} ->
        case ConfigureRoundLayout.run(staff, round.id, course_hole_ids) do
          {:ok, route} ->
            {:noreply,
             socket
             |> put_flash(:info, "Round route saved (#{length(route)} holes).")
             |> refresh_round_state(round)}

          {:error, :forbidden} ->
            {:noreply,
             put_flash(socket, :error, "You are not allowed to configure this Round route.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Route save failed: #{format_error(reason)}")}
        end
    end
  end

  defp handle_snapshot_tees(params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    profile_ids = Map.get(params, "profile_ids", []) |> List.wrap()

    case InputParsing.parse_uuids(profile_ids) do
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Selected tee profiles must be valid.")}

      {:ok, []} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Select at least one tee profile to snapshot. To remove snapshots, use Clear all snapshots."
         )}

      {:ok, selected} ->
        respond_to_snapshot_run(staff, round, selected, socket)
    end
  end

  defp handle_save_allowance(params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    case parse_allowance_percent(Map.get(params, "handicap_allowance_percent")) do
      {:error, :invalid_input} ->
        {:noreply,
         put_flash(socket, :error, "Handicap allowance must be an integer from 0 to 100.")}

      {:ok, percent} ->
        case Competition.configure_round_competition(staff, event_id, round.id, %{
               handicap_allowance_percent: percent
             }) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Handicap allowance saved (#{percent}%).")
             |> refresh_round_state(round)}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "You are not allowed to configure competition.")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Allowance save failed: #{format_error(reason)}")}
        end
    end
  end

  defp handle_assign_entry_tee(params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    with {:ok, entry_id} <- InputParsing.parse_uuid(Map.get(params, "round_entry_id")),
         {:ok, snapshot_id} <- InputParsing.parse_uuid(Map.get(params, "snapshot_id")) do
      noreply_assign_entry_tee(staff, event_id, round, entry_id, snapshot_id, socket)
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Entry and tee snapshot must be valid.")}
    end
  end

  defp noreply_assign_entry_tee(staff, event_id, round, entry_id, snapshot_id, socket) do
    case Competition.assign_round_tee(staff, event_id, round.id, entry_id, snapshot_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tee assignment saved.")
         |> refresh_round_state(round)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to assign tees.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Tee assignment failed: #{format_error(reason)}")}
    end
  end

  defp handle_confirm_handicap(params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    with {:ok, entry_id} <- InputParsing.parse_uuid(Map.get(params, "round_entry_id")),
         {:ok, hi} <- InputParsing.parse_decimal(Map.get(params, "source_handicap_index")) do
      noreply_confirm_handicap(staff, event_id, round, entry_id, hi, socket)
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Entry and handicap index must be valid.")}
    end
  end

  defp noreply_confirm_handicap(staff, event_id, round, entry_id, hi, socket) do
    case Scoring.confirm_handicap_input(staff, event_id, round.id, entry_id, %{
           source_handicap_index: hi
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Handicap index confirmed.")
         |> refresh_round_state(round)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to confirm handicaps.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Handicap confirmation failed: #{format_error(reason)}")}
    end
  end

  defp handle_apply_no_hi(params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    with {:ok, entry_id} <- InputParsing.parse_uuid(Map.get(params, "round_entry_id")),
         {:ok, deemed} <- InputParsing.parse_decimal(Map.get(params, "deemed_handicap_basis")),
         {:ok, provenance} <- parse_provenance_reference(Map.get(params, "source_reference")) do
      noreply_apply_no_hi(staff, event_id, round, entry_id, deemed, provenance, socket)
    else
      {:error, :invalid_input} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Entry, deemed basis, and committee provenance reference must be valid."
         )}
    end
  end

  defp noreply_apply_no_hi(staff, event_id, round, entry_id, deemed, provenance, socket) do
    case Scoring.apply_no_hi_policy(staff, event_id, round.id, entry_id, %{
           deemed_handicap_basis: deemed,
           source_reference: provenance
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "No-HI policy applied.")
         |> refresh_round_state(round)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to apply no-HI policy.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "No-HI policy failed: #{format_error(reason)}")}
    end
  end

  defp save_scoring_track(socket, track_kind) when track_kind in [:standard, :mystery] do
    case mutate_allowed(socket) do
      :read_only -> noreply_read_only(socket)
      :ok -> persist_scoring_track(socket, track_kind)
    end
  end

  defp persist_scoring_track(socket, track_kind) do
    {base_attrs, track_assign, success_message, failure_prefix} =
      scoring_track_persist_meta(track_kind)

    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id
    competition = socket.assigns.round_competition
    track = Map.fetch!(socket.assigns, track_assign)

    with :ok <- ensure_scoring_track_editable(track),
         %RoundCompetition{id: competition_id} <- competition do
      attrs = track_attrs_with_id(base_attrs, track)

      case Competition.configure_scoring_track(staff, event_id, round.id, competition_id, attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, success_message)
           |> refresh_round_state(round)}

        {:error, :forbidden} ->
          {:noreply,
           put_flash(socket, :error, "You are not allowed to configure scoring tracks.")}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "#{failure_prefix}: #{format_error(reason)}"
           )}
      end
    else
      {:error, :configuration_locked} ->
        {:noreply, put_flash(socket, :error, format_error(:configuration_locked))}

      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Save handicap allowance to create primary competition first."
         )}
    end
  end

  defp ensure_scoring_track_editable(track) do
    if scoring_track_editable?(track), do: :ok, else: {:error, :configuration_locked}
  end

  defp scoring_track_persist_meta(:standard) do
    {
      @standard_track_attrs,
      :standard_track,
      "Standard scoring track saved.",
      "Standard track save failed"
    }
  end

  defp scoring_track_persist_meta(:mystery) do
    {
      @mystery_track_attrs,
      :mystery_track,
      "Mystery scoring track saved.",
      "Mystery track save failed"
    }
  end

  defp respond_mystery_rule(staff, event_id, round, track_id, round_hole_id, selection, socket) do
    result =
      run_mystery_rule_action(staff, event_id, round.id, track_id, round_hole_id, selection)

    noreply_mystery_rule_result(result, socket, round)
  end

  defp run_mystery_rule_action(staff, event_id, round_id, track_id, round_hole_id, selection) do
    case mystery_rule_selection_atom(selection) do
      :invalid ->
        {:error, :invalid_input}

      :none ->
        Competition.remove_mystery_hole_rule(staff, event_id, round_id, track_id, round_hole_id)

      rule ->
        Competition.configure_mystery_hole_rule(
          staff,
          event_id,
          round_id,
          track_id,
          round_hole_id,
          rule
        )
    end
  end

  defp mystery_rule_selection_atom(selection) when is_binary(selection) do
    case String.upcase(String.trim(selection)) do
      "NONE" -> :none
      "BEST" -> :best
      "WORST" -> :worst
      "BOTH" -> :both
      _ -> :invalid
    end
  end

  defp mystery_rule_selection_atom(_), do: :invalid

  defp noreply_mystery_rule_result(:ok, socket, round) do
    {:noreply,
     socket
     |> put_flash(:info, "Mystery hole rule saved.")
     |> refresh_round_state(round)}
  end

  defp noreply_mystery_rule_result({:ok, _}, socket, round) do
    noreply_mystery_rule_result(:ok, socket, round)
  end

  defp noreply_mystery_rule_result({:error, :forbidden}, socket, _round) do
    {:noreply, put_flash(socket, :error, "You are not allowed to configure mystery rules.")}
  end

  defp noreply_mystery_rule_result({:error, :invalid_input}, socket, _round) do
    {:noreply,
     put_flash(socket, :error, "Mystery rule selection must be NONE, BEST, WORST, or BOTH.")}
  end

  defp noreply_mystery_rule_result({:error, reason}, socket, _round) do
    {:noreply, put_flash(socket, :error, "Mystery rule save failed: #{format_error(reason)}")}
  end

  defp respond_to_snapshot_run(staff, round, selected, socket) do
    case SnapshotRoundTeeProfiles.run(staff, round.id, selected) do
      {:ok, snapshots} ->
        {:noreply,
         socket
         |> put_flash(:info, snapshot_success_message(snapshots))
         |> refresh_round_state(round)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to snapshot tee profiles.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Snapshot failed: #{format_error(reason)}")}
    end
  end

  defp snapshot_success_message(snapshots),
    do: "Snapshotted #{length(snapshots)} tee profile(s)."

  defp pre_open?(round), do: round.state in [:draft, :ready]

  defp fetch_round(round_id) do
    case Competition.get_round_by_id(round_id, authorize?: false) do
      {:ok, round} -> {:ok, round}
      {:error, _} -> :error
    end
  end

  defp refresh_round_state(socket, round) do
    round = Repo.get!(Round, round.id)
    round_holes = list_round_holes(round.id)
    course_holes = list_course_holes(round.course_id)
    snapshots = list_snapshots(round.id)
    available = list_available_profiles(round.course_id)
    round_competition = load_primary_round_competition(round.id)
    handicap_allowance_percent = competition_allowance(round_competition)
    {standard_track, mystery_track} = load_scoring_tracks(round_competition)
    mystery_rule_selections = mystery_rule_selections(mystery_track)
    starting_entries = list_starting_entries(round.id, round_competition)

    course_hole_options =
      Enum.map(course_holes, fn hole ->
        {"Hole #{hole.hole_number}", hole.id}
      end)

    route_selections =
      round_holes
      |> Enum.sort_by(& &1.play_order)
      |> Map.new(fn hole -> {hole.play_order, hole.course_hole_id} end)

    selected_profile_ids = Enum.map(snapshots, & &1.source_tee_rating_profile_id)

    snapshot_options =
      Enum.map(snapshots, fn s -> {s.rating_label, s.id} end)

    staff_id = socket.assigns.current_staff_user.id
    event_id = socket.assigns.event_id

    can_configure_mystery =
      ActiveEventRole.authorized?(staff_id, event_id, @setup_roles)

    configuration_checklist =
      build_configuration_checklist(
        round_holes,
        snapshots,
        round_competition,
        standard_track,
        mystery_track,
        mystery_rule_selections,
        starting_entries
      )

    allowance_invalidation_notice =
      allowance_invalidation_notice(starting_entries, round_competition)

    socket
    |> assign(:round, round)
    |> assign(:can_mutate, pre_open?(round))
    |> assign(:can_configure_mystery, can_configure_mystery)
    |> assign(:round_holes, round_holes)
    |> assign(:course_holes, course_holes)
    |> assign(:course_hole_options, course_hole_options)
    |> assign(:route_selections, route_selections)
    |> assign(:snapshots, snapshots)
    |> assign(:available_profiles, available)
    |> assign(:selected_profile_ids, selected_profile_ids)
    |> assign(:snapshot_options, snapshot_options)
    |> assign(:round_competition, round_competition)
    |> assign(:handicap_allowance_percent, handicap_allowance_percent)
    |> assign(:standard_track, standard_track)
    |> assign(:mystery_track, mystery_track)
    |> assign(:mystery_rule_options, @mystery_rule_options)
    |> assign(:mystery_rule_selections, mystery_rule_selections)
    |> assign(:starting_entries, starting_entries)
    |> assign(:configuration_checklist, configuration_checklist)
    |> assign(:allowance_invalidation_notice, allowance_invalidation_notice)
  end

  defp competition_allowance(nil), do: 100

  defp competition_allowance(%RoundCompetition{handicap_allowance_percent: percent}), do: percent

  defp load_primary_round_competition(round_id) do
    RoundCompetition
    |> Ash.Query.filter(round_id == ^round_id and is_primary == true)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, competition} -> competition
      _ -> nil
    end
  end

  defp load_scoring_tracks(nil), do: {nil, nil}

  defp load_scoring_tracks(%RoundCompetition{id: competition_id}) do
    tracks =
      ScoringTrack
      |> Ash.Query.filter(round_competition_id == ^competition_id)
      |> Ash.read!(authorize?: false)

    standard = Enum.find(tracks, &(&1.track_type == :standard_better_ball))
    mystery = Enum.find(tracks, &(&1.track_type == :mystery))
    {standard, mystery}
  end

  defp mystery_rule_selections(nil), do: %{}

  defp mystery_rule_selections(%ScoringTrack{id: track_id}) do
    MysteryHoleRule
    |> Ash.Query.filter(scoring_track_id == ^track_id)
    |> Ash.read!(authorize?: false)
    |> Map.new(fn rule ->
      {rule.round_hole_id, mystery_rule_to_selection(rule.rule)}
    end)
  end

  defp mystery_rule_to_selection(:best), do: "BEST"
  defp mystery_rule_to_selection(:worst), do: "WORST"
  defp mystery_rule_to_selection(:both), do: "BOTH"
  defp mystery_rule_to_selection(_), do: "NONE"

  defp track_attrs_with_id(base_attrs, nil), do: base_attrs

  defp track_attrs_with_id(base_attrs, %ScoringTrack{id: id, configuration_state: :draft}) do
    Map.put(base_attrs, :scoring_track_id, id)
  end

  defp track_attrs_with_id(base_attrs, %ScoringTrack{}), do: base_attrs

  defp list_starting_entries(round_id, %RoundCompetition{id: competition_id}) do
    Repo.query!(
      @list_starting_entries_with_competition,
      [Ecto.UUID.dump!(round_id), Ecto.UUID.dump!(competition_id)]
    ).rows
    |> Enum.map(&map_starting_entry_row/1)
  end

  defp list_starting_entries(round_id, nil) do
    Repo.query!(@list_starting_entries_without_competition, [Ecto.UUID.dump!(round_id)]).rows
    |> Enum.map(&map_starting_entry_row/1)
  end

  defp map_starting_entry_row([
         id,
         tee_snapshot_id,
         first_name,
         surname,
         latest_hi,
         source_hi,
         deemed,
         confirmed_at,
         built_at,
         course_unrounded,
         course_rounded,
         playing,
         playing_allowance
       ]) do
    tee_uuid = cast_optional_uuid(tee_snapshot_id)
    player_has_hi? = not is_nil(parse_optional_decimal(latest_hi))

    %{
      id: Ecto.UUID.cast!(id),
      display_name: "#{first_name} #{surname}",
      round_tee_profile_snapshot_id: tee_uuid,
      player_has_handicap_index?: player_has_hi?,
      source_handicap_index: parse_optional_decimal(source_hi),
      deemed_handicap_basis: parse_optional_decimal(deemed),
      source_handicap_index_input: decimal_input(source_hi),
      deemed_handicap_basis_input: decimal_input(deemed),
      no_hi_source_reference_input: "",
      confirmed_at: confirmed_at,
      built_at: built_at,
      course_handicap_unrounded: parse_optional_decimal(course_unrounded),
      course_handicap_rounded: course_rounded,
      playing_handicap: playing,
      playing_handicap_allowance_percent: playing_allowance,
      tee_status_label: if(tee_uuid, do: "assigned", else: "missing"),
      basis_status_label: basis_status_label(confirmed_at, source_hi, deemed),
      course_handicap_label: course_handicap_label(built_at, course_rounded),
      playing_handicap_label: if(is_nil(playing), do: "missing", else: to_string(playing))
    }
  end

  defp basis_status_label(nil, _, _), do: "missing"

  defp basis_status_label(_, source_hi, deemed) when not is_nil(source_hi) or not is_nil(deemed),
    do: "confirmed"

  defp basis_status_label(_, _, _), do: "missing"

  defp course_handicap_label(nil, _), do: "missing"
  defp course_handicap_label(_, rounded) when not is_nil(rounded), do: to_string(rounded)
  defp course_handicap_label(_, _), do: "missing"

  defp decimal_input(nil), do: ""
  defp decimal_input(value) when is_binary(value), do: String.trim(value)

  defp parse_optional_decimal(nil), do: nil

  defp parse_optional_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp cast_optional_uuid(nil), do: nil

  defp cast_optional_uuid(value) do
    {:ok, uuid} = Ecto.UUID.cast(value)
    uuid
  end

  defp build_configuration_checklist(
         round_holes,
         snapshots,
         round_competition,
         standard_track,
         mystery_track,
         mystery_rule_selections,
         starting_entries
       ) do
    route_done = length(round_holes) == 18
    snapshots_done = snapshots != []
    competition_done = not is_nil(round_competition)
    standard_done = standard_track_configured?(standard_track)
    mystery_done = mystery_track_configured?(mystery_track)

    mystery_rules_done =
      not is_nil(mystery_track) and
        Enum.any?(mystery_rule_selections, fn {_hole_id, selection} ->
          selection != "NONE"
        end)

    all_tees = Enum.all?(starting_entries, & &1.round_tee_profile_snapshot_id)
    all_basis = Enum.all?(starting_entries, & &1.confirmed_at)
    all_course = Enum.all?(starting_entries, & &1.built_at)

    all_playing =
      starting_entries == [] or
        Enum.all?(starting_entries, &playing_handicap_current?(&1, round_competition))

    [
      checklist_item(:route, "Round route (18 holes)", route_done),
      checklist_item(:tee_snapshots, "Tee profile snapshots", snapshots_done),
      checklist_item(:competition, "Primary competition configured", competition_done),
      checklist_item(:standard_track, "Standard scoring track", standard_done),
      checklist_item(:mystery_track, "Mystery scoring track", mystery_done),
      checklist_item(:mystery_rules, "At least one mystery hole rule", mystery_rules_done),
      checklist_item(
        :entry_tees,
        "All starters assigned a tee",
        all_tees or starting_entries == []
      ),
      checklist_item(
        :entry_basis,
        "All starters have handicap basis",
        all_basis or starting_entries == []
      ),
      checklist_item(
        :entry_course,
        "All starters have course handicap",
        all_course or starting_entries == []
      ),
      checklist_item(
        :entry_playing,
        "All starters have playing handicap matching allowance",
        all_playing
      )
    ]
  end

  defp playing_handicap_current?(entry, %RoundCompetition{handicap_allowance_percent: expected}) do
    not is_nil(entry.playing_handicap) and
      entry.playing_handicap_allowance_percent == expected
  end

  defp playing_handicap_current?(_, nil), do: false

  defp parse_provenance_reference(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    if trimmed == "" do
      {:error, :invalid_input}
    else
      {:ok, trimmed}
    end
  end

  defp parse_provenance_reference(_), do: {:error, :invalid_input}

  defp checklist_item(key, label, done), do: %{key: key, label: label, done: done}

  defp allowance_invalidation_notice(_entries, nil), do: nil

  defp allowance_invalidation_notice(entries, _competition) do
    stale? =
      Enum.any?(entries, fn entry ->
        not is_nil(entry.built_at) and is_nil(entry.playing_handicap)
      end)

    if stale? do
      "Handicap allowance changed or playing handicaps were cleared. Rebuild playing handicaps for entries with course handicaps."
    else
      nil
    end
  end

  defp fetch_starting_entry(entries, entry_id) do
    case Enum.find(entries, &(&1.id == entry_id)) do
      nil -> {:error, :entry_not_found}
      entry -> {:ok, entry}
    end
  end

  defp entry_handicap_index(%{source_handicap_index: hi}) when not is_nil(hi), do: {:ok, hi}

  defp entry_handicap_index(%{deemed_handicap_basis: hi}) when not is_nil(hi), do: {:ok, hi}

  defp entry_handicap_index(_), do: {:error, :handicap_basis_missing}

  defp load_tee_ratings(nil, _round_id), do: {:error, :tee_not_assigned}

  defp load_tee_ratings(snapshot_id, round_id) do
    case Repo.query!(
           """
           SELECT slope_rating, course_rating::text, applicable_par
           FROM round_tee_profile_snapshots
           WHERE id = $1::uuid AND round_id = $2::uuid
           """,
           [Ecto.UUID.dump!(snapshot_id), Ecto.UUID.dump!(round_id)]
         ).rows do
      [[slope, course_rating, par]] ->
        {:ok,
         %{
           slope_rating: slope,
           course_rating: parse_optional_decimal(course_rating),
           applicable_par: par
         }}

      [] ->
        {:error, :tee_not_assigned}
    end
  end

  defp parse_route_selections(route_params) do
    1..18
    |> Enum.reduce_while({:ok, []}, fn play_order, {:ok, acc} ->
      key = "hole_#{play_order}"

      case InputParsing.parse_uuid(Map.get(route_params, key)) do
        {:ok, course_hole_id} -> {:cont, {:ok, [course_hole_id | acc]}}
        {:error, _} -> {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp parse_allowance_percent(value) when is_integer(value) and value >= 0 and value <= 100,
    do: {:ok, value}

  defp parse_allowance_percent(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 and int <= 100 -> {:ok, int}
      _ -> {:error, :invalid_input}
    end
  end

  defp parse_allowance_percent(_), do: {:error, :invalid_input}

  defp format_error({:invalid_round_state, state}), do: "invalid round state #{state}"

  defp format_error(:stale_handicap_output),
    do:
      "Handicap inputs changed since the last build. Confirm basis, rebuild course handicap, then rebuild playing handicap."

  defp format_error(:configuration_locked),
    do: "Scoring track configuration is locked and cannot be changed here."

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp list_round_holes(round_id) do
    Repo.query!(
      """
      SELECT id::text, course_hole_id::text, play_order, display_hole_number
      FROM round_holes
      WHERE round_id = $1::uuid
      ORDER BY play_order
      """,
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, course_hole_id, play_order, display_hole_number] ->
      %{
        id: Ecto.UUID.cast!(id),
        course_hole_id: Ecto.UUID.cast!(course_hole_id),
        play_order: play_order,
        display_hole_number: display_hole_number
      }
    end)
  end

  defp list_course_holes(course_id) do
    Repo.query!(
      "SELECT id::text, hole_number FROM course_holes WHERE course_id = $1::uuid ORDER BY hole_number",
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> Enum.map(fn [id, n] -> %{id: Ecto.UUID.cast!(id), hole_number: n} end)
  end

  defp list_snapshots(round_id) do
    Repo.query!(
      """
      SELECT id::text, rating_label, source_tee_rating_profile_id::text
      FROM round_tee_profile_snapshots
      WHERE round_id = $1::uuid
      ORDER BY rating_label
      """,
      [Ecto.UUID.dump!(round_id)]
    ).rows
    |> Enum.map(fn [id, label, source_id] ->
      %{
        id: Ecto.UUID.cast!(id),
        rating_label: label,
        source_tee_rating_profile_id: Ecto.UUID.cast!(source_id)
      }
    end)
  end

  defp list_available_profiles(course_id) do
    Repo.query!(
      """
      SELECT p.id::text, p.rating_label, t.name
      FROM tee_rating_profiles p
      INNER JOIN tee_sets t ON t.id = p.tee_set_id
      WHERE t.course_id = $1::uuid
      ORDER BY p.rating_label
      """,
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> Enum.map(fn [id, label, tee_set_name] ->
      %{id: Ecto.UUID.cast!(id), rating_label: label, tee_set_name: tee_set_name}
    end)
  end
end
