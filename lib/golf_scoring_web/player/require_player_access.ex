defmodule GolfScoringWeb.Player.RequirePlayerAccess do
  @moduledoc false

  import Phoenix.Controller, only: [redirect: 2]
  import Plug.Conn

  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoringWeb.Player.Session

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @player_denied_path "/player/access-denied"

  @impl Plug
  def call(conn, _opts) do
    case Session.grant_id(conn) do
      nil ->
        conn |> redirect(to: @player_denied_path) |> halt()

      grant_id ->
        case PlayerAccessGrantGuard.load_grant_for_session(grant_id) do
          {:ok, grant} ->
            conn
            |> assign(:current_player_access_grant, grant)
            |> assign(:current_player_id, grant.player_id)
            |> assign(:current_player_event_id, grant.event_id)

          {:error, :invalid_player_session} ->
            conn
            |> Session.clear()
            |> redirect(to: @player_denied_path)
            |> halt()
        end
    end
  end
end
