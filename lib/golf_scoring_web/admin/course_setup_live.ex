defmodule GolfScoringWeb.Admin.CourseSetupLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  alias GolfScoring.Accounts.Checks.ActiveEventRole
  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.GolfCatalog
  alias GolfScoring.Repo
  alias GolfScoringWeb.Admin.InputParsing

  @impl true
  def mount(%{"event_id" => event_id}, _session, socket) do
    with %StaffUser{status: :active} = staff <- socket.assigns[:current_staffuser],
         {:ok, event_uuid} <- Ecto.UUID.cast(event_id),
         true <- ActiveEventRole.authorized?(staff.id, event_uuid, :event_admin) do
      fresh = Repo.get!(StaffUser, staff.id)

      {:ok,
       socket
       |> assign(:current_staff_user, fresh)
       |> assign(:page_title, "Course catalog setup")
       |> assign(:current_path, ~p"/admin/events/#{event_uuid}/course-setup")
       |> assign(:event_id, event_uuid)
       |> assign(:round_id, nil)
       |> assign(:can_mutate, true)
       |> assign(:courses, list_active_courses())
       |> assign(:selected_course_id, nil)
       |> assign(:course_holes, [])
       |> assign(:tee_sets, [])
       |> assign(:tee_profiles, [])}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(
           :error,
           "You are not allowed to configure the course catalog for this Event."
         )
         |> push_navigate(to: ~p"/admin")}
    end
  end

  @impl true
  def handle_event("create_course", %{"course" => params}, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    event_id = socket.assigns.event_id

    case GolfCatalog.create_course(event_id, params, actor: staff) do
      {:ok, course} ->
        {:noreply,
         socket
         |> put_flash(:info, "Course created.")
         |> assign(:courses, list_active_courses())
         |> assign(:selected_course_id, course.id)
         |> refresh_course_details(course.id)}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         put_flash(socket, :error, "Catalog changes require an active Event Admin role.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not create the Course.")}
    end
  end

  @impl true
  def handle_event("select_course", %{"course_id" => course_id}, socket) do
    case Ecto.UUID.cast(course_id) do
      {:ok, course_uuid} ->
        {:noreply,
         socket
         |> assign(:selected_course_id, course_uuid)
         |> refresh_course_details(course_uuid)}

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid Course selection.")}
    end
  end

  @impl true
  def handle_event("configure_hole", %{"hole" => params}, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    event_id = socket.assigns.event_id
    course_id = socket.assigns.selected_course_id

    case InputParsing.parse_positive_integer(params["hole_number"]) do
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Hole number must be a positive integer.")}

      {:ok, hole_number} ->
        attrs = %{course_id: course_id, hole_number: hole_number}

        case GolfCatalog.configure_course_hole(event_id, attrs, actor: staff) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Course hole saved.")
             |> refresh_course_details(course_id)}

          {:error, %Ash.Error.Forbidden{}} ->
            {:noreply,
             put_flash(socket, :error, "Catalog changes require an active Event Admin role.")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not save the Course hole.")}
        end
    end
  end

  @impl true
  def handle_event("configure_tee_set", %{"tee_set" => params}, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    event_id = socket.assigns.event_id
    course_id = socket.assigns.selected_course_id

    attrs = Map.put(params, "course_id", course_id)

    case GolfCatalog.configure_tee_set(event_id, attrs, actor: staff) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tee set saved.")
         |> refresh_course_details(course_id)}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         put_flash(socket, :error, "Catalog changes require an active Event Admin role.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save the Tee set.")}
    end
  end

  @impl true
  def handle_event("configure_tee_profile", %{"tee_profile" => params}, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)
    event_id = socket.assigns.event_id
    course_id = socket.assigns.selected_course_id
    course_holes = socket.assigns.course_holes

    with {:ok, tee_set_id} <- InputParsing.parse_uuid(params["tee_set_id"]),
         {:ok, slope_rating} <- InputParsing.parse_positive_integer(params["slope_rating"]),
         {:ok, total_par} <- InputParsing.parse_positive_integer(params["total_par"]),
         {:ok, course_rating} <- InputParsing.parse_decimal(params["course_rating"]),
         {:ok, hole_ratings} <- build_hole_ratings(params, course_holes),
         rating_label when is_binary(rating_label) <- present_string(params["rating_label"]) do
      attrs = %{
        tee_set_id: tee_set_id,
        rating_label: rating_label,
        course_rating: course_rating,
        slope_rating: slope_rating,
        total_par: total_par,
        hole_ratings: hole_ratings
      }

      case GolfCatalog.configure_tee_rating_profile(event_id, attrs, actor: staff) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Tee rating profile saved.")
           |> refresh_course_details(course_id)}

        {:error, %Ash.Error.Forbidden{}} ->
          {:noreply,
           put_flash(socket, :error, "Catalog changes require an active Event Admin role.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save the Tee rating profile.")}
      end
    else
      {:error, :invalid_input} ->
        {:noreply, put_flash(socket, :error, "Tee profile fields must be valid.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Rating label is required.")}
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
        breadcrumbs={[
          %{label: "Dashboard", href: ~p"/admin"},
          %{label: "Course setup"}
        ]}
      >
        <section id="course-setup" class="space-y-6">
          <%= if @can_mutate do %>
            <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
              <h2 class="text-lg font-semibold">Create Course</h2>
              <.form id="course-create-form" for={%{}} phx-submit="create_course">
                <div class="grid gap-3 sm:grid-cols-2">
                  <.input name="course[name]" type="text" label="Name" value="" required />
                  <.input name="course[location]" type="text" label="Location" value="" required />
                </div>
                <button id="course-create-button" type="submit" class="btn btn-primary mt-4">
                  Create Course
                </button>
              </.form>
            </div>

            <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
              <h2 class="text-lg font-semibold">Select Course</h2>
              <.form id="course-select-form" for={%{}} phx-change="select_course">
                <.input
                  id="course-select"
                  name="course_id"
                  type="select"
                  label="Course"
                  value={@selected_course_id || ""}
                  options={Enum.map(@courses, &{&1.name, &1.id})}
                  prompt="Choose a course"
                />
              </.form>
            </div>

            <%= if @selected_course_id do %>
              <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
                <h2 class="text-lg font-semibold">Course holes</h2>
                <ul id="course-hole-list" class="text-sm space-y-1">
                  <li :for={hole <- @course_holes}>
                    Hole {hole.hole_number} · id {hole.id}
                  </li>
                </ul>
                <.form id="course-hole-form" for={%{}} phx-submit="configure_hole">
                  <.input name="hole[hole_number]" type="number" label="Hole number" value="" />
                  <button id="course-hole-save-button" type="submit" class="btn btn-primary mt-3">
                    Save hole
                  </button>
                </.form>
              </div>

              <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4">
                <h2 class="text-lg font-semibold">Tee sets</h2>
                <ul id="tee-set-list" class="text-sm space-y-1">
                  <li :for={tee <- @tee_sets}>{tee.name}</li>
                </ul>
                <.form id="tee-set-form" for={%{}} phx-submit="configure_tee_set">
                  <.input
                    name="tee_set[name]"
                    type="text"
                    label="Tee set name"
                    value=""
                    placeholder="e.g. White"
                  />
                  <button id="tee-set-save-button" type="submit" class="btn btn-primary mt-3">
                    Save tee set
                  </button>
                </.form>
              </div>

              <div
                :if={@tee_sets != []}
                class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm space-y-4"
              >
                <h2 class="text-lg font-semibold">Tee rating profiles</h2>
                <ul id="tee-profile-list" class="text-sm space-y-1">
                  <li :for={profile <- @tee_profiles}>{profile.rating_label}</li>
                </ul>
                <.form id="tee-profile-form" for={%{}} phx-submit="configure_tee_profile">
                  <.input
                    name="tee_profile[tee_set_id]"
                    type="select"
                    label="Tee set"
                    value=""
                    options={Enum.map(@tee_sets, &{&1.name, &1.id})}
                    prompt="Choose tee set"
                  />
                  <.input
                    name="tee_profile[rating_label]"
                    type="text"
                    label="Rating label"
                    value=""
                    placeholder="e.g. Competition White"
                  />
                  <.input
                    name="tee_profile[course_rating]"
                    type="text"
                    label="Course rating"
                    value=""
                    placeholder="e.g. 70.8"
                  />
                  <.input
                    name="tee_profile[slope_rating]"
                    type="number"
                    label="Slope"
                    value=""
                    placeholder="55–155"
                  />
                  <.input
                    name="tee_profile[total_par]"
                    type="number"
                    label="Total par"
                    value=""
                    placeholder="Sum of hole pars"
                  />
                  <div id="tee-profile-hole-ratings" class="mt-4 space-y-3">
                    <h3 class="text-sm font-semibold">Per-hole ratings</h3>
                    <%= for hole <- @course_holes do %>
                      <div class="grid gap-2 rounded-lg border border-base-200 p-3 sm:grid-cols-4">
                        <p class="text-sm font-medium sm:col-span-4">
                          Physical hole {hole.hole_number}
                        </p>
                        <.input
                          name={"tee_profile[hole_ratings][#{hole.id}][par]"}
                          type="number"
                          label="Par"
                          value=""
                          placeholder="3–5"
                        />
                        <.input
                          name={"tee_profile[hole_ratings][#{hole.id}][stroke_index]"}
                          type="number"
                          label="Stroke index"
                          value=""
                          placeholder="1–18"
                        />
                        <.input
                          name={"tee_profile[hole_ratings][#{hole.id}][distance_m]"}
                          type="number"
                          label="Distance (m)"
                          value=""
                        />
                      </div>
                    <% end %>
                  </div>
                  <button id="tee-profile-save-button" type="submit" class="btn btn-primary mt-3">
                    Save tee profile
                  </button>
                </.form>
              </div>
            <% end %>
          <% end %>
        </section>
      </AppShell.staff>
    </Layouts.app>
    """
  end

  defp refresh_course_details(socket, course_id) do
    assign(socket,
      course_holes: list_course_holes(course_id),
      tee_sets: list_tee_sets(course_id),
      tee_profiles: list_tee_profiles(course_id)
    )
  end

  defp list_active_courses do
    Repo.query!(
      "SELECT id::text, name FROM courses WHERE status = 'active' ORDER BY inserted_at DESC"
    ).rows
    |> Enum.map(fn [id, name] -> %{id: Ecto.UUID.cast!(id), name: name} end)
  end

  defp list_course_holes(course_id) do
    Repo.query!(
      "SELECT id::text, hole_number FROM course_holes WHERE course_id = $1::uuid ORDER BY hole_number",
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> Enum.map(fn [id, hole_number] -> %{id: Ecto.UUID.cast!(id), hole_number: hole_number} end)
  end

  defp list_tee_sets(course_id) do
    Repo.query!(
      "SELECT id::text, name FROM tee_sets WHERE course_id = $1::uuid ORDER BY name",
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> Enum.map(fn [id, name] -> %{id: Ecto.UUID.cast!(id), name: name} end)
  end

  defp list_tee_profiles(course_id) do
    Repo.query!(
      """
      SELECT p.id::text, p.rating_label
      FROM tee_rating_profiles p
      INNER JOIN tee_sets t ON t.id = p.tee_set_id
      WHERE t.course_id = $1::uuid
      ORDER BY p.rating_label
      """,
      [Ecto.UUID.dump!(course_id)]
    ).rows
    |> Enum.map(fn [id, label] -> %{id: Ecto.UUID.cast!(id), rating_label: label} end)
  end

  defp build_hole_ratings(params, course_holes) when is_list(course_holes) do
    ratings_params = Map.get(params, "hole_ratings", %{})

    course_holes
    |> Enum.reduce_while({:ok, []}, fn hole, {:ok, acc} ->
      hole_params = Map.get(ratings_params, to_string(hole.id), %{})

      with {:ok, par} <- InputParsing.parse_positive_integer(hole_params["par"]),
           {:ok, stroke_index} <- InputParsing.parse_positive_integer(hole_params["stroke_index"]),
           {:ok, distance_m} <-
             InputParsing.parse_optional_positive_integer(hole_params["distance_m"]) do
        rating = %{
          course_hole_id: hole.id,
          par: par,
          stroke_index: stroke_index,
          distance_m: distance_m
        }

        {:cont, {:ok, [rating | acc]}}
      else
        {:error, :invalid_input} -> {:halt, {:error, :invalid_input}}
      end
    end)
    |> case do
      {:ok, ratings} -> {:ok, Enum.reverse(ratings)}
      error -> error
    end
  end

  defp present_string(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp present_string(_), do: nil
end
