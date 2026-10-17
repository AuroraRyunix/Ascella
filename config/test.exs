import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ascella, AscellaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "0OQyUZ72ir6JYFazsqMZ0g5I83FrsLXYMcTYQRh7mzBH0a7WhqmwgbCbnNEkd6nb",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Nothing real, ever. The runner is a fake that runs nothing (tests that
# need it to do something hand it a script), GitHub is a Req.Test stub, the
# data lives in tmp/, and Ascella.Apps neither looks nor asks unless told.
config :ascella,
  runner: Ascella.FakeRunner,
  github_req_options: [plug: {Req.Test, Ascella.GitHub}],
  data_dir: Path.expand("../tmp/test-data", __DIR__),
  apps_auto: false,
  launcher_details: false,
  install_kind: :manual,
  local_hosts: ~w(localhost 127.0.0.1 www.example.com),
  # A catalogue of made-up apps: the tests never name a real one.
  catalogue_path: Path.expand("../test/fixtures/catalogue.json", __DIR__)
