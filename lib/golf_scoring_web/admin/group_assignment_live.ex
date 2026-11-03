defmodule GolfScoringWeb.Admin.GroupAssignmentLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  require Ash.Query

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition
  alias GolfScoring.Competition.CompetitionSide
  alias GolfScoring.Competition.CompetitionSideMembership
  alias GolfScoring.Competition.CompetitionSideResult
  alias GolfScoring.Competition.PlayingGroup
  alias GolfScoring.Competition.PlayingGroupReadiness
  alias GolfScoring.Competition.Round
  alias GolfScoring.Competition.RoundCompetition
  alias GolfScoring.Competition.RoundEntry
  alias GolfScoring.Competition.RoundHole
  alias GolfScoring.Competition.Services.AssignEntryToGroup
  alias GolfScoring.Competition.Services.AssignPlayingGroupStart
  alias GolfScoring.Competition.Services.ConfigureRoundCompetition
  alias GolfScoring.Competition.Services.CreateCompetitionSide
  alias GolfScoring.Competition.Services.SetSideMembership
  alias GolfScoring.Competition.StartingParticipant
  alias GolfScoring.Competition.StartingPositionLabel
  alias GolfScoring.Repo
  alias GolfScoringWeb.Admin.InputParsing

  @setup_roles [:event_admin, :competition_manager]

  @impl true
  def mount(%{"event_id" => event_id, "round_id" => round_id}, _session, socket) do
    with %StaffUser{status: :active} = staff <- socket.assigns[:current_staffuser],
         {:ok, event_uuid} <- Ecto.UUID.cast(event_id),
         {:ok, round_uuid} <- Ecto.UUID.cast(round_id),
         {:ok, round} <- fetch_round(round_uuid),
         true <- round.event_id == event_uuid,
         true <- ActiveEventRole.authorized?(staff.id, event_uuid, @setup_roles) do
      fresh = Repo.get!(StaffUser, staff.id)

      socket =
        socket
        |> assign(:current_staff_user, fresh)
        |> assign(:page_title, "Groups and sides")
        |> assign(:current_path, ~p"/admin/events/#{event_uuid}/rounds/#{round_uuid}/groups")
        |> assign(:event_id, event_uuid)
        |> assign(:round_id, round_uuid)
        |> assign(:round, round)
        |> assign(:can_mutate, pre_open?(round))
        |> refresh_assignments(round)

      {:ok, socket}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "You are not allowed to configure PlayingGroups for this Round.")
         |> push_navigate(to: ~p"/admin")}
    end
  end

  @impl true
  def handle_event("configure_competition", _params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    case ConfigureRoundCompetition.run(staff, event_id, round.id, %{}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Primary RoundCompetition configured.")
         |> refresh_assignments(round)}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "You are not allowed to configure competition setup.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not configure RoundCompetition.")}
    end
  end

  def handle_event("enable_solo_sides", _params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    case ConfigureRoundCompetition.run(staff, event_id, round.id, %{solo_sides_permitted: true}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intentional solo sides are enabled for this competition.")
         |> refresh_assignments(round)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to change competition setup.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not update competition solo policy.")}
    end
  end

  def handle_event("create_competition_side", %{"formation" => formation}, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id
    competition = socket.assigns.round_competition

    case parse_side_formation(formation) do
      {:ok, side_formation} ->
        case CreateCompetitionSide.run(
               staff,
               event_id,
               round.id,
               competition.id,
               side_formation
             ) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Competition side created.")
             |> refresh_assignments(round)}

          {:error, :forbidden} ->
            {:noreply,
             put_flash(socket, :error, "You are not allowed to create competition sides.")}

          {:error, {:invalid_round_state, state}} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Competition side setup is not allowed while the Round is #{state}."
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not create competition side.")}
        end

      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Side formation must be partnership or solo.")}
    end
  end

  def handle_event(
        "set_side_membership",
        %{"side" => %{"side_id" => side_id, "entry_ids" => entry_ids_raw}},
        socket
      ) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id
    competition = socket.assigns.round_competition

    with {:ok, side_uuid} <- InputParsing.parse_uuid(side_id),
         {:ok, entry_ids} <- parse_entry_id_list(entry_ids_raw) do
      case SetSideMembership.run(
             staff,
             event_id,
             round.id,
             competition.id,
             side_uuid,
             entry_ids
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Competition side membership saved.")
           |> refresh_assignments(round)}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to set side membership.")}

        {:error, {:invalid_round_state, state}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Side membership cannot change while the Round is #{state}."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save competition side membership.")}
      end
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Side and entries must be valid values.")}
    end
  end

  def handle_event("create_group", _params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    case Competition.create_playing_group(event_id, round.id, actor: staff) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Playing group created.")
         |> refresh_assignments(round)}

      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "Could not create Playing group.")}
    end
  end

  def handle_event(
        "assign_entry",
        %{"assignment" => %{"entry_id" => entry_id, "group_id" => group_id}},
        socket
      ) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    with {:ok, entry_uuid} <- InputParsing.parse_uuid(entry_id),
         {:ok, group_uuid} <- InputParsing.parse_uuid(group_id) do
      case AssignEntryToGroup.run(staff, event_id, round.id, entry_uuid, group_uuid) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Entry assigned to group.")
           |> refresh_assignments(round)}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to assign group membership.")}

        {:error, :group_capacity_exceeded} ->
          {:noreply, put_flash(socket, :error, "That group is already full (maximum 4 players).")}

        {:error, :not_current_starting_participant} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Only current expected or checked-in starters can be assigned."
           )}

        {:error, {:invalid_round_state, state}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Group assignment is not allowed while the Round is #{state}."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not assign entry to group.")}
      end
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Entry and group must be valid identifiers.")}
    end
  end

  def handle_event(
        "assign_start",
        %{
          "start" => %{
            "group_id" => group_id,
            "round_hole_id" => round_hole_id,
            "position" => position
          }
        },
        socket
      ) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    round = socket.assigns.round
    event_id = socket.assigns.event_id

    with {:ok, group_uuid} <- InputParsing.parse_uuid(group_id),
         {:ok, hole_uuid} <- InputParsing.parse_uuid(round_hole_id),
         {:ok, position_int} <- InputParsing.parse_positive_integer(position) do
      case AssignPlayingGroupStart.run(
             staff,
             event_id,
             round.id,
             group_uuid,
             hole_uuid,
             position_int
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Starting assignment saved.")
           |> refresh_assignments(round)}

        {:error, :forbidden} ->
          {:noreply, put_flash(socket, :error, "You are not allowed to assign shotgun starts.")}

        {:error, {:invalid_round_state, state}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Start assignment is not allowed while the Round is #{state}."
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not assign shotgun start.")}
      end
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Group, hole, and position must be valid values.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.staff
        flash={@flash}
        page_title={@page_title}
        eyebrow="Event workspace"
        current_staff_user={@current_staff_user}
        current_path={@current_path}
        event_id={@event_id}
        round_id={@round_id}
        status_badges={[%{id: "round-state-badge", label: "Round #{@round.state}"}]}
        breadcrumbs={[
          %{label: "Dashboard", href: ~p"/admin"},
          %{label: "Round setup", href: ~p"/admin/events/#{@event_id}/rounds/#{@round_id}/setup"},
          %{label: "Groups"}
        ]}
      >
        <section id="group-assignment" class="space-y-6">
          <p id="round-state" class="sr-only">State: {@round.state}</p>
          <p class="text-sm text-base-content/70">
            Physical Playing Groups are separate from Competition Sides.
          </p>
          <section
            id="competition-sides-section"
            class="rounded-2xl border border-primary/30 bg-base-100 p-4 space-y-4"
          >
            <header class="space-y-1">
              <h2 class="text-lg font-semibold">Competition sides</h2>
              <p class="text-sm text-base-content/70">
                Configure competitive sides for the primary RoundCompetition (not physical groups).
              </p>
            </header>

            <%= if is_nil(@round_competition) and @can_mutate do %>
              <button
                id="configure-round-competition-button"
                type="button"
                phx-click="configure_competition"
                class="btn btn-outline btn-sm"
              >
                Configure primary competition
              </button>
            <% end %>

            <%= if @round_competition do %>
              <p id="round-competition-summary" class="text-sm">
                Policy: {@round_competition.scoring_policy_identifier} · Solo sides permitted: {@round_competition.solo_sides_permitted}
              </p>

              <%= if @can_mutate and not @round_competition.solo_sides_permitted do %>
                <button
                  id="enable-solo-sides-button"
                  type="button"
                  phx-click="enable_solo_sides"
                  class="btn btn-outline btn-sm"
                >
                  Enable intentional solo sides
                </button>
              <% end %>

              <%= if @can_mutate do %>
                <div class="flex flex-wrap gap-2">
                  <button
                    id="create-competition-side-partnership"
                    type="button"
                    phx-click="create_competition_side"
                    phx-value-formation="partnership"
                    class="btn btn-sm btn-outline"
                  >
                    Add partnership side
                  </button>
                  <%= if @round_competition.solo_sides_permitted do %>
                    <button
                      id="create-competition-side-solo"
                      type="button"
                      phx-click="create_competition_side"
                      phx-value-formation="solo"
                      class="btn btn-sm btn-outline"
                    >
                      Add intentional solo side
                    </button>
                  <% end %>
                </div>
              <% end %>

              <div id="competition-side-list" class="space-y-3">
                <article
                  :for={side <- @competition_sides}
                  id={"competition-side-#{side.id}"}
                  class="rounded-xl border border-base-300 p-3 space-y-2"
                >
                  <p class="font-medium">
                    Side {String.slice(side.id, 0, 8)} · Formation: {side.formation}
                  </p>
                  <p id={"competition-side-result-#{side.id}"} class="text-sm text-base-content/70">
                    SideResult: {side.result_state}
                  </p>
                  <ul id={"competition-side-members-#{side.id}"} class="text-sm list-disc pl-5">
                    <li :for={member_id <- side.member_ids}>Entry {member_id}</li>
                  </ul>

                  <%= if @can_mutate do %>
                    <.form
                      id={"set-side-membership-form-#{side.id}"}
                      for={%{}}
                      phx-submit="set_side_membership"
                      class="flex flex-wrap gap-2 items-end"
                    >
                      <input type="hidden" name="side[side_id]" value={side.id} />
                      <.input
                        id={"set-side-membership-entries-#{side.id}"}
                        name="side[entry_ids]"
                        type="text"
                        label="Current starter entry IDs (comma-separated)"
                        value={Enum.join(side.member_ids, ",")}
                      />
                      <button type="submit" class="btn btn-sm btn-outline">Save side membership</button>
                    </.form>
                  <% end %>
                </article>
              </div>
            <% end %>
          </section>

          <section id="physical-playing-groups-section" class="space-y-4">
            <h2 class="text-lg font-semibold">Physical playing groups</h2>
            <%= if @can_mutate do %>
              <div class="flex gap-3">
                <button
                  id="create-playing-group-button"
                  type="button"
                  phx-click="create_group"
                  class="btn btn-primary btn-sm"
                >
                  Create empty group
                </button>
              </div>
            <% end %>

            <div id="unassigned-entries" class="rounded-2xl border border-base-300 bg-base-100 p-4">
              <h2 class="text-lg font-semibold">Unassigned entries</h2>
              <ul class="mt-2 space-y-1 text-sm">
                <li :for={entry <- @unassigned_entries} id={"unassigned-entry-#{entry.id}"}>
                  Entry {entry.id}
                </li>
              </ul>
            </div>

            <div id="group-list" class="space-y-4">
              <article
                :for={group <- @groups}
                id={"playing-group-#{group.id}"}
                class="rounded-2xl border border-base-300 bg-base-100 p-4 space-y-3"
              >
                <header class="flex flex-wrap items-baseline justify-between gap-2">
                  <h2 class="font-semibold">Group {String.slice(group.id, 0, 8)}</h2>
                  <p id={"group-member-count-#{group.id}"} class="text-sm text-base-content/70">
                    Members: {group.member_count} / {PlayingGroupReadiness.setup_capacity_max()}
                    <%= if not group.setup_complete? do %>
                      <span id={"group-incomplete-#{group.id}"} class="text-warning">
                        · Incomplete setup
                      </span>
                    <% end %>
                  </p>
                </header>

                <p id={"group-start-label-#{group.id}"} class="text-sm">
                  Start: {group.start_label}
                </p>

                <ul id={"group-members-#{group.id}"} class="text-sm list-disc pl-5">
                  <li :for={member_id <- group.member_ids}>Entry {member_id}</li>
                </ul>

                <%= if @can_mutate do %>
                  <.form
                    id={"assign-entry-form-#{group.id}"}
                    for={%{}}
                    phx-submit="assign_entry"
                    class="flex flex-wrap gap-2 items-end"
                  >
                    <input type="hidden" name="assignment[group_id]" value={group.id} />
                    <.input
                      id={"assign-entry-select-#{group.id}"}
                      name="assignment[entry_id]"
                      type="select"
                      label="Assign entry"
                      value=""
                      options={movable_entry_options(@eligible_starters, group.id)}
                      prompt="Select entry"
                    />
                    <button type="submit" class="btn btn-sm btn-outline">Assign</button>
                  </.form>

                  <.form
                    id={"assign-start-form-#{group.id}"}
                    for={%{}}
                    phx-submit="assign_start"
                    class="flex flex-wrap gap-2 items-end"
                  >
                    <input type="hidden" name="start[group_id]" value={group.id} />
                    <.input
                      id={"assign-start-hole-#{group.id}"}
                      name="start[round_hole_id]"
                      type="select"
                      label="Starting hole"
                      value=""
                      options={@round_hole_options}
                      prompt="Select hole"
                    />
                    <.input
                      id={"assign-start-position-#{group.id}"}
                      name="start[position]"
                      type="number"
                      label="Position"
                      value=""
                    />
                    <button type="submit" class="btn btn-sm btn-outline">Save start</button>
                  </.form>
                <% end %>
              </article>
            </div>
          </section>
        </section>
      </AppShell.staff>
    </Layouts.app>
    """
  end

  defp fetch_round(round_id) do
    case Ash.get(Round, round_id, authorize?: false) do
      {:ok, round} -> {:ok, round}
      {:error, error} -> {:error, error}
    end
  end

  defp pre_open?(round), do: round.state in [:draft, :ready]

  defp refresh_assignments(socket, round) do
    round = Repo.get!(Round, round.id)

    groups = list_groups(round.id)
    eligible_starters = list_eligible_current_starters(round.id)

    unassigned =
      eligible_starters
      |> Enum.filter(&is_nil(&1.playing_group_id))
      |> Enum.sort_by(&Ecto.UUID.dump!(&1.id))

    round_holes = list_round_holes(round.id)
    round_competition = load_primary_round_competition(round.id)
    competition_sides = list_competition_sides(round_competition, round.id)

    socket
    |> assign(:round, round)
    |> assign(:can_mutate, pre_open?(round))
    |> assign(:round_competition, round_competition)
    |> assign(:competition_sides, competition_sides)
    |> assign(:groups, groups)
    |> assign(:eligible_starters, eligible_starters)
    |> assign(:unassigned_entries, unassigned)
    |> assign(:round_hole_options, round_hole_options(round_holes))
  end

  defp list_groups(round_id) do
    eligible_by_group =
      round_id
      |> list_eligible_current_starters()
      |> Enum.group_by(& &1.playing_group_id, & &1.id)

    holes_by_id =
      round_id
      |> list_round_holes()
      |> Map.new(&{&1.id, &1})

    PlayingGroup
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&Ecto.UUID.dump!(&1.id))
    |> Enum.map(fn group ->
      member_ids = Map.get(eligible_by_group, group.id, [])
      member_count = length(member_ids)

      start_label =
        case {group.starting_round_hole_id, group.starting_position} do
          {hole_id, pos} when not is_nil(hole_id) and not is_nil(pos) ->
            hole = Map.fetch!(holes_by_id, hole_id)
            StartingPositionLabel.format(hole.display_hole_number, pos)

          _ ->
            "Not assigned"
        end

      %{
        id: group.id,
        member_ids: member_ids,
        member_count: member_count,
        setup_complete?: PlayingGroupReadiness.group_setup_complete?(member_count, group),
        start_label: start_label
      }
    end)
  end

  defp list_eligible_current_starters(round_id) do
    StartingParticipant.list_current_starters_in_round(Repo, round_id)
  end

  defp list_round_holes(round_id) do
    RoundHole
    |> Ash.Query.filter(round_id == ^round_id)
    |> Ash.Query.sort(play_order: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp round_hole_options(holes) do
    Enum.map(holes, fn hole ->
      {"Hole #{hole.display_hole_number} (play #{hole.play_order})", hole.id}
    end)
  end

  defp movable_entry_options(starters, target_group_id) do
    starters
    |> Enum.reject(fn entry -> entry.playing_group_id == target_group_id end)
    |> Enum.map(fn entry -> {entry.id, entry.id} end)
  end

  defp load_primary_round_competition(round_id) do
    RoundCompetition
    |> Ash.Query.filter(round_id == ^round_id and is_primary == true)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, competition} -> competition
      _ -> nil
    end
  end

  defp list_competition_sides(nil, _round_id), do: []

  defp list_competition_sides(_competition, round_id) do
    sides =
      CompetitionSide
      |> Ash.Query.filter(round_id == ^round_id)
      |> Ash.read!(authorize?: false)
      |> Enum.sort_by(&Ecto.UUID.dump!(&1.id))

    results_by_side =
      CompetitionSideResult
      |> Ash.Query.filter(competition_side_id in ^Enum.map(sides, & &1.id))
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.competition_side_id, &1.state})

    memberships =
      CompetitionSideMembership
      |> Ash.Query.filter(round_id == ^round_id)
      |> Ash.read!(authorize?: false)
      |> Enum.group_by(& &1.competition_side_id, & &1.round_entry_id)

    entries_by_id =
      RoundEntry
      |> Ash.Query.filter(round_id == ^round_id)
      |> Ash.read!(authorize?: false)
      |> Map.new(&{&1.id, &1})

    Enum.map(sides, fn side ->
      all_member_ids = Map.get(memberships, side.id, [])

      current_member_ids = current_starter_member_ids(all_member_ids, entries_by_id)

      %{
        id: side.id,
        formation: side.formation,
        result_state: Map.get(results_by_side, side.id, :unknown),
        member_ids: current_member_ids
      }
    end)
  end

  defp parse_side_formation("partnership"), do: {:ok, :partnership}
  defp parse_side_formation("solo"), do: {:ok, :solo}
  defp parse_side_formation(_), do: {:error, :invalid_input}

  defp parse_entry_id_list(raw) when is_binary(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while([], fn id, acc ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> {:cont, [uuid | acc]}
        :error -> {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:error, _} = err -> err
      ids -> {:ok, Enum.reverse(ids)}
    end
  end

  defp parse_entry_id_list(_), do: {:error, :invalid_input}

  defp current_starter_member_ids(member_ids, entries_by_id) do
    Enum.filter(member_ids, &side_member_current_starter?(entries_by_id, &1))
  end

  defp side_member_current_starter?(entries_by_id, entry_id) do
    case Map.get(entries_by_id, entry_id) do
      nil -> false
      entry -> StartingParticipant.current_starting_participant?(entry)
    end
  end
end
