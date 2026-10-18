defmodule Ascella.Launchers.MacOS do
  @moduledoc """
  The Dock and login items. The `.app` itself already sits in
  `/Applications` or `~/Applications`, where `Ascella.Installer.MacApp` puts
  it, so there is nothing to copy.

    * **Dock** - always through `cfprefsd`, the daemon that owns the Dock's
      preferences and caches them. Editing the plist file behind its back is
      ignored, which is how "Keep in Dock" used to do nothing. So:
      `defaults export com.apple.dock <file>`, edit `persistent-apps` in that
      copy with PlistBuddy (add a file tile, or delete every tile that points
      at the bundle), `defaults import com.apple.dock <file>`, `killall Dock`.
      Adding is checked against the export first, so a second click does not
      make a second icon. "Is it in the Dock" is read from an export too, so
      the checkbox shows what the Dock shows.
    * **Open at login** - a login item through System Events. The first use
      makes macOS ask whether Ascella may control System Events.
  """
  @behaviour Ascella.Launchers.Adapter

  alias Ascella.{Installer, Runner}

  @plist_buddy "/usr/libexec/PlistBuddy"
  @domain "com.apple.dock"
  @key ":persistent-apps"
  # More tiles than any Dock has: a loop that cannot end is worse than a Dock that is not read to the end.
  @max_tiles 500

  @impl true
  def kinds(_ctx, target), do: if(target[:bundle], do: [:dock, :login], else: [])

  @impl true
  def refreshable, do: []

  @impl true
  def create(:dock, _app, target, ctx, _existing) do
    bundle = target.bundle

    with_export(ctx, fn file ->
      {_array?, tiles} = tiles(ctx, file)

      if Enum.any?(tiles, fn {_index, path} -> same?(path, bundle) end) do
        {:error, :already_there}
      else
        with :ok <- add_tile(ctx, file, count(ctx, file, 0), bundle),
             :ok <- Installer.run(ctx, "defaults", ["import", @domain, file]),
             :ok <- Installer.run(ctx, "killall", ["Dock"]) do
          {:ok, %{"path" => bundle, "file" => false}}
        end
      end
    end)
  end

  def create(:login, _app, target, ctx, _existing) do
    script = [
      "-e",
      "on run argv",
      "-e",
      "tell application \"System Events\" to make login item at end with properties {path:(item 1 of argv), hidden:false}",
      "-e",
      "end run",
      target.bundle
    ]

    with :ok <- Installer.run(ctx, "osascript", script),
         do: {:ok, %{"path" => target.bundle, "file" => false}}
  end

  @impl true
  def delete(:dock, _app, %{"path" => bundle}, ctx) do
    with_export(ctx, fn file ->
      {_array?, tiles} = tiles(ctx, file)

      # Highest index first, so that deleting one does not renumber the next.
      case for({i, path} <- tiles, same?(path, bundle), do: i) |> Enum.sort(:desc) do
        [] ->
          :ok

        indices ->
          commands = Enum.flat_map(indices, &["-c", "Delete #{@key}:#{&1}"])

          with :ok <- Installer.run(ctx, @plist_buddy, commands ++ [file]),
               :ok <- Installer.run(ctx, "defaults", ["import", @domain, file]),
               do: Installer.run(ctx, "killall", ["Dock"])
      end
    end)
  end

  def delete(:login, _app, %{"path" => bundle}, ctx) do
    Installer.run(ctx, "osascript", [
      "-e",
      "on run argv",
      "-e",
      "tell application \"System Events\" to delete (every login item whose path is (item 1 of argv))",
      "-e",
      "end run",
      bundle
    ])
  end

  @impl true
  def exists?(:dock, %{"path" => bundle}, ctx) do
    case Runner.run(ctx, "defaults", ["export", @domain, "-"]) do
      {xml, 0} -> Enum.any?(dock_bundles(xml), &same?(&1, bundle))
      _failed -> false
    end
  end

  def exists?(_kind, _record, _ctx), do: true

  @doc false
  # The bundle paths of the Dock's `persistent-apps`, out of an XML export.
  # Only that section: `recent-apps` and `persistent-others` carry the same keys.
  def dock_bundles(xml) do
    section =
      case String.split(xml, "<key>persistent-apps</key>", parts: 2) do
        [_before, rest] ->
          rest
          |> String.split(~r/<key>(persistent-others|recent-apps)<\/key>/, parts: 2)
          |> hd()

        _none ->
          ""
      end

    ~r/<key>_CFURLString<\/key>\s*<string>([^<]*)<\/string>/
    |> Regex.scan(section, capture: :all_but_first)
    |> Enum.map(fn [url] -> path_of(url) end)
  end

  # --- the exported copy ---------------------------------------------------------------

  # `defaults export` into a file of our own, `fun` edits it, and the file
  # goes whatever happens.
  defp with_export(ctx, fun) do
    file =
      Path.join(System.tmp_dir!(), "ascella-dock-#{System.unique_integer([:positive])}.plist")

    try do
      with :ok <- Installer.run(ctx, "defaults", ["export", @domain, file]), do: fun.(file)
    after
      File.rm(file)
    end
  end

  # `{array_there?, [{index, bundle_path}]}`: the tiles that point at a file.
  # Read one at a time, because PlistBuddy prints nothing a program could
  # split safely (a tile can hold a binary bookmark), and a tile without a
  # file (a spacer) is skipped, not taken for the end.
  defp tiles(ctx, file) do
    case pb(ctx, file, "Print #{@key}") do
      {_out, 0} -> {true, scan(ctx, file, 0, [])}
      _missing -> {false, []}
    end
  end

  defp scan(_ctx, _file, i, acc) when i >= @max_tiles, do: Enum.reverse(acc)

  defp scan(ctx, file, i, acc) do
    case pb(ctx, file, "Print #{@key}:#{i}:tile-data:file-data:_CFURLString") do
      {url, 0} ->
        scan(ctx, file, i + 1, [{i, path_of(String.trim(url))} | acc])

      _no_url ->
        case pb(ctx, file, "Print #{@key}:#{i}") do
          {_out, 0} -> scan(ctx, file, i + 1, acc)
          _end -> Enum.reverse(acc)
        end
    end
  end

  # How many tiles the array has: the index a new one goes at.
  defp count(_ctx, _file, i) when i >= @max_tiles, do: i

  defp count(ctx, file, i) do
    case pb(ctx, file, "Print #{@key}:#{i}") do
      {_out, 0} -> count(ctx, file, i + 1)
      _end -> i
    end
  end

  defp pb(ctx, file, command), do: Runner.run(ctx, @plist_buddy, ["-c", command, file])

  defp add_tile(ctx, file, index, bundle) do
    at = "#{@key}:#{index}"

    # A Dock that never had a tile of its own has no array yet: made first.
    make_array =
      case pb(ctx, file, "Print #{@key}") do
        {_out, 0} -> []
        _missing -> ["-c", "Add #{@key} array"]
      end

    Installer.run(
      ctx,
      @plist_buddy,
      make_array ++
        [
          "-c",
          "Add #{at} dict",
          "-c",
          "Add #{at}:tile-type string file-tile",
          "-c",
          "Add #{at}:tile-data dict",
          "-c",
          "Add #{at}:tile-data:file-data dict",
          "-c",
          "Add #{at}:tile-data:file-data:_CFURLString string #{url(bundle)}",
          "-c",
          "Add #{at}:tile-data:file-data:_CFURLStringType integer 15",
          file
        ]
    )
  end

  # --- paths and URLs ---------------------------------------------------------------------

  # What the Dock itself writes for an app: a file:// URL, encoded, with a
  # trailing slash because a bundle is a folder.
  defp url(bundle), do: "file://" <> encode(bundle) <> "/"

  defp encode(path), do: URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))

  defp path_of(url) do
    url
    |> String.replace_prefix("file://localhost", "")
    |> String.replace_prefix("file://", "")
    |> URI.decode()
    |> String.trim_trailing("/")
  end

  defp same?(path, bundle), do: path == String.trim_trailing(bundle, "/")
end
