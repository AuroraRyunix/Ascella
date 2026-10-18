defmodule Ascella.Installer.LinuxScript do
  @moduledoc """
  A Linux app that ships its own `install.sh` and `update.sh` and runs as a
  systemd service (Alnasl, and everything built like it). Ascella brings the
  verified archive; the app's own scripts do the rest, because they know
  things Ascella should not have to: its service user, its units, where it
  keeps its database and how to copy it aside before a new version opens it.

    * **Not installed** - the archive is downloaded, verified, unpacked into
      Ascella's downloads folder, and its `install.sh` run from there (it
      installs the release it stands in; it fetches nothing itself).
    * **Installed** (`/opt/<id>/update.sh` exists) - the same, and then the
      new release's own `update.sh --from <folder>`: it stops the service
      (systemd's SIGTERM, which the runtime takes as "shut down cleanly"),
      switches one symlink, starts it, and switches back when the new
      version does not answer.
    * **Back** - `update.sh --from` a copy of the previous release, which
      `update.sh` keeps in `/opt/<id>/releases`.

  The scripts are root's business: run through `sudo -n` when Ascella is not
  root, and refused, not asked about, when sudo would want a password.
  The data, `/var/lib/<id>`, is the scripts' promise never to touch, and
  Ascella's never to come near.
  """
  @behaviour Ascella.Installer

  alias Ascella.{Context, Fs, Installer, Runner}

  @impl true
  def installed(_app, spec, ctx) do
    dir = Context.linux_path(ctx, spec.install_dir)

    case Installer.read_version(Path.join([dir, "current", "VERSION"])) do
      nil ->
        %{state: :absent, version: nil, previous: nil, where: nil}

      version ->
        %{state: :installed, version: version, previous: previous(dir, version), where: dir}
    end
  end

  defp previous(dir, current) do
    dir
    |> Path.join("releases/*/VERSION")
    |> Path.wildcard()
    |> Enum.map(&Installer.read_version/1)
    |> Enum.reject(&(&1 in [nil, current]))
    |> Enum.max(Version, fn -> nil end)
  end

  @impl true
  def running?(_app, spec, ctx) do
    match?({_, 0}, Runner.run(ctx, "systemctl", ["is-active", "--quiet", spec.unit]))
  end

  @impl true
  def install(app, spec, release, ctx) do
    unpack = Path.join([ctx.downloads, app.id, release.version, "unpacked"])

    with {:ok, %{path: archive}} <- Installer.fetch(app, spec, :asset, release, ctx),
         :ok <- Fs.rm_rf(unpack, ctx),
         :ok <- Fs.mkdir_p(unpack, ctx),
         :ok <- Installer.run(ctx, "tar", ["-xzf", archive, "-C", unpack]),
         src = Path.join(unpack, spec.folder),
         :ok <- check_release(src, release.version) do
      put_in_place(spec, src, ctx)
    end
  end

  defp put_in_place(spec, src, ctx) do
    dir = Context.linux_path(ctx, spec.install_dir)

    if File.exists?(Path.join(dir, "update.sh")),
      do: Installer.run(ctx, "sh", [Path.join(src, "update.sh"), "--from", src], as_root: true),
      else: Installer.run(ctx, "sh", [Path.join(src, "install.sh")], as_root: true)
  end

  @impl true
  def rollback(app, spec, ctx) do
    dir = Context.linux_path(ctx, spec.install_dir)

    case installed(app, spec, ctx) do
      %{previous: nil} ->
        {:error, :no_previous}

      %{previous: version} ->
        # A copy first: update.sh clears releases/<version> before it copies
        # the source there, and the source must not be the thing it clears.
        copy = Path.join([ctx.downloads, app.id, version, "rollback", spec.folder])

        with :ok <- Fs.rm_rf(Path.dirname(copy), ctx),
             :ok <- Fs.mkdir_p(Path.dirname(copy), ctx),
             :ok <- Installer.run(ctx, "cp", ["-a", Path.join([dir, "releases", version]), copy]) do
          Installer.run(ctx, "sh", [Path.join(copy, "update.sh"), "--from", copy], as_root: true)
        end
    end
  end

  # The app's own uninstall.sh when it ships one (Alnasl's family does, and
  # leaves the data): it knows its units and its service user. Otherwise
  # install.sh's work in reverse - stop and disable the unit, remove the unit
  # file and the install folder, tell systemd. The data in /var/lib/<id> is
  # not part of "the program" and is left. Run as root (through sudo -n when
  # Ascella is not).
  @impl true
  def uninstall(_app, spec, ctx) do
    dir = Context.linux_path(ctx, spec.install_dir)
    own = Path.join(dir, "uninstall.sh")
    unit = Context.linux_path(ctx, "/etc/systemd/system/" <> spec.unit)

    with :ok <- Ascella.Guard.check(dir, ctx) do
      if File.exists?(own) do
        Installer.run(ctx, "sh", [own], as_root: true)
      else
        with :ok <-
               Installer.run(ctx, "systemctl", ["disable", "--now", spec.unit], as_root: true),
             :ok <- Installer.run(ctx, "rm", ["-f", unit], as_root: true),
             :ok <- Installer.run(ctx, "rm", ["-rf", dir], as_root: true) do
          Installer.run(ctx, "systemctl", ["daemon-reload"], as_root: true)
        end
      end
    end
  end

  @impl true
  def start(_app, spec, ctx),
    do: Installer.run(ctx, "systemctl", ["start", spec.unit], as_root: true)

  @impl true
  def stop(_app, spec, ctx),
    do: Installer.run(ctx, "systemctl", ["stop", spec.unit], as_root: true)

  defp check_release(src, version) do
    cond do
      not File.regular?(Path.join(src, "install.sh")) -> {:error, :no_install_script}
      not File.regular?(Path.join(src, "update.sh")) -> {:error, :no_update_script}
      Installer.read_version(Path.join(src, "VERSION")) != version -> {:error, :wrong_version}
      true -> :ok
    end
  end
end
