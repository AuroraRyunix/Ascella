defmodule Ascella.Installer.MacApp do
  @moduledoc """
  An unsigned, zipped `.app` on macOS - which is why Ascella exists.

  A browser marks what it downloads with `com.apple.quarantine`, and
  Gatekeeper then refuses an unsigned app with "can't be opened". A file
  written by a program that does not ask for quarantine (Ascella does not:
  no `LSFileQuarantineEnabled` in its Info.plist) carries no such mark, so
  an app Ascella downloads and unpacks itself opens like any other. Nothing
  is stripped and nothing is bypassed; the mark is simply never made.

  ## In place, with the previous copy kept

    1. the zip is downloaded and verified;
    2. it is unpacked with `ditto` (which keeps the bundle's modes and its
       ad-hoc signature) into `.ascella-staging-<id>` in the same folder as
       the app, so that the moves below are renames on one disk;
    3. the unpacked app is checked: a bundle, of the version asked for;
    4. the running app is stopped - SIGTERM to its launcher, which stops
       its server cleanly and asks nobody anything - and waited for;
    5. `Name.app` moves to `.ascella-previous/Name.app` (the one before that
       goes), and the new one moves to `Name.app`. Should the second rename
       fail, the first is undone.

  `rollback/3` swaps the two back. The data lives in
  `~/Library/Application Support`, which none of this comes near.
  """
  @behaviour Ascella.Installer

  alias Ascella.{Fs, Installer, Runner}

  @impl true
  def installed(_app, spec, ctx) do
    case location(spec, ctx) do
      nil ->
        %{state: :absent, version: nil, previous: nil, where: nil}

      dir ->
        %{
          state: :installed,
          version: bundle_version(Path.join(dir, spec.bundle)),
          previous: bundle_version(previous_path(dir, spec)),
          where: Path.join(dir, spec.bundle)
        }
    end
  end

  @impl true
  def running?(_app, spec, ctx), do: pids(spec, ctx) != []

  @impl true
  def install(app, spec, release, ctx) do
    with {:ok, %{path: zip}} <- Installer.fetch(app, spec, :asset, release, ctx),
         {:ok, dir} <- target_dir(spec, ctx),
         staging = Path.join(dir, ".ascella-staging-#{app.id}"),
         :ok <- Fs.rm_rf(staging, ctx),
         :ok <- Fs.mkdir_p(staging, ctx),
         :ok <- Installer.run(ctx, "ditto", ["-x", "-k", zip, staging]),
         fresh = Path.join(staging, spec.bundle),
         :ok <- check_bundle(fresh, release.version),
         :ok <- Installer.stop_gracefully(__MODULE__, app, spec, ctx),
         :ok <- swap_in(fresh, dir, spec, ctx) do
      Fs.rm_rf(staging, ctx)
    end
  end

  defp swap_in(fresh, dir, spec, ctx) do
    current = Path.join(dir, spec.bundle)
    previous = previous_path(dir, spec)

    with :ok <- keep_previous(current, previous, ctx) do
      case Fs.rename(fresh, current, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          if File.dir?(previous), do: Fs.rename(previous, current, ctx)
          {:error, {:swap, reason}}
      end
    end
  end

  defp keep_previous(current, previous, ctx) do
    if File.dir?(current) do
      with :ok <- Fs.rm_rf(previous, ctx), do: Fs.rename(current, previous, ctx)
    else
      :ok
    end
  end

  @impl true
  def rollback(app, spec, ctx) do
    with dir when is_binary(dir) <- location(spec, ctx) || {:error, :absent},
         previous = previous_path(dir, spec),
         true <- File.dir?(previous) || {:error, :no_previous},
         :ok <- Installer.stop_gracefully(__MODULE__, app, spec, ctx) do
      current = Path.join(dir, spec.bundle)
      aside = Path.join(dir, ".ascella-staging-#{app.id}")

      with :ok <- Fs.rm_rf(aside, ctx),
           :ok <- Fs.rename(current, aside, ctx),
           :ok <- Fs.rename(previous, current, ctx) do
        Fs.rename(aside, previous, ctx)
      end
    end
  end

  @impl true
  def start(_app, spec, ctx) do
    case location(spec, ctx) do
      nil -> {:error, :absent}
      dir -> Installer.run(ctx, "open", [Path.join(dir, spec.bundle)])
    end
  end

  @impl true
  def stop(_app, spec, ctx) do
    case pids(spec, ctx) do
      [] -> :ok
      pids -> Installer.run(ctx, "kill", ["-TERM" | pids])
    end
  end

  # --- where, and which -------------------------------------------------------------

  defp location(spec, ctx), do: Enum.find(ctx.mac_apps, &File.dir?(Path.join(&1, spec.bundle)))

  # Where it is, when it is anywhere; else the first folder this user may write.
  defp target_dir(spec, ctx) do
    case location(spec, ctx) || Enum.find(ctx.mac_apps, &writable?/1) do
      nil -> {:error, {:no_writable_folder, ctx.mac_apps}}
      dir -> {:ok, dir}
    end
  end

  defp writable?(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory, access: access}} -> access in [:read_write, :write]
      _missing -> false
    end
  end

  defp previous_path(dir, spec), do: Path.join([dir, ".ascella-previous", spec.bundle])

  # The launcher is the bundle's own program in Contents/MacOS. The server it
  # starts lives in Contents/Resources and is the launcher's business.
  defp pids(spec, ctx) do
    case location(spec, ctx) do
      nil ->
        []

      dir ->
        pattern = Path.join([dir, spec.bundle, "Contents", "MacOS"]) <> "/"

        case Runner.run(ctx, "pgrep", ["-f", pattern]) do
          {out, 0} -> out |> String.split() |> Enum.filter(&(&1 =~ ~r/\A\d+\z/))
          _none -> []
        end
    end
  end

  defp check_bundle(path, version) do
    case bundle_version(path) do
      nil -> {:error, {:not_a_bundle, Path.basename(path)}}
      ^version -> :ok
      other -> {:error, {:wrong_version, other, version}}
    end
  end

  @doc false
  # CFBundleShortVersionString out of an XML Info.plist, which is what the
  # apps' build_app.sh writes.
  def bundle_version(app_path) do
    with {:ok, plist} <- File.read(Path.join([app_path, "Contents", "Info.plist"])),
         [_, version] <-
           Regex.run(
             ~r/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/,
             plist
           ) do
      String.trim(version)
    else
      _none -> nil
    end
  end
end
