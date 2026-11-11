defmodule GolfScoringWeb.Router do
  use GolfScoringWeb, :router
  use AshAuthentication.Phoenix.Router

  import AshAuthentication.Plug.Helpers, only: [set_actor: 2]

  @browser_headers %{
    "content-security-policy" =>
      "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :load_from_session
    plug :set_actor, :staffuser
    plug :assign_current_staff_user
    plug :fetch_live_flash
    plug :put_root_layout, html: {GolfScoringWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, @browser_headers
  end

  pipeline :require_staff do
    plug GolfScoringWeb.Admin.RequireStaff
  end

  pipeline :require_player_access do
    plug GolfScoringWeb.Player.RequirePlayerAccess
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  def assign_current_staff_user(conn, _opts) do
    assign(conn, :current_staff_user, conn.assigns[:current_staffuser])
  end

  scope "/", GolfScoringWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/player", GolfScoringWeb.Player do
    pipe_through :browser

    get "/access", AccessController, :exchange
    live "/access-denied", AccessDeniedLive, :show
  end

  scope "/player", GolfScoringWeb.Player do
    pipe_through [:browser, :require_player_access]

    live_session :player,
      on_mount: [{GolfScoringWeb.Player.LiveMount, :require_grant}] do
      live "/", HomeLive, :index
    end
  end

  scope "/player", alias: false do
    pipe_through [:browser, :require_player_access]

    live_session :player_scorecard,
      on_mount: [{GolfScoringWeb.Player.LiveMount, :require_grant}] do
      live "/events/:event_id/rounds/:round_id/groups/:group_id/scorecard",
           GolfScoringWeb.Scoring.GroupScorecardLive,
           :show

      live "/events/:event_id/rounds/:round_id/groups/:group_id/verify",
           GolfScoringWeb.Scoring.VerificationLive,
           :show
    end
  end

  scope "/admin" do
    pipe_through :browser

    sign_in_route(
      path: "/sign-in",
      auth_routes_prefix: {:unscoped, "/admin/auth"},
      resources: [GolfScoring.Accounts.StaffUser]
    )

    sign_out_route(GolfScoringWeb.Admin.SessionController, "/sign-out")

    auth_routes(
      GolfScoringWeb.Admin.SessionController,
      GolfScoring.Accounts.StaffUser,
      path: "/auth"
    )
  end

  scope "/admin" do
    pipe_through [:browser, :require_staff]

    ash_authentication_live_session :admin_staff do
      live "/", GolfScoringWeb.Admin.DashboardLive, :index
      live "/events/:event_id/course-setup", GolfScoringWeb.Admin.CourseSetupLive, :index
      live "/events/:event_id/rounds/:round_id/setup", GolfScoringWeb.Admin.RoundSetupLive, :index

      live "/events/:event_id/rounds/:round_id/score-queries",
           GolfScoringWeb.Admin.ScoreQueriesLive,
           :index

      live "/events/:event_id/rounds/:round_id/groups",
           GolfScoringWeb.Admin.GroupAssignmentLive,
           :index
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", GolfScoringWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:golf_scoring, :dev_routes) do
    @dev_dashboard_headers %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; object-src 'none'; base-uri 'self'; frame-ancestors 'none'; form-action 'self'"
    }

    pipeline :dev_dashboard do
      plug :put_secure_browser_headers, @dev_dashboard_headers
    end

    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser, :dev_dashboard]

      live_dashboard "/dashboard", metrics: GolfScoringWeb.Telemetry
    end
  end
end
