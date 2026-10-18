defmodule Ascella.Installer do
  @moduledoc """
  Installing, updating, starting and stopping one app, whichever way it
  ships on this system. The way is the catalogue's `method`; each has a
  module of its own (`Ascella.Installer.MacApp`, `.Velopack`,
  `.LinuxScript`, `.Portable`) and they all keep to the same order:

    1. download and verify (`Ascella.Fetch`) - before anything is stopped,
       so that a hall on a bad connection loses nothing but time;
    2. unpack and check what was unpacked, still beside the running copy;
    3. stop the app, politely, and wait until it has really stopped
       (`stop_gracefully/4`) - and when it does not, change nothing;
    4. put the new copy in place, keeping the previous one where the system
       allows it;
    5. start it again if it was running before.

  None of the steps touches a data directory; `Ascella.Fs` would refuse if
  one tried.
  """

  alias Ascella.{Catalogue, Context, Fetch, Runner}

  @type status :: %{
          state: :absent | :installed | :per_machine,
          version: String.t() | nil,
          previous: String.t() | nil,
          where: String.t() | nil
        }

  @callback installed(Catalogue.App.t(), map, Context.t()) :: status
  @callback running?(Catalogue.App.t(), map, Context.t()) :: boolean
  @callback install(Catalogue.App.t(), map, map, Context.t()) :: :ok | {:error, term}
  @callback start(Catalogue.App.t(), map, Context.t()) :: :ok | {:error, term}
  @callback stop(Catalogue.App.t(), map, Context.t()) :: :ok | {:error, term}
  @callback rollback(Catalogue.App.t(), map, Context.t()) :: :ok | {:error, term}
  @doc "Removes the program, the way the system removes it; never its data. The app is stopped already."
  @callback uninstall(Catalogue.App.t(), map, Context.t()) :: :ok | {:error, term}

  @modules %{
    mac_app: Ascella.Installer.MacApp,
    velopack: Ascella.Installer.Velopack,
    linux_script: Ascella.Installer.LinuxScript,
    portable: Ascella.Installer.Portable
  }

  @doc "`{module, spec}` for `app` on this context's target, or nil when there is no build for it."
  def for(app, %Context{target: target}) do
    case Catalogue.spec(app, target) do
      nil -> nil
      %{method: method} = spec -> {Map.fetch!(@modules, method), spec}
    end
  end

  @doc "What is installed: see `t:status/0`. An app without a build here is `:absent`."
  def installed(app, ctx) do
    case __MODULE__.for(app, ctx) do
      nil -> %{state: :absent, version: nil, previous: nil, where: nil}
      {mod, spec} -> mod.installed(app, spec, ctx)
    end
  end

  def running?(app, ctx) do
    case __MODULE__.for(app, ctx) do
      nil -> false
      {mod, spec} -> mod.running?(app, spec, ctx)
    end
  end

  @doc """
  Installs `release` (`%{version, tag}`), or updates to it. An app that is
  running is not touched: `{:error, {:running, name}}` at once, before
  anything is downloaded or swapped. Closing it is a person's decision (it
  may be mid-round), and the page offers the Stop button beside the message.
  Nothing is started again afterwards for the same reason: it was closed.
  """
  def install(app, release, ctx) do
    case __MODULE__.for(app, ctx) do
      nil ->
        {:error, :no_build}

      {mod, spec} ->
        with :ok <- closed(mod, app, spec, ctx), do: mod.install(app, spec, release, ctx)
    end
  end

  defp closed(mod, app, spec, ctx),
    do: if(mod.running?(app, spec, ctx), do: {:error, {:running, app.name}}, else: :ok)

  @doc """
  Removes `app`: stops it, takes the program away the platform's way, and
  removes the launchers Ascella made for it. Its data is kept, unless
  `delete_data: true` is passed (the page asks first, and defaults to no).
  """
  def uninstall(app, ctx, opts \\ []) do
    with_mod(app, ctx, fn mod, spec ->
      with :ok <- removable(mod.installed(app, spec, ctx)),
           :ok <- stop_gracefully(mod, app, spec, ctx),
           :ok <- mod.uninstall(app, spec, ctx) do
        launchers = Ascella.Launchers.remove_all(app, ctx)

        with :ok <- if(opts[:delete_data], do: delete_data(app, mod, ctx), else: :ok),
             do: launchers
      end
    end)
  end

  defp removable(%{state: :absent}), do: {:error, :absent}
  defp removable(%{state: :per_machine}), do: {:error, :per_machine_remove}
  defp removable(_installed), do: :ok

  # The one place that deletes data, and only the exact directories the
  # catalogue names for this app, and only when none of them contains or lies
  # in another app's data. Ascella.Fs would refuse all of it, which is why
  # this does not go through Ascella.Fs.
  defp delete_data(app, mod, ctx) do
    others = Enum.reject(Catalogue.apps(), &(&1.id == app.id))
    protected = [ctx.home, ctx.local_app_data, ctx.root, "/"] |> Enum.filter(&is_binary/1)

    Enum.reduce_while(Ascella.Guard.data_dirs(app, ctx), :ok, fn dir, :ok ->
      cond do
        Path.expand(dir) in Enum.map(protected, &Path.expand/1) ->
          {:halt, {:error, {:data_dir, app.id, dir}}}

        Ascella.Guard.check(dir, ctx, others) != :ok ->
          {:halt, Ascella.Guard.check(dir, ctx, others)}

        not File.exists?(dir) ->
          {:cont, :ok}

        mod == Ascella.Installer.LinuxScript ->
          case run(ctx, "rm", ["-rf", dir], as_root: true) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        true ->
          case File.rm_rf(dir) do
            {:ok, _} -> {:cont, :ok}
            {:error, reason, _file} -> {:halt, {:error, reason}}
          end
      end
    end)
  end

  def start(app, ctx), do: call(app, ctx, :start)
  def stop(app, ctx), do: with_mod(app, ctx, &stop_gracefully(&1, app, &2, ctx))

  @doc """
  Back to the previous version. Refused for an app whose catalogue entry says
  `"rollback": false` (its database moves forward on an update, and an older
  program over a newer database is how tournaments get damaged), and for one
  that is running.
  """
  def rollback(%{rollback: false}, _ctx), do: {:error, :no_rollback}

  def rollback(app, ctx) do
    with_mod(app, ctx, fn mod, spec ->
      with :ok <- closed(mod, app, spec, ctx), do: mod.rollback(app, spec, ctx)
    end)
  end

  defp call(app, ctx, fun), do: with_mod(app, ctx, &apply(&1, fun, [app, &2, ctx]))

  defp with_mod(app, ctx, fun) do
    case __MODULE__.for(app, ctx) do
      nil -> {:error, :no_build}
      {mod, spec} -> fun.(mod, spec)
    end
  end

  # --- shared steps -----------------------------------------------------------------

  @doc "Downloads and verifies the asset under `key` of `spec` for `release`."
  def fetch(app, spec, key, release, %Context{} = ctx) do
    name = Catalogue.asset(spec, key, release.version)
    dir = Path.join([ctx.downloads, app.id, release.version])
    Fetch.download(app.repo, release.tag, name, dir, ctx.github)
  end

  @doc """
  Stops the app the way it stops itself, and waits until it is gone. `:ok`
  when it was not running or has stopped; `{:error, :did_not_stop}` when it
  is still there after `ctx.stop_timeout_ms`. Nothing is ever killed: an
  app that will not stop is a person's decision, not Ascella's.
  """
  def stop_gracefully(mod, app, spec, %Context{} = ctx) do
    if mod.running?(app, spec, ctx) do
      with :ok <- mod.stop(app, spec, ctx) do
        if wait_until(fn -> not mod.running?(app, spec, ctx) end, ctx),
          do: :ok,
          else: {:error, :did_not_stop}
      end
    else
      :ok
    end
  end

  @doc "Polls `fun` until it is true or the context's stop timeout has passed."
  def wait_until(fun, %Context{stop_timeout_ms: timeout, poll_ms: poll}) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_until(fun, deadline, poll)
  end

  defp poll_until(fun, deadline, poll) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(poll)
        poll_until(fun, deadline, poll)
    end
  end

  @doc "Runs a program; `:ok` on exit status 0, else `{:error, {:exit, program, status, output}}`."
  def run(ctx, program, args, opts \\ []) do
    case Runner.run(ctx, program, args, opts) do
      {_output, 0} ->
        :ok

      {_output, 124} ->
        {:error, {:timeout, Path.basename(program)}}

      {output, status} ->
        {:error, {:exit, Path.basename(program), status, String.slice(output, -400, 400)}}
    end
  end

  @doc """
  Starts a Windows program outside Ascella's own process tree. Ascella's
  launcher holds everything it starts in a job object that dies with it -
  which is right for Ascella's own server, and wrong for OpenPairings in the
  middle of round five. So the program is created by WMI
  (`Win32_Process.Create`), whose process belongs to no job of ours, and
  Ascella closing takes nothing with it.
  """
  def start_detached(ctx, program, args \\ []) do
    command_line = Enum.map_join([program | args], " ", &~s("#{&1}"))
    literal = "'" <> String.replace(command_line, "'", "''") <> "'"

    script =
      "$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create " <>
        "-Arguments @{ CommandLine = #{literal} }; exit $r.ReturnValue"

    encoded = script |> :unicode.characters_to_binary(:utf8, {:utf16, :little}) |> Base.encode64()
    run(ctx, "powershell", ["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded])
  end

  @doc "Reads a VERSION file (one line, a version)."
  def read_version(path) do
    with {:ok, text} <- File.read(path),
         version = String.trim(text),
         {:ok, _} <- Version.parse(version) do
      version
    else
      _none -> nil
    end
  end
end
