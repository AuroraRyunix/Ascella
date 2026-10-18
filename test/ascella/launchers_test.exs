defmodule Ascella.LaunchersTest do
  @moduledoc """
  Shortcuts, pins and favourites, and their removal. Every folder is under a
  temporary directory and every command goes to the fake runner: nothing here
  can reach this PC's Start menu, Desktop, Dock or gsettings. What is checked
  is the paths and commands that would have been used, the record, and the
  cleanup.
  """
  use ExUnit.Case, async: false

  alias Ascella.{Catalogue, FakeGitHub, FakeMachine, FakeRunner, Installer, Launchers}

  setup do
    tmp = Path.expand("ascella-launch-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(&FakeRunner.reset/0)
    {:ok, tmp: tmp}
  end

  defp app(id), do: Catalogue.get(id)

  defp file_url(bundle),
    do: "file://" <> URI.encode(bundle, &(URI.char_unreserved?(&1) or &1 == ?/)) <> "/"

  defp release(v), do: %{version: v, tag: "v" <> v}

  # --- Windows ----------------------------------------------------------------------

  defp windows(tmp) do
    ctx = FakeMachine.context(tmp, :windows)
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.0.0", files: %{"Zipapp-1.0.0-win-Setup.exe" => "setup"}}
    })

    :ok = Installer.install(app("zipapp"), release("1.0.0"), ctx)
    ctx
  end

  test "Windows: the Start menu shortcut points at the stub in the install folder, not at current",
       %{
         tmp: tmp
       } do
    ctx = windows(tmp)
    root = Path.join(ctx.local_app_data, "ZipappApp")
    File.write!(Path.join(root, "Zipapp.exe"), "stub")

    assert [%{kind: :start_menu, on?: false}, %{kind: :desktop, on?: false}] =
             Launchers.options(app("zipapp"), ctx)

    assert :ok = Launchers.add(app("zipapp"), :start_menu, ctx)

    lnk = Path.join(ctx.start_menu, "Zipapp.lnk")
    assert File.exists?(lnk)

    assert [%{kind: :start_menu, on?: true, path: ^lnk}, _] =
             Launchers.options(app("zipapp"), ctx)

    # The target went through the environment, not into the script text.
    {"powershell", args} = List.last(FakeRunner.calls())
    refute Enum.any?(args, &(&1 =~ root))
    assert File.read!(Path.join(ctx.launchers, "launchers.json")) =~ "Zipapp.lnk"
  end

  test "Windows: without a stub, Update.exe --processStart does the same job", %{tmp: tmp} do
    ctx = windows(tmp)
    root = Path.join(ctx.local_app_data, "ZipappApp")

    assert {:ok, %{exec: exec, args: ["--processStart", "Zipapp.exe"]}} =
             Launchers.target(app("zipapp"), ctx)

    assert exec == Path.join(root, "Update.exe")
    refute exec =~ "current"
  end

  test "Windows: a shortcut of somebody else's is not overwritten and not removed", %{tmp: tmp} do
    ctx = windows(tmp)
    File.mkdir_p!(ctx.start_menu)
    File.write!(Path.join(ctx.start_menu, "Zipapp.lnk"), "theirs")

    assert {:error, :already_there} = Launchers.add(app("zipapp"), :start_menu, ctx)
    assert :ok = Launchers.remove(app("zipapp"), :start_menu, ctx)
    assert File.read!(Path.join(ctx.start_menu, "Zipapp.lnk")) == "theirs"
  end

  test "Windows: remove deletes only what was recorded; removing the app removes all of it", %{
    tmp: tmp
  } do
    ctx = windows(tmp)
    :ok = Launchers.add(app("zipapp"), :start_menu, ctx)
    :ok = Launchers.add(app("zipapp"), :desktop, ctx)
    bystander = Path.join(ctx.desktop, "Mine.lnk")
    File.write!(bystander, "mine")

    assert :ok = Launchers.remove(app("zipapp"), :desktop, ctx)
    refute File.exists?(Path.join(ctx.desktop, "Zipapp.lnk"))
    assert File.exists?(Path.join(ctx.start_menu, "Zipapp.lnk"))

    assert :ok = Installer.uninstall(app("zipapp"), ctx)
    refute File.exists?(Path.join(ctx.start_menu, "Zipapp.lnk"))
    assert File.exists?(bystander)
    assert Launchers.recorded(app("zipapp"), ctx) == []
  end

  test "Windows: a record pointing outside the launcher folders is never deleted", %{tmp: tmp} do
    ctx = windows(tmp)
    victim = Path.join(tmp, "precious.txt")
    File.write!(victim, "keep")
    File.mkdir_p!(ctx.launchers)

    File.write!(
      Path.join(ctx.launchers, "launchers.json"),
      Jason.encode!(%{"zipapp" => %{"desktop" => %{"path" => victim, "file" => true}}})
    )

    assert {:error, {:not_ours, ^victim}} = Launchers.remove(app("zipapp"), :desktop, ctx)
    assert File.read!(victim) == "keep"
  end

  test "Windows: refresh after an update remakes the shortcut", %{tmp: tmp} do
    ctx = windows(tmp)
    :ok = Launchers.add(app("zipapp"), :start_menu, ctx)
    File.rm!(Path.join(ctx.start_menu, "Zipapp.lnk"))
    File.write!(Path.join([ctx.local_app_data, "ZipappApp", "Zipapp.exe"]), "stub")

    assert :ok = Launchers.refresh(app("zipapp"), ctx)
    assert File.exists?(Path.join(ctx.start_menu, "Zipapp.lnk"))
  end

  test "Windows: uninstall runs the app's own Update.exe, keeps the data, drops the shortcuts", %{
    tmp: tmp
  } do
    ctx = windows(tmp)
    data = Path.join(ctx.local_app_data, "ZipappData")
    File.mkdir_p!(data)
    File.write!(Path.join(data, "t.db"), "round five")
    :ok = Launchers.add(app("zipapp"), :start_menu, ctx)

    assert :ok = Installer.uninstall(app("zipapp"), ctx)
    assert Enum.any?(FakeRunner.calls(), &match?({_, ["--silent", "uninstall"]}, &1))
    assert %{state: :absent} = Installer.installed(app("zipapp"), ctx)
    assert File.read!(Path.join(data, "t.db")) == "round five"
    refute File.exists?(Path.join(ctx.start_menu, "Zipapp.lnk"))
  end

  test "Windows: deleting the data is explicit, and touches only that app's folders", %{tmp: tmp} do
    ctx = windows(tmp)
    mine = Path.join(ctx.local_app_data, "ZipappData")
    other = Path.join(ctx.local_app_data, "HallappData")

    for dir <- [mine, other],
        do:
          (
            File.mkdir_p!(dir)
            File.write!(Path.join(dir, "t.db"), dir)
          )

    assert :ok = Installer.uninstall(app("zipapp"), ctx, delete_data: true)
    refute File.exists?(mine)
    assert File.exists?(Path.join(other, "t.db"))
  end

  test "Windows: an install folder holding a database is not uninstalled", %{tmp: tmp} do
    ctx = windows(tmp)
    File.write!(Path.join([ctx.local_app_data, "ZipappApp", "x.db"]), "data")

    assert {:error, {:install_folder_holds_data, _, "x.db"}} =
             Installer.uninstall(app("zipapp"), ctx)

    refute Enum.any?(FakeRunner.calls(), &match?({_, ["--silent", "uninstall"]}, &1))
  end

  # --- macOS ------------------------------------------------------------------------

  defp mac(tmp), do: tmp |> mac_with() |> elem(0)

  defp mac_with(tmp, opts \\ []) do
    ctx = FakeMachine.context(tmp, :macos)
    File.mkdir_p!(hd(ctx.mac_apps))
    agent = FakeMachine.start(ctx, opts)

    zip =
      FakeGitHub.zip([
        {"Zipapp.app/Contents/Info.plist", FakeGitHub.plist("1.0.0")},
        {"Zipapp.app/Contents/MacOS/Zipapp", "launcher"}
      ])

    FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.0.0", files: %{"zipapp_app_macos_aarch64.zip" => zip}}
    })

    :ok = Installer.install(app("zipapp"), release("1.0.0"), ctx)
    {ctx, agent}
  end

  test "Mac: Dock is edited through cfprefsd: export, PlistBuddy on the copy, import, killall; not twice",
       %{tmp: tmp} do
    other = "file:///Applications/Other.app/"
    {ctx, agent} = mac_with(tmp, dock: [other, :spacer])
    bundle = Path.join(hd(ctx.mac_apps), "Zipapp.app")

    assert [%{kind: :dock, on?: false}, %{kind: :login}] = Launchers.options(app("zipapp"), ctx)
    FakeRunner.clear()
    assert :ok = Launchers.add(app("zipapp"), :dock, ctx)

    calls = FakeRunner.calls()
    assert {"defaults", ["export", "com.apple.dock", file]} = hd(calls)

    pb = "/usr/libexec/PlistBuddy"
    add_at = Enum.find_index(calls, &match?({^pb, ["-c", "Add :persistent-apps:2 dict" | _]}, &1))

    import_at =
      Enum.find_index(calls, &match?({"defaults", ["import", "com.apple.dock", ^file]}, &1))

    assert add_at && import_at && add_at < import_at
    # The array has a spacer in it: it is skipped over, not taken for the end.
    assert {pb, ["-c", "Print :persistent-apps:2", file]} in calls
    assert List.last(calls) == {"killall", ["Dock"]}
    {^pb, add} = Enum.at(calls, add_at)

    assert add == [
             "-c",
             "Add :persistent-apps:2 dict",
             "-c",
             "Add :persistent-apps:2:tile-type string file-tile",
             "-c",
             "Add :persistent-apps:2:tile-data dict",
             "-c",
             "Add :persistent-apps:2:tile-data:file-data dict",
             "-c",
             "Add :persistent-apps:2:tile-data:file-data:_CFURLString string #{file_url(bundle)}",
             "-c",
             "Add :persistent-apps:2:tile-data:file-data:_CFURLStringType integer 15",
             file
           ]

    assert FakeMachine.dock(agent) == [other, :spacer, file_url(bundle)]
    refute File.exists?(file)

    # The checkbox reads the Dock itself.
    assert [%{kind: :dock, on?: true}, _login] = Launchers.options(app("zipapp"), ctx)

    # A second click: already there, and nothing is imported.
    FakeRunner.clear()
    assert {:error, :already_there} = Launchers.add(app("zipapp"), :dock, ctx)
    refute Enum.any?(FakeRunner.calls(), &match?({"defaults", ["import" | _]}, &1))
  end

  test "Mac: a tile put there by hand is left alone, and not added twice", %{tmp: tmp} do
    {ctx, agent} = mac_with(tmp)
    bundle = Path.join(hd(ctx.mac_apps), "Zipapp.app")
    Agent.update(agent, &%{&1 | dock: [file_url(bundle)]})

    assert {:error, :already_there} = Launchers.add(app("zipapp"), :dock, ctx)
    assert FakeMachine.dock(agent) == [file_url(bundle)]
  end

  test "Mac: unticking deletes every tile that points at the bundle, through the export",
       %{tmp: tmp} do
    other = "file:///Applications/Other.app/"
    {ctx, agent} = mac_with(tmp)
    bundle = Path.join(hd(ctx.mac_apps), "Zipapp.app")
    :ok = Launchers.add(app("zipapp"), :dock, ctx)
    :ok = Launchers.add(app("zipapp"), :login, ctx)
    # Twice in the Dock, once with the bare path, with another app between.
    Agent.update(agent, &%{&1 | dock: [file_url(bundle), other, file_url(bundle)]})

    assert :ok = Launchers.remove_all(app("zipapp"), ctx)

    assert FakeMachine.dock(agent) == [other]

    deletes =
      for {p, args} <- FakeRunner.calls(),
          p =~ "PlistBuddy",
          "Delete :persistent-apps:2" in args,
          do: args

    assert [["-c", "Delete :persistent-apps:2", "-c", "Delete :persistent-apps:0", _file]] =
             deletes

    assert {"killall", ["Dock"]} in FakeRunner.calls()

    assert Enum.any?(FakeRunner.calls(), fn
             {"osascript", args} ->
               List.last(args) == bundle and Enum.any?(args, &(&1 =~ "delete"))

             _other ->
               false
           end)

    assert Launchers.recorded(app("zipapp"), ctx) == []
  end

  test "Mac: unticking when the Dock does not have it touches nothing", %{tmp: tmp} do
    {ctx, agent} = mac_with(tmp)
    :ok = Launchers.add(app("zipapp"), :dock, ctx)
    # Taken out by hand since.
    Agent.update(agent, &%{&1 | dock: ["file:///Applications/Other.app/"]})
    FakeRunner.clear()

    assert :ok = Launchers.remove(app("zipapp"), :dock, ctx)
    refute Enum.any?(FakeRunner.calls(), &match?({"defaults", ["import" | _]}, &1))
    refute {"killall", ["Dock"]} in FakeRunner.calls()
  end

  test "Mac: dock_bundles reads only persistent-apps" do
    xml =
      "<dict><key>persistent-apps</key><array><dict><key>_CFURLString</key><string>file:///Applications/My%20App.app/</string></dict></array>" <>
        "<key>recent-apps</key><array><dict><key>_CFURLString</key><string>file:///Applications/Recent.app/</string></dict></array></dict>"

    assert Ascella.Launchers.MacOS.dock_bundles(xml) == ["/Applications/My App.app"]
  end

  test "Mac: uninstall puts the bundle in the Trash through Finder and drops the Dock tile", %{
    tmp: tmp
  } do
    ctx = mac(tmp)
    bundle = Path.join(hd(ctx.mac_apps), "Zipapp.app")
    :ok = Launchers.add(app("zipapp"), :dock, ctx)

    assert :ok = Installer.uninstall(app("zipapp"), ctx)
    assert Enum.any?(FakeRunner.calls(), &match?({"osascript", [_, _, _, _, _, _, ^bundle]}, &1))
    refute File.exists?(bundle)
    assert Launchers.recorded(app("zipapp"), ctx) == []
  end

  # --- Linux ------------------------------------------------------------------------

  defp linux_portable(tmp) do
    ctx = FakeMachine.context(tmp, :linux)
    base = Path.join(ctx.programs, "zipapp")
    File.mkdir_p!(Path.join([base, "1.0.0", "zipapp_portable"]))
    File.write!(Path.join([base, "1.0.0", "zipapp_portable", "zipapp.sh"]), "#!/bin/sh\n")
    File.write!(Path.join(base, "current"), "1.0.0\n")
    File.mkdir_p!(ctx.desktop)
    ctx
  end

  test "Linux: a .desktop file in the menu, a copy on the Desktop, a wrapper that reads current",
       %{
         tmp: tmp
       } do
    ctx = linux_portable(tmp)
    FakeRunner.script(fn _program, _args, _opts -> {"", 0} end)

    assert [%{kind: :menu}, %{kind: :desktop}, %{kind: :favourites}] =
             Launchers.options(app("zipapp"), ctx)

    assert :ok = Launchers.add(app("zipapp"), :menu, ctx)
    assert :ok = Launchers.add(app("zipapp"), :desktop, ctx)

    entry = File.read!(Path.join(ctx.applications, "ascella-zipapp.desktop"))
    assert entry =~ "[Desktop Entry]"
    assert entry =~ "Name=Zipapp"
    wrapper = Path.join(ctx.launchers, "zipapp.sh")
    assert entry =~ "Exec=" <> wrapper
    assert entry =~ "Icon=" <> Path.join([ctx.launchers, "icons", "zipapp.svg"])
    assert File.read!(wrapper) =~ ~s(cat "$base/current")
    refute File.read!(wrapper) =~ "1.0.0"
    assert File.exists?(Path.join(ctx.desktop, "Zipapp.desktop"))

    assert :ok = Launchers.remove_all(app("zipapp"), ctx)
    refute File.exists?(Path.join(ctx.applications, "ascella-zipapp.desktop"))
    refute File.exists?(Path.join(ctx.desktop, "Zipapp.desktop"))
    refute File.exists?(wrapper)
  end

  test "Linux: a service with a page starts xdg-open on it; one without has no launcher", %{
    tmp: tmp
  } do
    ctx = FakeMachine.context(tmp, :linux)
    dir = Path.join(ctx.root, "opt/hallapp/current")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "VERSION"), "1.0.0\n")

    assert {:ok, %{exec: "xdg-open", args: ["http://localhost:4999"]}} =
             Launchers.target(app("hallapp"), ctx)

    ghost_dir = Path.join(ctx.root, "opt/ghost/current")
    File.mkdir_p!(ghost_dir)
    File.write!(Path.join(ghost_dir, "VERSION"), "1.0.0\n")
    assert Launchers.options(app("ghost"), ctx) == []
  end

  test "Linux: favourites go through gsettings, are added once, and come out again", %{tmp: tmp} do
    ctx = linux_portable(tmp)
    parent = self()
    {:ok, favs} = Agent.start_link(fn -> "['org.gnome.Terminal.desktop']" end)

    FakeRunner.script(fn program, args, _opts ->
      case {program, args} do
        {"gsettings", ["get", "org.gnome.shell", "favorite-apps"]} ->
          {Agent.get(favs, & &1) <> "\n", 0}

        {"gsettings", ["set", "org.gnome.shell", "favorite-apps", value]} ->
          send(parent, {:set, value})
          Agent.update(favs, fn _ -> value end)
          {"", 0}

        _other ->
          {"", 0}
      end
    end)

    assert :ok = Launchers.add(app("zipapp"), :favourites, ctx)
    assert_received {:set, "['org.gnome.Terminal.desktop', 'ascella-zipapp.desktop']"}
    # The menu entry it points at was made too.
    assert File.exists?(Path.join(ctx.applications, "ascella-zipapp.desktop"))

    assert :ok = Launchers.remove(app("zipapp"), :favourites, ctx)
    assert_received {:set, "['org.gnome.Terminal.desktop']"}
  end

  test "Linux: without gsettings there is no favourites option; without ~/Desktop no Desktop one",
       %{
         tmp: tmp
       } do
    ctx = linux_portable(tmp)
    File.rm_rf!(ctx.desktop)
    ctx = %{ctx | gsettings: false}

    assert [%{kind: :menu}] = Launchers.options(app("zipapp"), ctx)
    assert {:error, :not_offered} = Launchers.add(app("zipapp"), :favourites, ctx)
  end

  test "Linux: uninstall without an own script reverses install in root's commands", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :linux)
    machine = FakeMachine.start(ctx, running: ["hallapp.service"])
    dir = Path.join(ctx.root, "opt/hallapp")
    File.mkdir_p!(Path.join(dir, "current"))
    File.write!(Path.join([dir, "current", "VERSION"]), "1.0.0\n")
    data = Path.join(ctx.root, "var/lib/hallapp")
    File.mkdir_p!(data)
    File.write!(Path.join(data, "t.db"), "keep")

    assert :ok = Installer.uninstall(app("hallapp"), ctx)
    refute File.exists?(dir)
    refute FakeMachine.running?(machine, "hallapp.service")
    assert File.read!(Path.join(data, "t.db")) == "keep"

    assert {"sudo", ["-n", "systemctl", "disable", "--now", "hallapp.service"]} in FakeRunner.calls()
  end

  test "an app that is not installed cannot be removed", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :windows)
    FakeMachine.start(ctx)
    assert {:error, :absent} = Installer.uninstall(app("zipapp"), ctx)
  end
end
