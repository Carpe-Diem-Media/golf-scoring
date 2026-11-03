defmodule GolfScoringWeb.Player.Session do
  @moduledoc false

  @session_key "player_access_grant_id"

  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @spec grant_id(Plug.Conn.t()) :: Ecto.UUID.t() | nil
  def grant_id(conn), do: Plug.Conn.get_session(conn, @session_key)

  @spec grant_id_from_session(map()) :: Ecto.UUID.t() | nil
  def grant_id_from_session(session) when is_map(session) do
    Map.get(session, @session_key)
  end

  @spec put_grant_id(Plug.Conn.t(), Ecto.UUID.t()) :: Plug.Conn.t()
  def put_grant_id(conn, grant_id) do
    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.put_session(@session_key, grant_id)
  end

  @spec clear(Plug.Conn.t()) :: Plug.Conn.t()
  def clear(conn), do: Plug.Conn.delete_session(conn, @session_key)
end
