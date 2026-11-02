defmodule GolfScoringWeb.Player.AccessController do
  @moduledoc false

  use GolfScoringWeb, :controller

  alias GolfScoring.Accounts.PlayerAccessExchange
  alias GolfScoringWeb.Player.Session

  def exchange(conn, %{"token" => token}) when is_binary(token) do
    case PlayerAccessExchange.exchange(token) do
      {:ok, grant} ->
        conn
        |> Session.put_grant_id(grant.id)
        |> redirect(to: ~p"/player")

      {:error, :invalid_credentials} ->
        conn
        |> put_status(:unauthorized)
        |> text("Authentication failed")
        |> halt()
    end
  end

  def exchange(conn, _params) do
    conn
    |> put_status(:unauthorized)
    |> text("Authentication failed")
    |> halt()
  end
end
