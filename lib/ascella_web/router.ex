defmodule AscellaWeb.Router do
  use AscellaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug AscellaWeb.LocalOnly
    plug :fetch_session
    plug AscellaWeb.Locale
    plug :fetch_live_flash
    plug :put_root_layout, html: {AscellaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # No accounts, no sign-in: the page answers this machine only (the
  # endpoint binds 127.0.0.1, and `AscellaWeb.LocalOnly` checks the name the
  # browser asked for), and whoever sits at this machine may already
  # install programs on it.
  scope "/", AscellaWeb do
    pipe_through :browser

    live_session :default, on_mount: [AscellaWeb.Locale] do
      live "/", HomeLive, :index
    end

    get "/help", HelpController, :show
    get "/remove-ascella", HelpController, :remove_self
  end

  scope "/", AscellaWeb do
    get "/favicon.svg", HelpController, :favicon
  end
end
