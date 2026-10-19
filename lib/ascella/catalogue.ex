defmodule Ascella.Catalogue do
  @moduledoc """
  The apps Ascella manages, read from data (`priv/catalogue.json`, or the
  file `ASCELLA_CATALOGUE` names), not written in code. Adding an app is
  adding an entry.

  ## An entry

      {
        "id": "polis",                    lower case; the key everywhere
        "name": "Polis",                  what people read
        "repo": "teapot-chess/Polis",     on GitHub, and only there
        "layout": "hall",                 optional: ships like Alnasl, see below
        "mark": "polis.svg",              a file in priv/marks
        "accent": ["#1f4f8a", "#8fb8ec"], the mark's accent, day and night
        "port": 4040,                     where its site answers (or null)
        "rollback": false,                optional, default true: false for an app
                                          whose database migrates forward on an
                                          update, so there is no way back
        "blurb": {"en": "...", "nl": "..."},
        "platforms": { "<target>": { "method": ..., ... } },
        "data": { "windows": [...], "macos": [...], "linux": [...] }
      }

  An app that publishes a Mac build for Intel too says so: a hall app adds
  `"macos_x86_64": true` (its `id-macos-x86_64.zip` is then expected), any
  other adds a `"macos-x86_64"` platform of its own. Without one, an Intel
  Mac is told there is no build for it yet; the Apple Silicon zip is never
  offered to it.

  `platforms` and `data` may be left out for a `"layout": "hall"` app; what
  is written out wins, per target and per system.

  ## Methods

    * `velopack` (Windows): `setup`, `package` (`{version}` is replaced),
      `pack_id`, `main_exe`, `window_class` (the launcher window that a
      polite stop is sent to)
    * `mac_app` (macOS): `asset` (a zip holding the bundle), `bundle`
    * `linux_script` (Linux): `asset` (a .tar.gz with one folder), `folder`,
      `install_dir`, `unit`. The app's own install.sh and update.sh do the
      work, and its own systemd unit runs it
    * `portable` (any): `asset` (a zip with one folder), `folder`, `start`
      (the script or program inside it that starts it)

  ## The hall layout

  What Alnasl's release workflow publishes, with `Name` and `id` filled in:
  `Name-Setup.exe`, `NameApp-{version}-full.nupkg` (pack id `NameApp`),
  `id-macos-aarch64.zip` (and `id-macos-x86_64.zip` with `"macos_x86_64": true`)
  holding `Name.app`, `id-linux-<arch>.tar.gz` holding
  `id/` with `install.sh`, installed in `/opt/id` as `id.service`. The data:
  `%LOCALAPPDATA%\\NameData`, `~/Library/Application Support/NameData`,
  `/var/lib/id`.

  ## Data directories

  Each app's data directories, per system, with `{home}` and
  `{localappdata}` for the obvious. Ascella never writes, moves or deletes
  anything in them, or anything that contains them (`Ascella.Guard`), and
  refuses to load a catalogue whose install folders would.
  """

  alias Ascella.Platform

  alias Ascella.Catalogue.App

  @methods %{
    "velopack" => {:velopack, ~w(setup package pack_id main_exe window_class)},
    "mac_app" => {:mac_app, ~w(asset bundle)},
    "linux_script" => {:linux_script, ~w(asset folder install_dir unit)},
    "portable" => {:portable, ~w(asset folder start)}
  }

  # Names that end up in a URL, a path or a command line. Narrow on purpose:
  # a catalogue is data, and data does not get to bring its own quotes.
  @name ~r/\A[A-Za-z0-9][A-Za-z0-9._{}+-]{0,127}\z/
  @id ~r/\A[a-z][a-z0-9_-]{0,31}\z/
  @repo ~r/\A[A-Za-z0-9][A-Za-z0-9-]{0,38}\/[A-Za-z0-9._-]{1,100}\z/
  @colour ~r/\A#[0-9a-fA-F]{6}\z/

  @doc "The catalogue Ascella runs with: every app, in order."
  def apps do
    case :persistent_term.get({__MODULE__, path()}, nil) do
      nil ->
        apps = load!(path())
        :persistent_term.put({__MODULE__, path()}, apps)
        apps

      apps ->
        apps
    end
  end

  @doc "One app by id, or nil."
  def get(id), do: Enum.find(apps(), &(&1.id == id))

  @doc "The file the catalogue is read from."
  def path do
    Application.get_env(:ascella, :catalogue_path) ||
      Application.app_dir(:ascella, "priv/catalogue.json")
  end

  @doc "Reads and checks a catalogue file. Raises with a sentence when it is wrong."
  def load!(path) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> parse!()
  end

  @doc "Checks decoded catalogue JSON and turns it into `%App{}`s."
  def parse!(%{"apps" => entries}) when is_list(entries) do
    apps = Enum.map(entries, &app!/1)
    ids = Enum.map(apps, & &1.id)

    if Enum.uniq(ids) != ids, do: fail!("two apps share an id: #{inspect(ids -- Enum.uniq(ids))}")

    apps
  end

  def parse!(_other), do: fail!("there is no \"apps\" list")

  @doc "The platform spec of `app` for `target`, or nil when it has no build there."
  def spec(%App{platforms: platforms}, target), do: Map.get(platforms, target)

  @doc "The release asset names of a spec, with `{version}` filled in."
  def asset(spec, key, version), do: String.replace(Map.fetch!(spec, key), "{version}", version)

  # --- one entry -----------------------------------------------------------------

  defp app!(%{} = entry) do
    id = string!(entry, "id", @id)
    name = string!(entry, "name", ~r/\A[A-Za-z][A-Za-z0-9 ]{0,31}\z/)
    repo = string!(entry, "repo", @repo)

    layout =
      case entry["layout"] do
        nil -> %{platforms: %{}, data: %{}}
        "hall" -> hall_layout(id, String.replace(name, " ", ""), intel_mac!(id, entry))
        other -> fail!("#{id}: unknown layout #{inspect(other)}")
      end

    platforms =
      layout.platforms
      |> Map.merge(entry["platforms"] || %{})
      |> Map.new(fn {target, spec} -> {target, platform!(id, target, spec)} end)

    data =
      layout.data
      |> Map.merge(entry["data"] || %{})
      |> Map.new(fn {family, dirs} -> {family!(id, family), dirs!(id, dirs)} end)

    app = %App{
      id: id,
      name: name,
      repo: repo,
      mark: mark!(id, entry["mark"]),
      accent: accent!(id, entry["accent"]),
      port: port!(id, entry["port"]),
      rollback: rollback!(id, Map.get(entry, "rollback", true)),
      blurb: Map.new(entry["blurb"] || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
      platforms: platforms,
      data: data
    }

    check_install_folders!(app)
    app
  end

  defp app!(other), do: fail!("an entry that is not an object: #{inspect(other)}")

  # `intel?` is the catalogue's `"macos_x86_64": true`: the app publishes
  # `id-macos-x86_64.zip` as well. Until it does, an Intel Mac is told so.
  defp hall_layout(id, name, intel?) do
    linux = fn arch ->
      %{
        "method" => "linux_script",
        "asset" => "#{id}-linux-#{arch}.tar.gz",
        "folder" => id,
        "install_dir" => "/opt/#{id}",
        "unit" => "#{id}.service"
      }
    end

    mac = fn arch ->
      %{"method" => "mac_app", "asset" => "#{id}-macos-#{arch}.zip", "bundle" => "#{name}.app"}
    end

    platforms = %{
      "windows-x86_64" => %{
        "method" => "velopack",
        "setup" => "#{name}-Setup.exe",
        "package" => "#{name}App-{version}-full.nupkg",
        "pack_id" => "#{name}App",
        "main_exe" => "#{name}.exe",
        "window_class" => "#{name}Launcher"
      },
      "macos-aarch64" => mac.("aarch64"),
      "linux-x86_64" => linux.("x86_64"),
      "linux-aarch64" => linux.("aarch64")
    }

    platforms = if intel?, do: Map.put(platforms, "macos-x86_64", mac.("x86_64")), else: platforms

    %{
      platforms: platforms,
      data: %{
        "windows" => ["{localappdata}/#{name}Data"],
        "macos" => ["{home}/Library/Application Support/#{name}Data"],
        "linux" => ["/var/lib/#{id}"]
      }
    }
  end

  defp platform!(id, target, %{"method" => method} = spec) do
    unless target in Platform.targets(), do: fail!("#{id}: unknown target #{inspect(target)}")

    {kind, keys} =
      Map.get(@methods, method) || fail!("#{id} #{target}: unknown method #{inspect(method)}")

    fields =
      Map.new(keys, fn key ->
        value = spec[key]

        cond do
          key == "install_dir" ->
            unless is_binary(value) and value =~ ~r/\A\/opt\/[a-z][a-z0-9_-]{0,31}\z/,
              do: fail!("#{id} #{target}: install_dir must be /opt/<name>, not #{inspect(value)}")

          is_binary(value) and value =~ @name and not String.contains?(value, "..") ->
            :ok

          true ->
            fail!("#{id} #{target}: #{key} is missing or not a plain name: #{inspect(value)}")
        end

        {String.to_atom(key), value}
      end)

    if kind == :mac_app and not String.ends_with?(fields.bundle, ".app"),
      do: fail!("#{id}: a bundle's name ends in .app")

    if kind == :linux_script and not String.ends_with?(fields.unit, ".service"),
      do: fail!("#{id}: a unit's name ends in .service")

    Map.put(fields, :method, kind)
  end

  defp platform!(id, target, _spec), do: fail!("#{id} #{target}: no method")

  defp intel_mac!(id, entry) do
    case Map.get(entry, "macos_x86_64", false) do
      flag when is_boolean(flag) -> flag
      _other -> fail!("#{id}: macos_x86_64 is true or false")
    end
  end

  defp family!(_id, family) when family in ~w(windows macos linux), do: String.to_atom(family)
  defp family!(id, family), do: fail!("#{id}: data for an unknown system #{inspect(family)}")

  defp dirs!(id, dirs) when is_list(dirs) do
    Enum.map(dirs, fn
      dir when is_binary(dir) and dir != "" ->
        if String.contains?(dir, ".."), do: fail!("#{id}: a data directory with '..' in it")
        dir

      other ->
        fail!("#{id}: a data directory that is not a path: #{inspect(other)}")
    end)
  end

  defp dirs!(id, _other), do: fail!("#{id}: data directories come as a list")

  defp mark!(id, mark) do
    unless is_binary(mark) and mark =~ ~r/\A[a-z0-9_-]+\.svg\z/,
      do: fail!("#{id}: the mark is a .svg file name in priv/marks")

    mark
  end

  defp accent!(_id, [day, night] = accent) when is_binary(day) and is_binary(night) do
    if day =~ @colour and night =~ @colour, do: accent, else: fail!("accents are #rrggbb")
  end

  defp accent!(_id, nil), do: ["#b3261e", "#f28b82"]
  defp accent!(id, _other), do: fail!("#{id}: accent is [day, night]")

  defp rollback!(_id, flag) when is_boolean(flag), do: flag
  defp rollback!(id, other), do: fail!("#{id}: rollback is true or false, not #{inspect(other)}")

  defp port!(_id, nil), do: nil
  defp port!(_id, port) when is_integer(port) and port in 1..65_535, do: port
  defp port!(id, other), do: fail!("#{id}: not a port: #{inspect(other)}")

  defp string!(entry, key, pattern) do
    case entry[key] do
      value when is_binary(value) ->
        if value =~ pattern, do: value, else: fail!("#{key} #{inspect(value)} is not allowed")

      other ->
        fail!("#{key} is missing (#{inspect(other)})")
    end
  end

  # The 2026-09-13 lesson, as a load-time rule: a Windows install folder is
  # %LOCALAPPDATA%\<pack id>, Velopack's uninstall deletes it whole, so a
  # pack id that names a data folder - this app's or any other's - is a
  # catalogue that has already decided to lose somebody's data.
  defp check_install_folders!(%App{id: id} = app) do
    data_names =
      app.data
      |> Map.get(:windows, [])
      |> Enum.map(&(&1 |> Path.basename() |> String.downcase()))

    for {_target, %{method: :velopack, pack_id: pack_id}} <- app.platforms,
        String.downcase(pack_id) in data_names do
      fail!(
        "#{id}: pack id #{pack_id} is the name of a data folder; its uninstall would delete it"
      )
    end

    :ok
  end

  defp fail!(message), do: raise(ArgumentError, "Ascella catalogue: " <> message)
end
