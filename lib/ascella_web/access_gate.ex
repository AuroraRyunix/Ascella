defmodule AscellaWeb.AccessGate do
  @moduledoc """
  Turns away a browser that was not let in with the key (`Ascella.Access`):
  a plug for the pages and an `on_mount` for the LiveView, which is the part
  that does anything and can be reached without the pages.

  Does nothing at all where Ascella has no key (everywhere but the Linux
  service).
  """
  @behaviour Plug

  import Plug.Conn

  alias Ascella.Access

  @session_key "ascella_access"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      not Access.required?() ->
        conn

      Access.granted?(get_session(conn, @session_key)) ->
        conn

      true ->
        conn = fetch_query_params(conn)

        if Access.valid?(conn.query_params["k"]), do: let_in(conn), else: turn_away(conn)
    end
  end

  # The key has done its job: the cookie says so from now on, and the address
  # goes back to what it was without it.
  defp let_in(conn) do
    conn
    |> put_session(@session_key, Access.marker())
    |> put_resp_header("location", conn.request_path)
    |> send_resp(302, "")
    |> halt()
  end

  defp turn_away(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(
      403,
      "Ascella wants its key. Open it with: sh /opt/ascella/current/ascella.sh open\n" <>
        "(as the desktop user named by ASCELLA_RUN_AS, or with sudo).\n"
    )
    |> halt()
  end

  @doc "LiveView: the session must carry the marker."
  def on_mount(:default, _params, session, socket) do
    if not Access.required?() or Access.granted?(session[@session_key]),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
  end
end
