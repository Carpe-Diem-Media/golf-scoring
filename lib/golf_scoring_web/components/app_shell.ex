defmodule GolfScoringWeb.AppShell do
  @moduledoc """
  Shared application chrome for staff and player LiveViews.
  """
  use GolfScoringWeb, :html

  alias GolfScoring.Accounts.StaffUser

  @doc """
  Staff / admin operational shell.
  """
  attr :flash, :map, required: true
  attr :page_title, :string, required: true
  attr :eyebrow, :string, default: nil
  attr :current_staff_user, StaffUser, default: nil
  attr :current_path, :string, required: true
  attr :event_id, :any, default: nil
  attr :round_id, :any, default: nil
  attr :breadcrumbs, :list, default: []
  attr :status_badges, :list, default: []

  slot :page_actions
  slot :inner_block, required: true

  def staff(assigns) do
    primary_nav = staff_primary_nav(assigns.current_path)
    event_nav = staff_event_nav(assigns)
    mobile_nav_id = "staff-mobile-nav"

    assigns =
      assigns
      |> assign(:primary_nav, primary_nav)
      |> assign(:event_nav, event_nav)
      |> assign(:mobile_nav_id, mobile_nav_id)
      |> assign(:system_admin?, system_admin?(assigns.current_staff_user))

    ~H"""
    <div
      id="staff-application-shell"
      phx-hook=".StaffMobileNav"
      class="min-h-dvh flex flex-col bg-base-100"
    >
      <header
        id="staff-shell-header"
        class="sticky top-0 z-40 border-b border-base-300 bg-base-100/95 backdrop-blur-sm"
      >
        <div class="mx-auto flex max-w-7xl items-center gap-3 px-4 py-3 sm:px-6 lg:px-8">
          <button
            type="button"
            id="staff-shell-menu-toggle"
            class="inline-flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded-lg text-base-content hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary lg:hidden"
            aria-controls={@mobile_nav_id}
            aria-expanded="false"
            aria-haspopup="true"
          >
            <span class="sr-only">Open navigation menu</span>
            <.icon name="hero-bars-3" class="size-6" />
          </button>

          <.link
            navigate={~p"/admin"}
            class="flex min-h-11 items-center gap-2 rounded-lg px-2 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
          >
            <span class="text-base font-semibold tracking-tight text-base-content">Golf Scoring</span>
            <span
              :if={@system_admin?}
              class="inline-flex items-center rounded-md border border-base-300 px-2 py-0.5 text-xs font-medium text-base-content/80"
            >
              System admin
            </span>
          </.link>

          <div class="ml-auto flex items-center gap-2">
            <.link
              href={~p"/admin/sign-out"}
              method="delete"
              id="staff-sign-out"
              class="inline-flex min-h-11 items-center rounded-lg px-3 text-sm font-medium text-base-content hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
            >
              Sign out
            </.link>
          </div>
        </div>
      </header>

      <div class="mx-auto flex w-full max-w-7xl flex-1 gap-0 lg:gap-8 lg:px-8 lg:py-6">
        <nav
          id="staff-shell-nav"
          aria-label="Staff primary"
          class="hidden w-56 shrink-0 flex-col gap-1 lg:flex"
        >
          <.staff_nav_links items={@primary_nav} id_suffix="" />
          <div :if={@event_nav != []} class="mt-6 border-t border-base-300 pt-4">
            <p class="mb-2 px-3 text-sm text-base-content/70">Event workspace</p>
            <.staff_nav_links items={@event_nav} id_suffix="" />
          </div>
        </nav>

        <nav
          id={@mobile_nav_id}
          aria-label="Staff primary mobile"
          hidden
          class="fixed inset-x-0 top-[3.25rem] z-30 max-h-[calc(100dvh-3.25rem)] flex-col gap-1 overflow-y-auto border-b border-base-300 bg-base-100 p-4 shadow-lg lg:hidden"
        >
          <div class="mb-3 flex items-center justify-between gap-2">
            <p class="text-sm font-medium text-base-content">Menu</p>
            <button
              type="button"
              id="staff-shell-menu-close"
              class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-lg text-base-content hover:bg-base-200 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
            >
              <span class="sr-only">Close navigation menu</span>
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </div>
          <.staff_nav_links items={@primary_nav} id_suffix="-mobile" />
          <div :if={@event_nav != []} class="mt-4 border-t border-base-300 pt-4">
            <p class="mb-2 px-3 text-sm text-base-content/70">Event workspace</p>
            <.staff_nav_links items={@event_nav} id_suffix="-mobile" />
          </div>
        </nav>

        <main id="staff-shell-main" class="min-w-0 flex-1 px-4 py-8 sm:px-6 lg:py-10 lg:px-0">
          <.staff_page_header
            eyebrow={@eyebrow}
            page_title={@page_title}
            breadcrumbs={@breadcrumbs}
            status_badges={@status_badges}
          >
            <:page_actions :if={@page_actions != []}>
              {render_slot(@page_actions)}
            </:page_actions>
          </.staff_page_header>
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".StaffMobileNav">
      export default {
        mounted() {
          this.toggleBtn = this.el.querySelector("#staff-shell-menu-toggle")
          this.closeBtn = this.el.querySelector("#staff-shell-menu-close")
          this.drawer = this.el.querySelector("#staff-mobile-nav")

          this.onToggle = () => this.setOpen(!this.isOpen())
          this.onClose = () => this.setOpen(false)
          this.onKeydown = (event) => {
            if (event.key === "Escape" && this.isOpen()) {
              event.preventDefault()
              this.setOpen(false)
              this.toggleBtn?.focus()
            }
          }

          this.toggleBtn?.addEventListener("click", this.onToggle)
          this.closeBtn?.addEventListener("click", this.onClose)
          document.addEventListener("keydown", this.onKeydown)
          this.setOpen(false)
        },
        destroyed() {
          this.toggleBtn?.removeEventListener("click", this.onToggle)
          this.closeBtn?.removeEventListener("click", this.onClose)
          document.removeEventListener("keydown", this.onKeydown)
        },
        isOpen() {
          return this.drawer && !this.drawer.hidden
        },
        setOpen(open) {
          if (!this.drawer || !this.toggleBtn) return
          this.drawer.hidden = !open
          this.toggleBtn.setAttribute("aria-expanded", open ? "true" : "false")
          if (open) {
            this.closeBtn?.focus()
          }
        }
      }
    </script>
    """
  end

  @doc """
  Minimal player surface for denied or guest states (no authenticated navigation).
  """
  attr :flash, :map, required: true
  attr :page_title, :string, required: true

  slot :inner_block, required: true

  def player_guest(assigns) do
    ~H"""
    <div id="player-access-denied-shell" class="min-h-dvh flex flex-col bg-base-100">
      <header
        id="player-guest-header"
        class="border-b border-base-300 bg-base-100/95 backdrop-blur-sm"
      >
        <div class="mx-auto max-w-lg px-4 py-4">
          <p class="text-sm text-base-content/70">Golf Scoring</p>
          <h1 class="text-lg font-semibold tracking-tight text-base-content">{@page_title}</h1>
        </div>
      </header>

      <main id="player-guest-main" class="mx-auto w-full max-w-lg flex-1 px-4 py-8">
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end

  @doc """
  Mobile-first player shell.
  """
  attr :flash, :map, required: true
  attr :page_title, :string, required: true
  attr :player_name, :string, default: nil
  attr :current_path, :string, required: true

  slot :inner_block, required: true

  def player(assigns) do
    nav = player_nav(assigns.current_path)

    assigns = assign(assigns, :nav, nav)

    ~H"""
    <div id="player-application-shell" class="min-h-dvh flex flex-col bg-base-100 pb-20">
      <header
        id="player-shell-header"
        class="sticky top-0 z-40 border-b border-base-300 bg-base-100/95 backdrop-blur-sm"
      >
        <div class="mx-auto flex max-w-lg items-center justify-between gap-3 px-4 py-3">
          <div class="min-w-0">
            <p class="text-sm text-base-content/70">Golf Scoring</p>
            <h1 class="truncate text-lg font-semibold tracking-tight">{@page_title}</h1>
          </div>
          <p
            :if={@player_name}
            id="player-shell-identity"
            class="truncate text-sm text-base-content/80"
          >
            {@player_name}
          </p>
        </div>
      </header>

      <main id="player-shell-main" class="mx-auto w-full max-w-lg flex-1 px-4 py-8">
        {render_slot(@inner_block)}
      </main>

      <nav
        id="player-shell-nav"
        aria-label="Player"
        class="fixed inset-x-0 bottom-0 z-40 border-t border-base-300 bg-base-100/95 backdrop-blur-sm"
      >
        <ul class="mx-auto grid max-w-lg grid-cols-3 gap-1 px-2 py-2">
          <li :for={item <- @nav} class="min-w-0">
            <.player_nav_item item={item} />
          </li>
        </ul>
      </nav>
    </div>
    """
  end

  attr :items, :list, required: true
  attr :id_suffix, :string, default: ""

  defp staff_nav_links(assigns) do
    ~H"""
    <ul class="flex flex-col gap-0.5">
      <li :for={item <- @items}>
        <.link
          navigate={item.href}
          id={"#{item.id}#{@id_suffix}"}
          aria-current={if item.current, do: "page", else: false}
          class={[
            "flex min-h-11 items-center rounded-lg px-3 text-sm font-medium transition-colors focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
            item.current && "bg-base-200 text-base-content",
            !item.current && "text-base-content/80 hover:bg-base-200/60 hover:text-base-content",
            item.disabled && "pointer-events-none opacity-50"
          ]}
        >
          {item.label}
        </.link>
      </li>
    </ul>
    """
  end

  attr :item, :map, required: true

  defp player_nav_item(assigns) do
    ~H"""
    <%= if @item.disabled do %>
      <span
        id={@item.id}
        aria-disabled="true"
        class="flex min-h-11 flex-col items-center justify-center rounded-xl px-2 text-center text-xs font-medium text-base-content/40"
      >
        <.icon name={@item.icon} class="mb-0.5 size-5" />
        <span>{@item.label}</span>
      </span>
    <% else %>
      <.link
        navigate={@item.href}
        id={@item.id}
        aria-current={if @item.current, do: "page", else: false}
        class={[
          "flex min-h-11 flex-col items-center justify-center rounded-xl px-2 text-center text-xs font-medium focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
          @item.current && "bg-base-200 text-base-content",
          !@item.current && "text-base-content/80"
        ]}
      >
        <.icon name={@item.icon} class="mb-0.5 size-5" />
        <span>{@item.label}</span>
      </.link>
    <% end %>
    """
  end

  attr :eyebrow, :string, default: nil
  attr :page_title, :string, required: true
  attr :breadcrumbs, :list, default: []
  attr :status_badges, :list, default: []

  slot :page_actions

  defp staff_page_header(assigns) do
    ~H"""
    <header id="staff-page-header" class="mb-10 space-y-3">
      <nav :if={@breadcrumbs != []} id="staff-breadcrumbs" aria-label="Breadcrumb">
        <ol class="flex flex-wrap items-center gap-2 text-sm text-base-content/70">
          <li :for={{crumb, idx} <- Enum.with_index(@breadcrumbs)}>
            <span :if={idx > 0} aria-hidden="true" class="mr-2">/</span>
            <.link :if={crumb[:href]} navigate={crumb.href} class="hover:text-base-content">
              {crumb.label}
            </.link>
            <span
              :if={!crumb[:href]}
              aria-current={if idx == length(@breadcrumbs) - 1, do: "page", else: false}
            >
              {crumb.label}
            </span>
          </li>
        </ol>
      </nav>

      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-1">
          <p :if={@eyebrow} class="text-sm text-base-content/70">{@eyebrow}</p>
          <h1 id="staff-page-title" class="text-2xl font-semibold tracking-tight text-base-content">
            {@page_title}
          </h1>
          <div :if={@status_badges != []} class="flex flex-wrap gap-2 pt-1">
            <span
              :for={badge <- @status_badges}
              class="inline-flex items-center rounded-md border border-base-300 px-2 py-0.5 text-xs font-medium text-base-content/80"
              id={badge[:id]}
            >
              {badge.label}
            </span>
          </div>
        </div>
        <div :if={@page_actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@page_actions)}
        </div>
      </div>
    </header>
    """
  end

  defp staff_primary_nav(current_path) do
    [
      nav_item("staff-nav-dashboard", "Dashboard", ~p"/admin", current_path),
      nav_item("staff-nav-sign-in", "Sign in", ~p"/admin/sign-in", current_path, hidden: true)
    ]
    |> Enum.reject(& &1[:hidden])
  end

  defp staff_event_nav(%{event_id: nil}), do: []

  defp staff_event_nav(%{event_id: event_id, round_id: nil, current_path: current_path}) do
    course_path = ~p"/admin/events/#{event_id}/course-setup"

    [
      nav_item(
        "staff-nav-course-setup",
        "Course setup",
        course_path,
        current_path
      )
    ]
  end

  defp staff_event_nav(%{
         event_id: event_id,
         round_id: round_id,
         current_path: current_path
       }) do
    [
      nav_item(
        "staff-nav-course-setup",
        "Course setup",
        ~p"/admin/events/#{event_id}/course-setup",
        current_path
      ),
      nav_item(
        "staff-nav-round-setup",
        "Round setup",
        ~p"/admin/events/#{event_id}/rounds/#{round_id}/setup",
        current_path
      ),
      nav_item(
        "staff-nav-groups",
        "Groups",
        ~p"/admin/events/#{event_id}/rounds/#{round_id}/groups",
        current_path
      )
    ]
  end

  defp player_nav(current_path) do
    [
      %{
        id: "player-nav-home",
        label: "Home",
        href: ~p"/player",
        icon: "hero-home",
        current: current_path == ~p"/player",
        disabled: false
      },
      %{
        id: "player-nav-scoring",
        label: "Scoring",
        href: ~p"/player",
        icon: "hero-pencil-square",
        current: false,
        disabled: true
      },
      %{
        id: "player-nav-leaderboard",
        label: "Results",
        href: ~p"/player",
        icon: "hero-trophy",
        current: false,
        disabled: true
      }
    ]
  end

  defp nav_item(id, label, href, current_path, opts \\ []) do
    href_string = to_string(href)

    %{
      id: id,
      label: label,
      href: href,
      current: current_path == href_string,
      disabled: Keyword.get(opts, :disabled, false),
      hidden: Keyword.get(opts, :hidden, false)
    }
  end

  defp system_admin?(%StaffUser{system_admin: true, status: :active}), do: true
  defp system_admin?(_), do: false
end
