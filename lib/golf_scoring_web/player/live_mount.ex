defmodule GolfScoringWeb.Player.LiveMount do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias GolfScoring.Accounts.PlayerAccessGrantGuard
  alias GolfScoringWeb.Player.Session

  @player_denied_path "/player/access-denied"

  def on_mount(:require_grant, _params, session, socket) do
    case Session.grant_id_from_session(session) do
      nil ->
        deny(socket)

      grant_id ->
        case PlayerAccessGrantGuard.load_grant_for_session(grant_id) do
          {:ok, grant} ->
            {:cont,
             socket
             |> assign(:current_player_access_grant, grant)
             |> assign(:current_player_id, grant.player_id)
             |> assign(:current_player_event_id, grant.event_id)}

          {:error, :invalid_player_session} ->
            deny(socket)
        end
    end
  end

  defp deny(socket) do
    {:halt,
     socket
     |> put_flash(:error, "Your player access is no longer valid.")
     |> redirect(to: @player_denied_path)}
  end
end
