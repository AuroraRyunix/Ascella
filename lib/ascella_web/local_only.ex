defmodule AscellaWeb.LocalOnly do
  @moduledoc """
  Answers a request only when the browser asked for this machine by a local
  name. The endpoint already listens on 127.0.0.1 alone; this is for the
  page elsewhere on the internet that points a name of its own at
  127.0.0.1 and then asks, from the visitor's browser, to install
  something. It gets a 403 and the rest of its day.
  """
  import Plug.Conn

  @default ~w(localhost 127.0.0.1 ::1 [::1])

  def init(opts), do: opts

  def call(conn, _opts) do
    hosts = Application.get_env(:ascella, :local_hosts, @default)

    if conn.host in hosts do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Ascella answers this machine only: open http://localhost:#{conn.port}\n")
      |> halt()
    end
  end
end
