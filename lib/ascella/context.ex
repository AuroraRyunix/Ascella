defmodule Ascella.Context do
  @moduledoc """
  Everything an installer needs to know about the machine, in one struct,
  so that the tests can hand it a different machine: a temporary folder
  for a home, a fake runner for the programs, a fake GitHub for the
  downloads. Nothing in `Ascella.Installer.*` asks the real machine
  anything except through this.

    * `target`, `family` - see `Ascella.Platform`
    * `runner` - the module that runs programs (`Ascella.Runner`)
    * `downloads`, `programs` - Ascella's own folders
    * `mac_apps` - where `.app` bundles go, in order of preference
    * `program_files` - where a per-machine .msi install would be
    * `home`, `homes`, `local_app_data` - for the catalogue's `{home}` and
      `{localappdata}`; `homes` is every home whose data is protected
    * `root` - prefixed to the absolute Linux paths (`/opt`, `/var/lib`,
      `/etc/systemd`): `""` for real, a temporary folder in a test
    * `sudo` - run Linux installers through `sudo -n` (Ascella is not root)
    * `run_as` - on Linux, the user a portable app is started as when
      Ascella itself runs as root
    * `stop_timeout_ms`, `poll_ms` - how long a polite stop is waited for
  """

  alias Ascella.{Paths, Platform}

  defstruct [
    :target,
    :family,
    :runner,
    :downloads,
    :programs,
    :home,
    :local_app_data,
    :program_files,
    :run_as,
    mac_apps: [],
    homes: [],
    root: "",
    sudo: false,
    stop_timeout_ms: 60_000,
    poll_ms: 500,
    github: []
  ]

  @doc "The context of the machine this runs on."
  def current do
    case Application.get_env(:ascella, :context) do
      %__MODULE__{} = ctx -> ctx
      nil -> build()
    end
  end

  defp build do
    family = Platform.family()
    home = System.user_home() || ""
    run_as = System.get_env("ASCELLA_RUN_AS")

    %__MODULE__{
      target: Platform.target(),
      family: family,
      runner: Application.get_env(:ascella, :runner, Ascella.Runner.System),
      downloads: Paths.downloads(),
      programs: Paths.programs(),
      home: home,
      homes: Enum.uniq([home | run_as_home(run_as)]),
      local_app_data: System.get_env("LOCALAPPDATA"),
      program_files: System.get_env("ProgramFiles"),
      run_as: run_as,
      mac_apps: mac_apps(home),
      sudo: family == :linux and not root?(),
      github: Application.get_env(:ascella, :github_req_options, [])
    }
  end

  # /Applications first, where people look; ~/Applications when that is not
  # writable for this user. ASCELLA_APPS_DIR overrides both.
  defp mac_apps(home) do
    case System.get_env("ASCELLA_APPS_DIR") do
      dir when dir not in [nil, ""] -> [Path.expand(dir)]
      _unset -> ["/Applications", Path.join(home, "Applications")]
    end
  end

  defp root? do
    case System.cmd("id", ["-u"], stderr_to_stdout: true) do
      {"0\n", 0} -> true
      _other -> false
    end
  rescue
    _no_id -> false
  end

  defp run_as_home(nil), do: []

  defp run_as_home(user) do
    if user =~ ~r/\A[a-z_][a-z0-9_-]{0,31}\z/ do
      case System.cmd("getent", ["passwd", user], stderr_to_stdout: true) do
        {line, 0} ->
          [line |> String.trim() |> String.split(":") |> Enum.at(5)] |> Enum.reject(&is_nil/1)

        _none ->
          []
      end
    else
      []
    end
  rescue
    _no_getent -> []
  end

  @doc "An absolute Linux path, under the context's root."
  def linux_path(%__MODULE__{root: root}, "/" <> _ = path), do: root <> path
end
