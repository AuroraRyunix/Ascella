defmodule Ascella.SelfUpdate.Mac do
  @moduledoc """
  Ascella replacing its own `Ascella.app`, which is the one thing the Mac
  version could not do for itself until now.

  What `apply/3` does, in this order, and why in this order:

    1. **Can it be done here at all?** The folder the app sits in must be
       writable. An app opened straight from Downloads runs from a read-only
       "translocated" copy, and one dragged into a folder an ordinary user
       may not write to cannot be replaced either. Then nothing is
       downloaded, and the message says where Ascella is and how to move it
       to /Applications.
    2. The release zip is downloaded and checked against the release's
       `SHA256SUMS` (`Ascella.Fetch`, the same as for every other program).
    3. It is unpacked with `ditto` into a folder *beside* the running app, so
       that the swap below is two renames on one volume, atomic each.
    4. The unpacked app is checked: a bundle, of the version asked for, and
       without `com.apple.quarantine`. Ascella's own downloads carry none (its
       `Info.plist` does not ask for it); if the mark is there anyway, it is
       removed, because an unsigned app with it does not start.
    5. `Ascella.app` is renamed to `.ascella-previous/Ascella.app` (the copy
       before that goes: exactly one is kept) and the new app is renamed to
       `Ascella.app`.
    6. A detached helper is started - `/bin/sh -c SCRIPT sh ARGS...`, the
       arguments a list and nothing interpolated, in a clean environment
       (`Ascella.CleanStart`, because Ascella's own `PORT` once broke another
       app). It waits for this app to be gone, opens the new one, and asks
       its port for an answer. No answer, and it puts the previous app back
       and opens that instead.
    7. This app is asked to quit, the way Quit does it: SIGTERM to its
       launcher, which stops the server cleanly.

  Ascella's data (`~/Library/Application Support/AscellaData`) is nowhere in
  this. `Ascella.Fs` would refuse if it were.

  The helper's script is below as `helper_script/0`; the file-level tests run
  it for real against fake bundles in a temporary folder, with stand-ins for
  `open`, `curl` and `pgrep`.
  """

  alias Ascella.{CleanStart, Fetch, Fs, Installer, Runner, Updates}
  alias Ascella.Installer.MacApp

  @asset "ascella-macos-aarch64.zip"
  @bundle_name "Ascella.app"

  # $1 launcher pid  $2 bundle  $3 previous  $4 port  $5 status file
  # $6 open  $7 curl  $8 pgrep  $9 seconds to wait for an answer
  # $10 version  $11 tick (seconds, 1 in real life)
  @helper ~S"""
  launcher=$1; bundle=$2; previous=$3; port=$4; status=$5
  open=$6; curl=$7; pgrep=$8; secs=$9; version=${10}; tick=${11}

  say() { printf '%s\n' "$1" >"$status" 2>/dev/null; }

  (
    trap '' HUP

    # The old Ascella has to be gone before the new one can bind the port.
    i=0
    while kill -0 "$launcher" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 120 ]; then say "stuck $version"; exit 1; fi
      sleep "$tick"
    done

    "$open" "$bundle"

    i=0
    while [ "$i" -lt "$secs" ]; do
      if "$curl" -fsS --max-time 2 -o /dev/null "http://127.0.0.1:$port/help" 2>/dev/null; then
        say "ok $version"
        exit 0
      fi
      i=$((i + 1))
      sleep "$tick"
    done

    # The new Ascella did not answer: stop what is left of it, put the
    # previous one back, open that.
    for p in $("$pgrep" -f "$bundle/Contents/MacOS/" 2>/dev/null); do
      kill -TERM "$p" 2>/dev/null
    done
    i=0
    while [ -n "$("$pgrep" -f "$bundle/Contents/MacOS/" 2>/dev/null)" ] && [ "$i" -lt 30 ]; do
      i=$((i + 1))
      sleep "$tick"
    done

    failed="$bundle.failed"
    rm -rf "$failed"
    if mv "$bundle" "$failed" && mv "$previous" "$bundle"; then
      rm -rf "$failed"
      "$open" "$bundle"
      say "rolled-back $version"
    else
      say "failed $version"
      exit 1
    fi
  ) </dev/null >/dev/null 2>&1 &
  """

  @doc "The helper's script, as run by `/bin/sh -c`."
  def helper_script, do: @helper

  @doc "The release asset this replaces the app with."
  def asset, do: @asset

  @doc "Where the running `Ascella.app` is, or nil when this copy is not inside one."
  def bundle_path do
    case Application.get_env(:ascella, :self_bundle) do
      nil -> System.get_env("RELEASE_ROOT") |> bundle_from()
      path -> path
    end
  end

  @doc "The `.app` a path lies in (the innermost, if there are several), or nil."
  def bundle_from(nil), do: nil

  def bundle_from(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.find_index(Enum.reverse(parts), &String.ends_with?(&1, ".app")) do
      nil -> nil
      back -> parts |> Enum.take(length(parts) - back) |> Path.join()
    end
  end

  @doc "Where the previous copy is kept: one, in a folder of its own beside the app."
  def previous_path(bundle),
    do: Path.join([Path.dirname(bundle), ".ascella-previous", Path.basename(bundle)])

  @doc """
  Whether the app can be replaced where it is: the folder is writable, and is
  not one of the read-only copies macOS runs a downloaded app from.
  """
  def writable?(bundle) do
    dir = Path.dirname(bundle)

    not String.contains?(bundle, "/AppTranslocation/") and
      match?(
        {:ok, %File.Stat{type: :directory, access: access}} when access in [:read_write, :write],
        File.stat(dir)
      )
  end

  @doc """
  Replaces the running app with `release` (`%{version, tag}`), starts the
  helper, and asks this app to quit. `:ok` means the helper is running and
  the quit was asked for. Anything else leaves the app as it was.

  `opts` exists for the tests: `:bundle`, `:launcher_pid`, `:port`,
  `:status_file`, `:open`, `:curl`, `:pgrep`, `:seconds`, `:tick`.
  """
  def apply(%{version: version, tag: tag}, ctx, opts \\ []) do
    bundle = Keyword.get_lazy(opts, :bundle, &bundle_path/0)

    with true <- is_binary(bundle) || {:error, :not_a_bundle},
         true <- writable?(bundle) || {:error, {:not_writable, bundle}},
         {:ok, launcher} <- launcher_pid(bundle, ctx, opts),
         {:ok, %{path: zip}} <-
           Fetch.download(
             Updates.repo(),
             tag,
             @asset,
             Path.join([ctx.downloads, "ascella", version]),
             ctx.github
           ),
         staging = Path.join(Path.dirname(bundle), ".ascella-staging-ascella"),
         :ok <- Fs.rm_rf(staging, ctx),
         :ok <- Fs.mkdir_p(staging, ctx),
         :ok <- Installer.run(ctx, "ditto", ["-x", "-k", zip, staging]),
         fresh = Path.join(staging, @bundle_name),
         :ok <- check_bundle(fresh, version),
         :ok <- same_volume(fresh, bundle),
         :ok <- strip_quarantine(fresh, ctx),
         previous = previous_path(bundle),
         :ok <- swap(fresh, bundle, previous, ctx),
         :ok <- start_helper(launcher, bundle, previous, version, ctx, opts) do
      _ = Fs.rm_rf(staging, ctx)
      quit(launcher, ctx)
    end
  end

  # The launcher of this copy: what Quit would signal. Asked of the
  # environment first (launcher.sh exports it), then of `pgrep`, and before
  # the swap, while the old path still names this copy.
  defp launcher_pid(bundle, ctx, opts) do
    case opts[:launcher_pid] || System.get_env("ASCELLA_LAUNCHER_PID") do
      pid when is_binary(pid) and pid != "" ->
        if pid =~ ~r/\A\d+\z/, do: {:ok, [pid]}, else: {:error, :launcher_not_found}

      _unset ->
        case Runner.run(ctx, "pgrep", ["-f", Path.join([bundle, "Contents", "MacOS"]) <> "/"]) do
          {out, 0} ->
            case out |> String.split() |> Enum.filter(&(&1 =~ ~r/\A\d+\z/)) do
              [] -> {:error, :launcher_not_found}
              pids -> {:ok, pids}
            end

          _none ->
            {:error, :launcher_not_found}
        end
    end
  end

  defp check_bundle(path, version) do
    case MacApp.bundle_version(path) do
      nil -> {:error, {:not_a_bundle, Path.basename(path)}}
      ^version -> :ok
      other -> {:error, {:wrong_version, other, version}}
    end
  end

  # The swap is only a pair of renames when both ends are on one disk.
  # Unpacked in the app's own folder it always is; this says so out loud.
  defp same_volume(fresh, bundle) do
    with {:ok, a} <- File.stat(fresh),
         {:ok, b} <- File.stat(Path.dirname(bundle)) do
      if {a.major_device, a.minor_device} == {b.major_device, b.minor_device},
        do: :ok,
        else: {:error, :other_volume}
    end
  end

  # `xattr -p` finds the mark (exit 0) or not. Ascella's own downloads have
  # none; if it is there, it goes, or the new app would meet Gatekeeper.
  defp strip_quarantine(path, ctx) do
    case Runner.run(ctx, "xattr", ["-p", "com.apple.quarantine", path]) do
      {_out, 0} -> Installer.run(ctx, "xattr", ["-dr", "com.apple.quarantine", path])
      _absent -> :ok
    end
  end

  @doc """
  `bundle` to `previous` (the one that was there goes), `fresh` to `bundle`.
  If the second rename fails the first is undone, so the app is either the
  old one or the new one and never neither.
  """
  def swap(fresh, bundle, previous, ctx) do
    with :ok <- Fs.rm_rf(previous, ctx),
         :ok <- Fs.rename(bundle, previous, ctx) do
      case Fs.rename(fresh, bundle, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = Fs.rename(previous, bundle, ctx)
          {:error, {:swap, reason}}
      end
    end
  end

  defp start_helper([launcher | _], bundle, previous, version, ctx, opts) do
    args = [
      launcher,
      bundle,
      previous,
      to_string(opts[:port] || System.get_env("PORT") || "4090"),
      opts[:status_file] || Updates.status_file(),
      opts[:open] || "/usr/bin/open",
      opts[:curl] || "/usr/bin/curl",
      opts[:pgrep] || "/usr/bin/pgrep",
      to_string(opts[:seconds] || 45),
      version,
      to_string(opts[:tick] || 1)
    ]

    {program, words} = CleanStart.command(:macos, "/bin/sh", ["-c", @helper, "sh" | args])

    case Installer.run(ctx, program, words) do
      :ok ->
        :ok

      error ->
        # No helper, nobody to open the new app: back to the old one.
        _ = Fs.rename(bundle, Path.join(Path.dirname(bundle), ".ascella-failed-start"), ctx)
        _ = Fs.rename(previous, bundle, ctx)
        _ = Fs.rm_rf(Path.join(Path.dirname(bundle), ".ascella-failed-start"), ctx)
        error
    end
  end

  defp quit(pids, ctx), do: Installer.run(ctx, "kill", ["-TERM" | pids])
end
