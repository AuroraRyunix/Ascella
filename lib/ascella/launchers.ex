defmodule Ascella.Launchers do
  @moduledoc """
  Making an installed app easy to start, and undoing it.

  Per system (`Ascella.Launchers.Adapter`):

    * Windows - a Start menu shortcut and a Desktop shortcut. Pinning to the
      taskbar is the user's right-click; Windows has no supported way to do
      it for them.
    * macOS - keep in the Dock, open at login. The `.app` already sits in an
      Applications folder.
    * Linux - a menu entry, a Desktop file when `~/Desktop` exists, and GNOME
      favourites when `gsettings` does.

  ## The record

  Everything made is written to `launchers.json` in Ascella's own launchers
  folder (`ctx.launchers`): app, kind, path. Removal only ever touches what is
  recorded, and a recorded file is only deleted when it lies in one of the
  launcher folders of the context. A shortcut somebody else made with the same
  name is never overwritten and never deleted: it is reported as "already
  there" and left alone.

  ## Pointing at the right executable

  A launcher must survive an update, so it points at a path that does not
  move:

    * Windows Velopack - the stub `<main exe>` in `%LOCALAPPDATA%\\<pack id>`,
      which starts whatever `current\\` holds (when a build has no stub, then
      `Update.exe --processStart <main exe>`, which does the same). Never a
      path inside `current\\`.
    * macOS - the `.app`, which an update replaces in the same place.
    * portable (Linux, Windows) - a tiny wrapper in the launchers folder that
      reads `current` when it runs, so the versioned folder is never written
      into a shortcut.
    * Linux services - the app's page, `xdg-open http://localhost:<port>`.

  After every install and update `refresh/2` writes the file launchers again
  anyway, so a layout change cannot leave one pointing at nothing.
  """

  require Logger

  alias Ascella.{Context, Installer}
  alias Ascella.Launchers.{Linux, MacOS, Windows}

  @doc "The adapter module for this context's system."
  def adapter(%Context{family: :windows}), do: Windows
  def adapter(%Context{family: :macos}), do: MacOS
  def adapter(%Context{family: :linux}), do: Linux

  @doc "What is offered right after a first install: the one thing most people want."
  def defaults(%Context{family: :windows}), do: [:start_menu]
  def defaults(%Context{family: :macos}), do: [:dock]
  def defaults(%Context{family: :linux}), do: [:menu]

  # --- what can be started, and how ----------------------------------------------------

  @doc """
  What a launcher starts, or an error. Pure: it writes nothing (see
  `materialize/3`). Keys: `exec`, `args`, `workdir`, `icon`, `bundle`,
  `wrapper` (`%{base, folder, start}` for portable apps).
  """
  def target(app, ctx) do
    case Installer.for(app, ctx) do
      nil ->
        {:error, :no_build}

      {mod, spec} ->
        case mod.installed(app, spec, ctx) do
          %{state: :absent} -> {:error, :absent}
          status -> target_for(spec, status, app, ctx)
        end
    end
  end

  defp target_for(%{method: :velopack} = spec, %{state: :installed, where: root}, _app, _ctx) do
    stub = Path.join(root, spec.main_exe)

    if File.exists?(stub),
      do: {:ok, %{exec: stub, args: [], workdir: root, icon: stub}},
      else:
        {:ok,
         %{
           exec: Path.join(root, "Update.exe"),
           args: ["--processStart", spec.main_exe],
           workdir: root,
           icon: Path.join([root, "current", spec.main_exe])
         }}
  end

  defp target_for(%{method: :velopack} = spec, %{state: :per_machine, where: dir}, _app, _ctx) do
    exe = Path.join([dir, "current", spec.main_exe])
    {:ok, %{exec: exe, args: [], workdir: Path.dirname(exe), icon: exe}}
  end

  defp target_for(%{method: :mac_app}, %{where: bundle}, _app, _ctx),
    do: {:ok, %{bundle: bundle, args: []}}

  defp target_for(%{method: :linux_script}, _status, app, _ctx) do
    if app.port,
      do: {:ok, %{exec: "xdg-open", args: ["http://localhost:#{app.port}"], icon: :mark}},
      else: {:error, :nothing_to_launch}
  end

  defp target_for(%{method: :portable} = spec, %{where: base}, _app, _ctx),
    do:
      {:ok,
       %{wrapper: %{base: base, folder: spec.folder, start: spec.start}, args: [], icon: :mark}}

  @doc "Writes what a target needs to exist first: portable wrappers and Linux icons."
  def materialize(app, target, ctx) do
    with {:ok, target} <- wrapper(app, target, ctx), do: icon(app, target, ctx)
  end

  defp wrapper(_app, %{wrapper: %{base: base, folder: folder, start: start}} = target, ctx) do
    {name, body, mode} =
      if ctx.family == :windows do
        {"#{target_name(base)}.cmd",
         ~s(@echo off\r\nset /p V=<"#{base}\\current"\r\ncd /d "#{base}\\%V%\\#{folder}"\r\nstart "" "#{base}\\%V%\\#{folder}\\#{start}"\r\n),
         0o644}
      else
        {"#{target_name(base)}.sh",
         """
         #!/bin/sh
         base=#{sh_quote(base)}
         v=$(cat "$base/current") || exit 1
         dir="$base/$v/#{String.replace(folder, "'", "")}"
         cd "$dir" || exit 1
         exec "$dir"/#{sh_quote(start)} "$@"
         """, 0o755}
      end

    path = Path.join(ctx.launchers, name)
    File.mkdir_p!(ctx.launchers)

    with :ok <- File.write(path, body), :ok <- File.chmod(path, mode) do
      exe = if ctx.family == :windows, do: win_exe(base, folder, start), else: nil
      target = target |> Map.delete(:wrapper) |> Map.merge(%{exec: path, workdir: base})
      {:ok, if(ctx.family == :windows, do: %{target | icon: exe}, else: target)}
    end
  end

  defp wrapper(_app, target, _ctx), do: {:ok, target}

  # An .ico is not made: a shortcut takes the program's own icon, and the
  # exe of the version installed now carries it. refresh/2 follows updates.
  defp win_exe(base, folder, start) do
    with {:ok, text} <- File.read(Path.join(base, "current")),
         version = String.trim(text),
         path = Path.join([base, version, folder, start]),
         true <- File.exists?(path),
         true <- String.ends_with?(path, ".exe") do
      path
    else
      _none -> nil
    end
  end

  defp icon(app, %{icon: :mark} = target, ctx) do
    path = Path.join([ctx.launchers, "icons", app.id <> ".svg"])

    case AscellaWeb.Logo.app_mark(app.mark) do
      nil ->
        {:ok, %{target | icon: nil}}

      {view_box, inner} ->
        [x, y, w, h] = view_box |> String.split() |> Enum.map(&number/1)
        [day | _] = app.accent

        inner =
          inner
          |> String.replace(~r/var\(--[a-z-]+,\s*#[0-9a-fA-F]+\)/, day)
          |> String.replace("currentColor", "#24231f")

        svg =
          ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{view_box}">| <>
            ~s|<rect x="#{x}" y="#{y}" width="#{w}" height="#{h}" rx="#{w / 5}" fill="#ffffff"/>| <>
            ~s|<g transform="translate(#{x + w * 0.1} #{y + h * 0.1}) scale(0.8)">#{inner}</g></svg>|

        File.mkdir_p!(Path.dirname(path))
        with :ok <- File.write(path, svg), do: {:ok, %{target | icon: path}}
    end
  end

  defp icon(_app, target, _ctx), do: {:ok, target}

  defp number(text), do: text |> Float.parse() |> elem(0)

  defp target_name(base), do: base |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_-]/, "_")
  defp sh_quote(text), do: "'" <> String.replace(text, "'", "'\\''") <> "'"

  # --- what is on offer, what is on ---------------------------------------------------------

  @doc """
  The launchers of `app` on this machine: `[%{kind, on?, path}]`, empty when
  there is nothing to start (not installed, no build, a service without a page).
  """
  def options(app, ctx) do
    adapter = adapter(ctx)
    recorded = records(ctx)[app.id] || %{}

    case target(app, ctx) do
      {:ok, target} ->
        for kind <- adapter.kinds(ctx, target) do
          record = recorded[Atom.to_string(kind)]

          %{
            kind: kind,
            on?: record != nil and adapter.exists?(kind, record),
            path: record && record["path"]
          }
        end

      {:error, _} ->
        []
    end
  end

  @doc "Everything recorded for `app`, installed or not: `[kind]`."
  def recorded(app, ctx),
    do: (records(ctx)[app.id] || %{}) |> Map.keys() |> Enum.map(&String.to_atom/1)

  # --- doing -------------------------------------------------------------------------------

  @doc "Makes launcher `kind`. `:ok` or `{:error, reason}` (`:already_there` when somebody else's is in the way)."
  def add(app, kind, ctx) do
    adapter = adapter(ctx)
    key = Atom.to_string(kind)

    with {:ok, target} <- target(app, ctx),
         true <- kind in adapter.kinds(ctx, target) || {:error, :not_offered},
         :ok <- needs(kind, app, ctx),
         {:ok, target} <- materialize(app, target, ctx),
         {:ok, record} <-
           adapter.create(kind, app, target, ctx, (records(ctx)[app.id] || %{})[key]) do
      put(ctx, app.id, key, record)
    end
  end

  # GNOME favourites point at the menu entry, so it has to be there.
  defp needs(:favourites, app, ctx) do
    if :menu in recorded(app, ctx), do: :ok, else: add(app, :menu, ctx)
  end

  defp needs(_kind, _app, _ctx), do: :ok

  @doc "Removes launcher `kind` of `app`, if Ascella made it. Anything it did not make is left alone."
  def remove(app, kind, ctx) do
    key = Atom.to_string(kind)

    case (records(ctx)[app.id] || %{})[key] do
      nil ->
        :ok

      record ->
        with :ok <- delete_file(record, ctx),
             :ok <- adapter(ctx).delete(kind, app, record, ctx) do
          drop(ctx, app.id, key)
          if records(ctx)[app.id] == nil, do: tidy(app, ctx)
          :ok
        end
    end
  end

  @doc "Removes everything Ascella made for `app`. `:ok`, or the first error (the rest are still tried)."
  def remove_all(app, ctx) do
    kinds = recorded(app, ctx)

    # Favourites first: they point at the menu entry.
    kinds
    |> Enum.sort_by(&(&1 != :favourites))
    |> Enum.map(&remove(app, &1, ctx))
    |> Enum.find(:ok, &(&1 != :ok))
  end

  @doc "After an install or update: writes the file launchers again, so they point at what is there now."
  def refresh(app, ctx) do
    adapter = adapter(ctx)

    for kind <- recorded(app, ctx), kind in adapter.refreshable() do
      case add(app, kind, ctx) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Ascella: refreshing #{kind} of #{app.id}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "Windows only: opens the folder with the Start menu shortcut selected."
  def reveal(app, kind, ctx) do
    case (records(ctx)[app.id] || %{})[Atom.to_string(kind)] do
      %{"path" => path} when ctx.family == :windows ->
        # explorer exits 1 even when it worked; its status is not an answer.
        Ascella.Runner.run(ctx, "explorer", ["/select,", path])
        :ok

      _none ->
        {:error, :nothing_to_show}
    end
  end

  defp delete_file(%{"file" => true, "path" => path}, ctx) do
    if owned_folder?(path, ctx) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        error -> error
      end
    else
      {:error, {:not_ours, path}}
    end
  end

  defp delete_file(_record, _ctx), do: :ok

  defp owned_folder?(path, ctx) do
    target = segments(path)

    [ctx.start_menu, ctx.desktop, ctx.applications, ctx.launchers]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(fn dir ->
      dir = segments(dir)
      length(target) > length(dir) and List.starts_with?(target, dir)
    end)
  end

  defp segments(path) do
    path
    |> String.replace("\\", "/")
    |> Path.expand()
    |> String.downcase()
    |> String.split("/", trim: true)
  end

  # The wrapper and the icon are Ascella's own files, named after the app.
  defp tidy(app, ctx) do
    if is_binary(ctx.launchers) do
      File.rm(Path.join([ctx.launchers, "icons", app.id <> ".svg"]))

      Enum.each(["#{app.id}.sh", "#{app.id}.cmd"], &File.rm(Path.join(ctx.launchers, &1)))
    end

    :ok
  end

  # --- the record ----------------------------------------------------------------------------

  defp file(ctx), do: Path.join(ctx.launchers, "launchers.json")

  @doc false
  def records(ctx) do
    with {:ok, text} <- File.read(file(ctx)),
         {:ok, %{} = map} <- Jason.decode(text) do
      map
    else
      _none -> %{}
    end
  end

  defp put(ctx, id, key, record) do
    records = records(ctx)
    save(ctx, Map.put(records, id, Map.put(records[id] || %{}, key, record)))
  end

  defp drop(ctx, id, key) do
    records = records(ctx)
    left = Map.delete(records[id] || %{}, key)
    save(ctx, if(left == %{}, do: Map.delete(records, id), else: Map.put(records, id, left)))
  end

  defp save(ctx, records) do
    File.mkdir_p!(ctx.launchers)
    tmp = file(ctx) <> ".new"

    with :ok <- File.write(tmp, Jason.encode!(records, pretty: true)),
         do: File.rename(tmp, file(ctx))
  end
end
