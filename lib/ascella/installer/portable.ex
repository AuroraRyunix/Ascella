defmodule Ascella.Installer.Portable do
  @moduledoc """
  An app that ships as a zipped folder and nothing more - OpenPairings on
  Linux, which has no installer there. Ascella keeps such copies itself:

      <programs>/<id>/<version>/<folder>/...   one folder per version
      <programs>/<id>/current                  the version in use
      <programs>/<id>/previous                 the one before it, kept
      <programs>/<id>/pid                      what Ascella started: "<pid> <start time>"
      <programs>/<id>/logs/<id>.log            what it said (owned by the run-as user)

  An update unpacks the new version beside the old one, stops the app
  (SIGTERM, which the runtime takes as "shut down cleanly"; on Windows the
  polite `taskkill` without `/F`), and then changes one word in `current`.
  Versions other than these two are removed by name.

  The app's data is wherever the app keeps it (OpenPairings:
  `~/.local/share/OpenPairings`), never in here, and never touched.

  When Ascella runs as root (its Linux service does), an app is not started
  as root: `ASCELLA_RUN_AS` names the user it runs as, and without it Start
  says so instead of making root the owner of somebody's tournaments. Before
  each such start the way to the program is made walkable for that user
  (the data folder's "execute" bit; the folder is `0750 root` otherwise and
  the user could not reach the script it is told to run) and the folder of
  the log is handed to it. A start counts only when the program is still
  there a moment later (`start_check_ms`): a process that is already gone is
  a failed start, and the end of its log is the error.

  ## The pid file

  A pid is a number the system hands out again. The file holds the process's
  start time beside it (`/proc/<pid>/stat`, field 22, on Linux; `ps -o lstart`
  on macOS), and a pid whose start time is not the recorded one is somebody
  else's process: it is not "running", it is never sent a signal, and the
  file is deleted. A file from before this (a bare pid) is trusted once, as
  it always was. Windows finds the program by its executable name and keeps
  no pid.
  """
  @behaviour Ascella.Installer

  alias Ascella.{Fs, Installer, Runner}

  @impl true
  def installed(app, _spec, ctx) do
    base = base(app, ctx)

    case word(Path.join(base, "current")) do
      nil ->
        %{state: :absent, version: nil, previous: nil, where: nil}

      version ->
        %{
          state: :installed,
          version: version,
          previous: word(Path.join(base, "previous")),
          where: base
        }
    end
  end

  @impl true
  def running?(app, spec, %{family: :windows} = ctx) do
    exe = Path.basename(spec.start)
    String.ends_with?(exe, ".exe") and File.dir?(base(app, ctx)) and tasklist_has?(ctx, exe)
  end

  def running?(app, _spec, ctx) do
    case live_pid(app, ctx) do
      nil -> false
      pid -> match?({_, 0}, Runner.run(ctx, "kill", ["-0", pid]))
    end
  end

  defp tasklist_has?(ctx, exe) do
    {out, _} = Runner.run(ctx, "tasklist", ["/FI", "IMAGENAME eq #{exe}", "/NH"])
    String.contains?(String.downcase(out), String.downcase(exe))
  end

  @impl true
  def install(app, spec, release, ctx) do
    base = base(app, ctx)
    version = release.version
    staging = Path.join(base, version <> ".new")
    final = Path.join(base, version)

    with {:ok, %{path: zip}} <- Installer.fetch(app, spec, :asset, release, ctx),
         :ok <-
           if(word(Path.join(base, "current")) == version,
             do: {:error, :already_installed},
             else: :ok
           ),
         :ok <- Fs.rm_rf(staging, ctx),
         :ok <- unpack(zip, staging, ctx),
         true <-
           File.exists?(Path.join([staging, spec.folder, spec.start])) || {:error, :no_start},
         :ok <- Fs.rm_rf(final, ctx),
         :ok <- Fs.rename(staging, final, ctx),
         :ok <- Installer.stop_gracefully(__MODULE__, app, spec, ctx) do
      switch(base, version, ctx)
    end
  end

  # Erlang's unzip forgets the executable bit, which Windows never had and
  # Linux cannot do without.
  defp unpack(zip, dir, %{family: :windows} = ctx), do: Fs.unzip(zip, dir, ctx)

  defp unpack(zip, dir, ctx) do
    with :ok <- Fs.mkdir_p(dir, ctx), do: Installer.run(ctx, "unzip", ["-q", zip, "-d", dir])
  end

  defp switch(base, version, ctx) do
    old = word(Path.join(base, "current"))

    with :ok <- write_word(Path.join(base, "current"), version, ctx),
         :ok <- if(old, do: write_word(Path.join(base, "previous"), old, ctx), else: :ok) do
      keep = [version, old]

      base
      |> File.ls!()
      |> Enum.filter(&match?({:ok, _}, Version.parse(&1)))
      |> Enum.reject(&(&1 in keep))
      |> Enum.reduce_while(:ok, fn stale, :ok ->
        case Fs.rm_rf(Path.join(base, stale), ctx) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  @impl true
  def rollback(app, spec, ctx) do
    base = base(app, ctx)

    with %{version: current, previous: previous} when is_binary(previous) <-
           installed(app, spec, ctx),
         true <- File.dir?(Path.join(base, previous)) || {:error, :no_previous},
         :ok <- Installer.stop_gracefully(__MODULE__, app, spec, ctx),
         :ok <- write_word(Path.join(base, "current"), previous, ctx) do
      write_word(Path.join(base, "previous"), current, ctx)
    else
      %{} -> {:error, :no_previous}
      error -> error
    end
  end

  # Ascella made every file of it, in its own folder: that folder goes.
  @impl true
  def uninstall(app, _spec, ctx), do: Fs.rm_rf(base(app, ctx), ctx)

  @impl true
  def start(app, spec, %{family: :windows} = ctx) do
    with {:ok, path} <- start_path(app, spec, ctx), do: Installer.start_detached(ctx, path)
  end

  def start(app, spec, ctx) do
    with {:ok, path} <- start_path(app, spec, ctx),
         {:ok, prefix} <- as_user(ctx),
         :ok <- prepare_run_as(app, prefix, ctx) do
      log = Path.join([base(app, ctx), "logs", "#{app.id}.log"])
      {program, args} = launch(prefix, path, log)
      {program, args} = Ascella.CleanStart.command(:linux, program, args)

      case Runner.run(ctx, program, args, cd: Path.dirname(path)) do
        {out, 0} ->
          case Regex.run(~r/(\d+)\s*\z/, out) do
            [_, pid] -> settle(app, path, pid, String.trim_trailing(out, pid <> "\n"), log, ctx)
            nil -> {:error, :no_pid}
          end

        {out, status} ->
          {:error, {:exit, Path.basename(path), status, out}}
      end
    end
  end

  # Records the pid with its start time, and then looks once more: a program
  # that fell over in its first second (a script it was not allowed to read, a
  # port taken) leaves a pid that was true for a moment and a launch command
  # that exited 0 regardless.
  defp settle(app, path, pid, said, log, ctx) do
    stamp = start_stamp(pid, ctx)
    pid_file = Path.join(base(app, ctx), "pid")

    with :ok <- Fs.write(pid_file, pid_line(pid, stamp), ctx) do
      if ctx.start_check_ms > 0, do: Process.sleep(ctx.start_check_ms)

      if match?({_, 0}, Runner.run(ctx, "kill", ["-0", pid])) do
        :ok
      else
        Fs.rm_rf(pid_file, ctx)
        {:error, {:died, Path.basename(path), tail(log, said)}}
      end
    end
  end

  # The end of what the program wrote, or of what the launch itself said when
  # there is no log (the shell could not even open it).
  defp tail(log, said) do
    logged =
      case File.read(log) do
        {:ok, text} -> String.slice(text, -400, 400)
        _none -> ""
      end

    String.trim(logged <> " " <> said)
  end

  # Gives the run-as user what it needs to start the program: a way to walk to
  # it, and a folder for its log. Nothing to do when Ascella is not root.
  defp prepare_run_as(_app, [], _ctx), do: :ok

  defp prepare_run_as(app, ["runuser", "-u", user], ctx) do
    base = base(app, ctx)
    logs = Path.join(base, "logs")

    with :ok <- Fs.mkdir_p(logs, ctx),
         :ok <- Installer.run(ctx, "chown", ["--", user, logs]) do
      Installer.run(ctx, "chmod", ["o+x", Path.dirname(ctx.programs), ctx.programs, base])
    end
  end

  # `sh -c 'nohup "$0" > "$1" 2>&1 & echo $!' <script> <log>`: the script and
  # the log are arguments, not text inside the command.
  defp launch([], path, log), do: {"sh", ["-c", ~s(nohup "$0" > "$1" 2>&1 & echo $!), path, log]}

  defp launch([runuser | args], path, log),
    do: {runuser, args ++ ["--", "sh", "-c", ~s(nohup "$0" > "$1" 2>&1 & echo $!), path, log]}

  defp as_user(%{sudo: false, run_as: nil}), do: {:error, :needs_run_as}

  defp as_user(%{sudo: false, run_as: user}) when is_binary(user),
    do: {:ok, ["runuser", "-u", user]}

  defp as_user(_not_root), do: {:ok, []}

  @impl true
  def stop(_app, spec, %{family: :windows} = ctx),
    do: Installer.run(ctx, "taskkill", ["/IM", Path.basename(spec.start)])

  def stop(app, _spec, ctx) do
    case live_pid(app, ctx) do
      nil -> :ok
      pid -> Installer.run(ctx, "kill", ["-TERM", pid])
    end
  end

  defp start_path(app, spec, ctx) do
    case installed(app, spec, ctx) do
      %{version: nil} -> {:error, :absent}
      %{version: v} -> {:ok, Path.join([base(app, ctx), v, spec.folder, spec.start])}
    end
  end

  defp base(app, ctx), do: Path.join(ctx.programs, app.id)

  # The pid Ascella started, if that process is still the one it started: the
  # recorded start time has to be the process's own. A pid file that fails the
  # test is stale and is deleted.
  defp live_pid(app, ctx) do
    file = Path.join(base(app, ctx), "pid")

    with {:ok, text} <- File.read(file),
         [_, pid | rest] <- Regex.run(~r/\A(\d+)(?: (.+?))?\s*\z/s, text) do
      stamp = List.first(rest)

      cond do
        stamp in [nil, ""] ->
          pid

        start_stamp(pid, ctx) == stamp ->
          pid

        true ->
          Fs.rm_rf(file, ctx)
          nil
      end
    else
      _none -> nil
    end
  end

  defp pid_line(pid, nil), do: pid <> "\n"
  defp pid_line(pid, stamp), do: pid <> " " <> stamp <> "\n"

  # When the process started, as the system says it: a value that two
  # processes of the same pid will not share. nil when it cannot be read
  # (the process is gone, or the system does not say).
  @doc false
  def start_stamp(pid, %{family: :linux} = ctx) do
    with {:ok, stat} <- File.read(Path.join(ctx.root, "/proc/#{pid}/stat")),
         # The command name is in parentheses and may hold spaces and
         # parentheses of its own: the fields count from the last one. After
         # it come field 3 (the state) onwards, so field 22 is the 20th word.
         [_, after_name] <- Regex.run(~r/\)([^)]*)\z/s, stat),
         started when is_binary(started) <- Enum.at(String.split(after_name), 19) do
      started
    else
      _none -> nil
    end
  end

  def start_stamp(pid, %{family: :macos} = ctx) do
    case Runner.run(ctx, "ps", ["-o", "lstart=", "-p", pid]) do
      {out, 0} -> if String.trim(out) != "", do: String.trim(out)
      _none -> nil
    end
  end

  def start_stamp(_pid, _ctx), do: nil

  defp word(path) do
    with {:ok, text} <- File.read(path),
         word = String.trim(text),
         {:ok, _} <- Version.parse(word) do
      word
    else
      _none -> nil
    end
  end

  defp write_word(path, word, ctx) do
    with :ok <- Fs.write(path <> ".new", word <> "\n", ctx),
         do: Fs.rename(path <> ".new", path, ctx)
  end
end
