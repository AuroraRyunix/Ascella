defmodule Ascella.Installer.Velopack do
  @moduledoc """
  A Windows app that ships a Velopack installer: drive the app's own
  installer and its own updater, nothing home-made.

    * **Not installed** - the release's Setup.exe, verified, run with
      `--silent`. Never with `--installto`: Velopack's own default,
      `%LOCALAPPDATA%\\<pack id>`, is the folder the apps were built and
      checked against, and the one place their data is known not to be.
    * **Installed** (`%LOCALAPPDATA%\\<pack id>\\Update.exe` exists) - the
      release's full `.nupkg`, verified, kept in Ascella's own downloads
      folder (not in the app's), the app stopped, then
      `Update.exe apply --norestart --package <file>`, which is what the
      app's own "Install and restart" does underneath.
    * **Installed for everyone** (`Program Files\\<pack id>`, from the .msi)
      - left alone: updating it needs an administrator and the .msi, and
      Ascella says so instead.

  ## The data, which is the point

  The 2026-09-13 lesson: Velopack's uninstall deletes
  `%LOCALAPPDATA%\\<pack id>` whole, and an OpenPairings once packed under
  a pack id that was its data folder lost every tournament on the machine.
  The apps have since moved their data out (`OpenPairingsData`,
  `AlnaslData`) and their pack ids away from it (`OpenPairingsApp`,
  `AlnaslApp`). Ascella checks it again anyway, before every install and
  every update: the install folder must not be, contain or lie inside any
  app's data folder (`Ascella.Guard`), and must not have a database lying
  in it - the signature of an old install that still keeps its data where
  the uninstaller can reach it. Either finding stops everything, and the
  tile says why.

  ## Stopping

  The launcher window's own close, sent as `WM_CLOSE` with `wParam` 1 (the
  "no questions" close the apps' launchers use for their own updates), and
  then a wait until the program is gone. The launchers end their server the
  way they always do - SQLite in WAL mode, built to survive exactly that.
  Ascella never terminates a process.
  """
  @behaviour Ascella.Installer

  alias Ascella.{Fetch, Guard, Installer, Runner}

  @impl true
  def installed(_app, spec, ctx) do
    root = root(spec, ctx)
    machine = ctx.program_files && Path.join(ctx.program_files, spec.pack_id)

    cond do
      root && File.exists?(Path.join(root, "Update.exe")) ->
        %{state: :installed, version: version(root), previous: nil, where: root}

      machine && File.dir?(Path.join(machine, "current")) ->
        %{state: :per_machine, version: version(machine), previous: nil, where: machine}

      true ->
        %{state: :absent, version: nil, previous: nil, where: nil}
    end
  end

  @impl true
  def running?(_app, spec, ctx) do
    case Runner.run(ctx, "tasklist", ["/FI", "IMAGENAME eq #{spec.main_exe}", "/NH", "/FO", "CSV"]) do
      {out, 0} -> String.contains?(String.downcase(out), ~s("#{String.downcase(spec.main_exe)}"))
      _other -> false
    end
  end

  @impl true
  def install(app, spec, release, ctx) do
    with :ok <- safe_root(spec, ctx) do
      case installed(app, spec, ctx) do
        %{state: :absent} -> first_install(app, spec, release, ctx)
        %{state: :installed} -> update(app, spec, release, ctx)
        %{state: :per_machine} -> {:error, :per_machine}
      end
    end
  end

  defp first_install(app, spec, release, ctx) do
    with {:ok, %{path: setup, sha256: sum}} <- Installer.fetch(app, spec, :setup, release, ctx),
         true <- Fetch.still?(setup, sum) || {:error, :changed_after_download} do
      Installer.run(ctx, setup, ["--silent"])
    end
  end

  defp update(app, spec, release, ctx) do
    root = root(spec, ctx)

    with {:ok, %{path: package, sha256: sum}} <-
           Installer.fetch(app, spec, :package, release, ctx),
         :ok <- Installer.stop_gracefully(__MODULE__, app, spec, ctx),
         true <- Fetch.still?(package, sum) || {:error, :changed_after_download} do
      Installer.run(ctx, Path.join(root, "Update.exe"), [
        "apply",
        "--norestart",
        "--package",
        package
      ])
    end
  end

  @impl true
  def start(app, spec, ctx) do
    case installed(app, spec, ctx) do
      %{state: :installed, where: root} ->
        Installer.start_detached(ctx, Path.join(root, "Update.exe"), ["start"])

      %{state: :per_machine, where: dir} ->
        Installer.start_detached(ctx, Path.join([dir, "current", spec.main_exe]))

      %{state: :absent} ->
        {:error, :absent}
    end
  end

  # FindWindow on the launcher's class, PostMessage WM_CLOSE (0x0010) with
  # wParam 1. The class name went through the catalogue's name check, so
  # it cannot carry a quote into this script.
  @impl true
  def stop(_app, spec, ctx) do
    script = """
    $sig = '[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string c, string t);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);'
    $u = Add-Type -MemberDefinition $sig -Name AscellaUser32 -Namespace Ascella -PassThru
    $h = $u::FindWindowW('#{spec.window_class}', $null)
    if ($h -eq [IntPtr]::Zero) { exit 3 }
    [void]$u::PostMessageW($h, 0x0010, [IntPtr]1, [IntPtr]0)
    exit 0
    """

    case Installer.run(ctx, "powershell", ["-NoProfile", "-NonInteractive", "-Command", script]) do
      :ok -> :ok
      {:error, {:exit, _, 3, _}} -> {:error, :no_window}
      error -> error
    end
  end

  @impl true
  def rollback(_app, _spec, _ctx), do: {:error, :not_supported}

  # --- the install folder ---------------------------------------------------------------

  defp root(spec, ctx), do: ctx.local_app_data && Path.join(ctx.local_app_data, spec.pack_id)

  @doc false
  def safe_root(spec, ctx) do
    case root(spec, ctx) do
      nil ->
        {:error, :no_local_app_data}

      root ->
        with :ok <- Guard.check(root, ctx) do
          case Path.wildcard(Path.join(root, "*.db")) ++
                 Path.wildcard(Path.join(root, "secret_key_base")) do
            [] -> :ok
            [found | _] -> {:error, {:install_folder_holds_data, root, Path.basename(found)}}
          end
        end
    end
  end

  # Velopack writes current\sq.version (a nuspec) into every install; the
  # apps write VERSION into their release as well.
  defp version(root) do
    with {:ok, nuspec} <- File.read(Path.join([root, "current", "sq.version"])),
         [_, version] <- Regex.run(~r/<version>\s*([^<\s]+)\s*<\/version>/, nuspec) do
      version
    else
      _none -> Installer.read_version(Path.join([root, "current", "VERSION"]))
    end
  end
end
