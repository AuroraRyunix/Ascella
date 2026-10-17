import Config

# Loopback only (config/runtime.exs), plain HTTP, no host to pin.
config :ascella, AscellaWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Only pages served from this machine may open the live connection: a
  # page elsewhere that has its name point at 127.0.0.1 still says where it
  # came from, and is refused.
  check_origin: ["//localhost", "//127.0.0.1", "//[::1]"],
  server: true

config :logger, level: :info
