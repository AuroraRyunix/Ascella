defmodule AscellaWeb.HelpController do
  use AscellaWeb, :controller

  def show(conn, _params) do
    render(conn, :show, page_title: "Ascella · " <> gettext("Help"))
  end

  @doc "The favicon, drawn from the mark (`AscellaWeb.Logo.favicon/0`)."
  def favicon(conn, _params) do
    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=86400")
    |> send_resp(200, AscellaWeb.Logo.favicon())
  end
end
