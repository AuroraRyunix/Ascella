import Config

# Runtime configuration: read when the application starts, in every
# environment, also inside a release.

if System.get_env("PHX_SERVER") do
  config :ascella, AscellaWeb.Endpoint, server: true
end

# Where Ascella keeps its own things. `Ascella.DataHome` says where an
# installed copy keeps them and why that is never a folder an installer owns.
data_dir =
  cond do
    data = System.get_env("ASCELLA_DATA") -> Path.expand(data)
    config_env() == :prod -> Path.expand(Ascella.DataHome.default())
    config_env() == :dev -> Path.expand("data")
    true -> nil
  end

# Loopback, always, and no switch to change it. This page installs and
# starts programs - on Linux as root - and a page that does that for anyone
# on the hall's network is a remote installer with a nice font. A box without
# a screen is reached with `ssh -L 4090:127.0.0.1:4090 box`.
if config_env() != :test do
  config :ascella, AscellaWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4090"))]
end

# The Linux service (root) wants a key of whoever uses its page: where the
# service unit says to write it. Everything else - Windows, macOS, a terminal -
# leaves this unset and the page answers without one. See Ascella.Access.
if token_file = System.get_env("ASCELLA_TOKEN_FILE") do
  config :ascella, access_token_file: token_file
end

# Another catalogue than the one in priv/ (a test hall, a fork). It is read
# as data and held to the same rules: GitHub repositories only.
if catalogue = System.get_env("ASCELLA_CATALOGUE") do
  config :ascella, catalogue_path: Path.expand(catalogue)
end

if data_dir do
  config :ascella, data_dir: data_dir
end

if config_env() == :dev do
  config :ascella, AscellaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/ascella_web/router\.ex$"E,
        ~r"lib/ascella_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  data = data_dir

  # Refused before anything is written there, for the same reason as in
  # every sister program: data inside a folder that an update replaces is
  # data with a date on it.
  if reason = Ascella.DataHome.refusal(data) do
    raise Ascella.DataHome.refusal_message(data, reason)
  end

  File.mkdir_p!(data)

  secret_file = Path.join(data, "secret_key_base")

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} when byte_size(secret) >= 64 ->
          String.trim(secret)

        _missing ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
          File.write!(secret_file, secret)
          File.chmod(secret_file, 0o600)
          secret
      end

  config :ascella, AscellaWeb.Endpoint,
    url: [host: "localhost"],
    secret_key_base: secret
end
