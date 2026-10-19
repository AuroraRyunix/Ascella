# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ascella,
  generators: [timestamp_type: :utc_datetime],
  # The real thing: GitHub over HTTPS, programs started and stopped for real.
  # The tests replace both (config/test.exs) and never reach either.
  runner: Ascella.Runner.System,
  github_req_options: []

# Configure the endpoint
config :ascella, AscellaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  # At a stop, the page left open in a browser gets three seconds to go,
  # not Bandit's fifteen: a self-update waits for this copy to be gone.
  http: [thousand_island_options: [shutdown_timeout: 3_000]],
  render_errors: [
    formats: [html: AscellaWeb.ErrorHTML, json: AscellaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ascella.PubSub,
  live_view: [signing_salt: "wuvYbIXU"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r",
  # Windows without developer mode cannot symlink, and this app has no
  # colocated assets that would need it.
  colocated_assets: [disable_symlink_warning: true]

config :ascella, AscellaWeb.Gettext, default_locale: "en", locales: ~w(en nl)

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ascella: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outbase=. --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
