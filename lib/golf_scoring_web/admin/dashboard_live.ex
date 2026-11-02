defmodule GolfScoringWeb.Admin.DashboardLive do
  @moduledoc false

  use GolfScoringWeb, :live_view

  alias GolfScoring.Accounts.StaffUser
  alias GolfScoring.Competition.Services.CreateEvent
  alias GolfScoring.Repo

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns[:current_staffuser] do
      %StaffUser{status: :active} = staff ->
        fresh = Repo.get!(StaffUser, staff.id)

        {:ok,
         socket
         |> assign(:current_staff_user, fresh)
         |> assign(:page_title, "Admin dashboard")
         |> assign(:current_path, ~p"/admin")
         |> assign(:event_id, nil)
         |> assign(:can_create_event, can_create_event?(fresh))
         |> assign(:last_event_id, nil)}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/admin/sign-in")}
    end
  end

  @impl true
  def handle_event("create_event", _params, socket) do
    staff = Repo.get!(StaffUser, socket.assigns.current_staff_user.id)

    case CreateEvent.create(staff, %{"source" => "admin_dashboard"}) do
      {:ok, %{event: event}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event created.")
         |> assign(:last_event_id, event.id)
         |> assign(:event_id, event.id)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You are not allowed to create Events.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Event creation failed.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <AppShell.staff
        flash={@flash}
        page_title={@page_title}
        eyebrow="Staff administration"
        current_staff_user={@current_staff_user}
        current_path={@current_path}
        event_id={@event_id}
        breadcrumbs={[%{label: "Dashboard"}]}
      >
        <section id="admin-dashboard" class="space-y-6">
          <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
            <h2 class="text-lg font-semibold">Events</h2>
            <p class="mt-2 text-sm text-base-content/70">
              Create a draft Event with an initial Event Admin assignment.
            </p>

            <div class="mt-4 flex flex-wrap items-center gap-3">
              <%= if @can_create_event do %>
                <.button id="create-event-button" phx-click="create_event">
                  Create Event
                </.button>
              <% else %>
                <p id="create-event-unavailable" class="text-sm text-base-content/70">
                  Event creation requires an active SYSTEM_ADMIN account.
                </p>
              <% end %>
            </div>

            <%= if @last_event_id do %>
              <div id="last-created-event" data-event-id={@last_event_id} class="mt-4 space-y-2">
                <p class="text-sm text-success">Event created.</p>
                <.link
                  navigate={~p"/admin/events/#{@last_event_id}/course-setup"}
                  class="btn btn-outline btn-sm min-h-11"
                >
                  Open course setup
                </.link>
              </div>
            <% end %>
          </div>
        </section>
      </AppShell.staff>
    </Layouts.app>
    """
  end

  defp can_create_event?(%StaffUser{status: :active, system_admin: true}), do: true
  defp can_create_event?(_), do: false
end
