defmodule Ascella.Launchers.MacOS do
  @moduledoc """
  The Dock and login items. The `.app` itself already sits in
  `/Applications` or `~/Applications`, where `Ascella.Installer.MacApp` puts
  it, so there is nothing to copy.

    * **Dock** - `defaults write com.apple.dock persistent-apps -array-add`
      with a file tile, then `killall Dock` (the Dock only re-reads on a
      restart). Checked first, so a second click does not make a second icon.
      Removal edits the same plist with PlistBuddy, the only workable way to
      delete one array element, and restarts the Dock.
    * **Open at login** - a login item through System Events. The first use
      makes macOS ask whether Ascella may control System Events.
  """
  @behaviour Ascella.Launchers.Adapter

  alias Ascella.{Installer, Runner}

  @remove_script """
  plist="$HOME/Library/Preferences/com.apple.dock.plist"
  want="$1"
  i=0
  while p=$(/usr/libexec/PlistBuddy -c "Print :persistent-apps:$i:tile-data:file-data:_CFURLString" "$plist" 2>/dev/null); do
    if [ "$p" = "$want" ] || [ "$p" = "$want/" ]; then
      /usr/libexec/PlistBuddy -c "Delete :persistent-apps:$i" "$plist" || exit 1
      killall Dock
      exit 0
    fi
    i=$((i+1))
  done
  exit 0
  """

  @impl true
  def kinds(_ctx, target), do: if(target[:bundle], do: [:dock, :login], else: [])

  @impl true
  def refreshable, do: []

  @impl true
  def create(:dock, _app, target, ctx, _existing) do
    bundle = target.bundle

    {listing, _status} =
      Runner.run(ctx, "defaults", ["read", "com.apple.dock", "persistent-apps"])

    if String.contains?(listing, [bundle, encode(bundle)]) do
      {:error, :already_there}
    else
      with :ok <-
             Installer.run(ctx, "defaults", [
               "write",
               "com.apple.dock",
               "persistent-apps",
               "-array-add",
               tile(bundle)
             ]),
           :ok <- Installer.run(ctx, "killall", ["Dock"]) do
        {:ok, %{"path" => bundle, "file" => false}}
      end
    end
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
  def delete(:dock, _app, %{"path" => bundle}, ctx),
    do: Installer.run(ctx, "sh", ["-c", @remove_script, "sh", url(bundle)])

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
  def exists?(_kind, _record), do: true

  # What the Dock itself writes for an app: a file tile with a file:// URL.
  defp tile(bundle) do
    "<dict><key>tile-data</key><dict><key>file-data</key><dict>" <>
      "<key>_CFURLString</key><string>#{escape(url(bundle))}</string>" <>
      "<key>_CFURLStringType</key><integer>15</integer></dict></dict>" <>
      "<key>tile-type</key><string>file-tile</string></dict>"
  end

  defp url(bundle), do: "file://" <> encode(bundle) <> "/"

  defp encode(path), do: URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))

  defp escape(text), do: text |> String.replace("&", "&amp;") |> String.replace("<", "&lt;")
end
