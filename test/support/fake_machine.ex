defmodule Ascella.FakeMachine do
  @moduledoc """
  A computer for the installers to work on that is a temporary folder and
  an Agent. It answers the programs they run (through `Ascella.FakeRunner`)
  by doing, in the temporary folder, what the real program would have done:
  `ditto` unpacks, Setup.exe makes an install folder, `Update.exe apply`
  writes a new version, `update.sh` switches a release, `kill -TERM` stops
  something. Nothing on the real machine is run, installed or stopped.

  `stubborn: true` makes every polite stop ignored, for the tests about
  apps that will not stop.
  """

  alias Ascella.{Context, FakeRunner}

  @doc "A context whose every folder is under `tmp`, for `family`."
  def context(tmp, family) do
    target =
      case family do
        :windows -> "windows-x86_64"
        :macos -> "macos-aarch64"
        :linux -> "linux-x86_64"
      end

    home = Path.join(tmp, "home")

    %Context{
      target: target,
      family: family,
      runner: FakeRunner,
      downloads: Path.join(tmp, "ascella/downloads"),
      programs: Path.join(tmp, "ascella/programs"),
      home: home,
      homes: [home],
      local_app_data: Path.join(tmp, "LocalAppData"),
      program_files: Path.join(tmp, "ProgramFiles"),
      mac_apps: [Path.join(tmp, "Applications")],
      start_menu: Path.join(tmp, "StartMenu"),
      desktop: Path.join(tmp, "home/Desktop"),
      applications: Path.join(tmp, "home/.local/share/applications"),
      launchers: Path.join(tmp, "ascella/launchers"),
      gsettings: true,
      root: Path.join(tmp, "root"),
      sudo: true,
      run_as: nil,
      stop_timeout_ms: 300,
      poll_ms: 10,
      github: [plug: {Req.Test, Ascella.GitHub}]
    }
  end

  @doc "Starts the machine; `running` is a list of what runs at the start."
  def start(ctx, opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          running: MapSet.new(Keyword.get(opts, :running, [])),
          stubborn: Keyword.get(opts, :stubborn, false)
        }
      end)

    FakeRunner.script(fn program, args, opts ->
      handle(agent, ctx, Path.basename(program), program, args, opts)
    end)

    agent
  end

  def running?(agent, what), do: Agent.get(agent, &MapSet.member?(&1.running, what))

  defp up(agent, what), do: Agent.update(agent, &%{&1 | running: MapSet.put(&1.running, what)})

  defp down(agent, what) do
    Agent.get_and_update(agent, fn state ->
      if state.stubborn,
        do: {false, state},
        else: {true, %{state | running: MapSet.delete(state.running, what)}}
    end)
  end

  # A clean start: `env -i NAME=value... command args` runs the command.
  defp handle(agent, ctx, "env", _p, ["-i" | rest], opts) do
    [command | args] = Enum.drop_while(rest, &(&1 =~ ~r/\A[A-Z_]+=/))
    handle(agent, ctx, Path.basename(command), command, args, opts)
  end

  defp handle(_agent, _ctx, name, _p, _args, _opts) when name in ["defaults", "killall"],
    do: {"", 0}

  # --- macOS ------------------------------------------------------------------------

  defp handle(_agent, _ctx, "ditto", _p, ["-x", "-k", zip, dest], _opts) do
    {:ok, _} = :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(dest))
    {"", 0}
  end

  defp handle(agent, _ctx, "pgrep", _p, ["-f", pattern], _opts) do
    bundle = pattern |> Path.split() |> Enum.find(&String.ends_with?(&1, ".app"))
    if running?(agent, bundle), do: {"4242\n", 0}, else: {"", 1}
  end

  defp handle(agent, ctx, "kill", _p, ["-TERM" | _pids], _opts) do
    for what <- Agent.get(agent, & &1.running),
        do: if(ctx.family != :windows, do: down(agent, what))

    {"", 0}
  end

  defp handle(agent, _ctx, "kill", _p, ["-0", _pid], _opts) do
    if Agent.get(agent, &(MapSet.size(&1.running) > 0)), do: {"", 0}, else: {"", 1}
  end

  defp handle(_agent, _ctx, "osascript", _p, ["-e" | _] = args, _opts) do
    # The Trash: the bundle is gone from where it was.
    File.rm_rf!(List.last(args))
    {"", 0}
  end

  defp handle(agent, _ctx, "open", _p, [path], _opts) do
    up(agent, Path.basename(path))
    {"", 0}
  end

  # --- Windows ----------------------------------------------------------------------

  defp handle(agent, _ctx, "tasklist", _p, ["/FI", "IMAGENAME eq " <> exe | _], _opts) do
    if running?(agent, exe),
      do: {~s("#{exe}","4242","Console"\n), 0},
      else: {"INFO: No tasks.\n", 0}
  end

  defp handle(
         agent,
         _ctx,
         "powershell",
         _p,
         ["-NoProfile", "-NonInteractive", "-Command", script],
         opts
       ) do
    if script =~ "CreateShortcut" do
      File.write!(opts[:env] |> List.keyfind!("ASCELLA_LNK", 0) |> elem(1), "lnk")
      {"", 0}
    else
      [_, class] = Regex.run(~r/FindWindowW\('([A-Za-z0-9_]+)'/, script)
      exe = String.replace_suffix(class, "Launcher", ".exe")

      cond do
        not running?(agent, exe) -> {"", 3}
        true -> (down(agent, exe) && {"", 0}) || {"", 0}
      end
    end
  end

  defp handle(
         agent,
         _ctx,
         "powershell",
         _p,
         ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
         _opts
       ) do
    script =
      encoded |> Base.decode64!() |> :unicode.characters_to_binary({:utf16, :little}, :utf8)

    [_, line] = Regex.run(~r/CommandLine = '(.*)' \}/, script)
    [first | _] = Regex.run(~r/"([^"]+)"/, line, capture: :all_but_first)

    exe =
      if Path.basename(first) == "Update.exe",
        do: first |> Path.dirname() |> Path.basename() |> String.replace_suffix("App", ".exe"),
        else: Path.basename(first)

    up(agent, exe)
    {"", 0}
  end

  defp handle(_agent, ctx, name, program, ["--silent"], _opts) do
    [_, product, version] = Regex.run(~r/\A(.+?)-(?:([0-9.]+)-win-)?Setup\.exe\z/, name) |> pad()
    version = version || program |> Path.dirname() |> Path.basename()
    root = Path.join(ctx.local_app_data, product <> "App")
    File.mkdir_p!(Path.join(root, "current"))
    File.write!(Path.join(root, "Update.exe"), "fake")

    File.write!(
      Path.join([root, "current", "sq.version"]),
      "<package><metadata><version>#{version}</version></metadata></package>"
    )

    {"", 0}
  end

  defp handle(
         _agent,
         _ctx,
         "Update.exe",
         program,
         ["apply", "--norestart", "--package", package],
         _opts
       ) do
    [_, version] = Regex.run(~r/-([0-9.]+)-full\.nupkg\z/, package)

    File.write!(
      Path.join([Path.dirname(program), "current", "sq.version"]),
      "<version>#{version}</version>"
    )

    {"", 0}
  end

  defp handle(_agent, _ctx, "Update.exe", program, ["--silent", "uninstall"], _opts) do
    File.rm_rf!(Path.dirname(program))
    {"", 0}
  end

  defp handle(_agent, _ctx, "taskkill", _p, ["/IM", _exe], _opts), do: {"", 0}

  # --- Linux ------------------------------------------------------------------------

  defp handle(_agent, _ctx, "tar", _p, ["-xzf", archive, "-C", dest], _opts) do
    :ok =
      :erl_tar.extract(String.to_charlist(archive), [
        :compressed,
        {:cwd, String.to_charlist(dest)}
      ])

    {"", 0}
  end

  defp handle(_agent, _ctx, "unzip", _p, ["-q", zip, "-d", dest], _opts) do
    {:ok, _} = :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(dest))
    {"", 0}
  end

  defp handle(_agent, _ctx, "cp", _p, ["-a", from, to], _opts) do
    File.cp_r!(from, to)
    {"", 0}
  end

  # What install.sh and update.sh do, in the folder: the release copied into
  # releases/<version>, current pointing at it. `current` is a copy here, not
  # a symlink: Windows test machines and symlinks are not on speaking terms.
  defp handle(agent, ctx, "sudo", _p, ["-n", "sh", script | rest], _opts) do
    src = Path.dirname(script)
    id = Path.basename(src)
    version = src |> Path.join("VERSION") |> File.read!() |> String.trim()
    dir = Context.linux_path(ctx, "/opt/#{id}")

    case {Path.basename(script), rest} do
      {name, []} when name in ["install.sh"] -> :ok
      {"update.sh", ["--from", ^src]} -> :ok
    end

    was = running?(agent, id <> ".service")
    down(agent, id <> ".service")
    File.mkdir_p!(Path.join(dir, "releases"))
    File.rm_rf!(Path.join([dir, "releases", version]))
    File.cp_r!(src, Path.join([dir, "releases", version]))
    File.rm_rf!(Path.join(dir, "current"))
    File.cp_r!(src, Path.join(dir, "current"))
    File.cp!(Path.join(src, "update.sh"), Path.join(dir, "update.sh"))
    if was or Path.basename(script) == "install.sh", do: up(agent, id <> ".service")
    {"", 0}
  end

  defp handle(agent, _ctx, "systemctl", _p, ["is-active", "--quiet", unit], _opts) do
    if running?(agent, unit), do: {"", 0}, else: {"", 3}
  end

  defp handle(agent, _ctx, "sudo", _p, ["-n", "systemctl", "disable", "--now", unit], _opts) do
    down(agent, unit)
    {"", 0}
  end

  defp handle(_agent, _ctx, "sudo", _p, ["-n", "systemctl", "daemon-reload"], _opts), do: {"", 0}

  defp handle(_agent, _ctx, "sudo", _p, ["-n", "rm", flag, path], _opts)
       when flag in ["-f", "-rf"] do
    File.rm_rf!(path)
    {"", 0}
  end

  defp handle(agent, _ctx, "sudo", _p, ["-n", "systemctl", "stop", unit], _opts) do
    down(agent, unit)
    {"", 0}
  end

  defp handle(agent, _ctx, "sudo", _p, ["-n", "systemctl", "start", unit], _opts) do
    up(agent, unit)
    {"", 0}
  end

  defp handle(agent, _ctx, "sh", _p, ["-c", _launch, script, _log], _opts) do
    up(agent, Path.basename(script))
    {"4243\n", 0}
  end

  defp handle(_agent, _ctx, name, _program, args, _opts) do
    {"fake machine: no idea what #{name} #{Enum.join(args, " ")} does", 99}
  end

  defp pad([whole, a]), do: [whole, a, nil]
  defp pad(list), do: list
end
