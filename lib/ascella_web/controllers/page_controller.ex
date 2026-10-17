defmodule AscellaWeb.PageController do
  use AscellaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
