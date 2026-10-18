defmodule Ascella.Installer.Portable do
  @moduledoc """
  An app that ships as a zipped folder and nothing more - OpenPairings on
  Linux, which has no installer there. Ascella keeps such copies itself:

      <programs>/<id>/<version>/<folder>/...   one folder per version
      <programs>/<id>/current                  the version in use
      <programs>/<id>/previous                 the one before it, kept
      <programs>/<id>/pid                      what Ascella started (Linux)

  An update unpacks the new version beside the old one, stops the app
  (SIGTERM, which the runtime takes as "shut down cleanly"; on Windows the
  polite `taskkill` without `/F`), and then changes one word in `current`.
  Versions other than these two are removed by name.

  The app's data is wherever the app keeps it (OpenPairings:
  `~/.local/share/OpenPairings`), never in here, and never touched.

  When Ascella runs as root (its Linux service does), an app is not started
  as root: `ASCELLA_RUN_AS` names the user it runs as, and without it Start
  says so instead of making root the owner of somebody's tournaments.
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
    case pid(app, ctx) do
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
         {:ok, prefix} <- as_user(ctx) do
      log = Path.join(base(app, ctx), "#{app.id}.log")
      {program, args} = launch(prefix, path, log)
      {program, args} = Ascella.CleanStart.command(:linux, program, args)

      case Runner.run(ctx, program, args, cd: Path.dirname(path)) do
        {out, 0} ->
          case Regex.run(~r/(\d+)\s*\z/, out) do
            [_, pid] -> Fs.write(Path.join(base(app, ctx), "pid"), pid, ctx)
            nil -> {:error, :no_pid}
          end

        {out, status} ->
          {:error, {:exit, Path.basename(path), status, out}}
      end
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
    case pid(app, ctx) do
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

  defp pid(app, ctx) do
    case File.read(Path.join(base(app, ctx), "pid")) do
      {:ok, text} -> if text =~ ~r/\A\d+\s*\z/, do: String.trim(text)
      _none -> nil
    end
  end

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
