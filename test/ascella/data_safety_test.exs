defmodule Ascella.DataSafetyTest do
  @moduledoc """
  The one promise that is not negotiable: installing, updating and going
  back never delete, move or change an app's data directory.

  Every way an app ships (a Mac app, Velopack, a Linux install script, a
  portable zip) is run through first install, update and - where there is
  one - rollback on a fake machine, with every data directory of every app
  in the catalogue full of files. Before and after, the data is read byte
  for byte, and it must not have changed. And no program the installers ran
  may have been handed a path that lies in, or contains, a data directory.
  """
  use ExUnit.Case, async: false

  alias Ascella.{Catalogue, FakeGitHub, FakeMachine, FakeRunner, Fs, Guard, Installer}

  setup do
    tmp = Path.expand("ascella-safety-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(&FakeRunner.reset/0)
    {:ok, tmp: tmp}
  end

  # Every data directory of every app, with something in it worth keeping.
  defp fill_data(ctx) do
    for {_id, dir} <- Guard.protected(ctx) do
      File.mkdir_p!(Path.join(dir, "backups"))
      File.write!(Path.join(dir, "tournaments.db"), "round five, " <> dir)
      File.write!(Path.join([dir, "backups", "before.db"]), "a backup")
    end

    snapshot(ctx)
  end

  defp snapshot(ctx) do
    for {_id, dir} <- Guard.protected(ctx),
        file <- Path.wildcard(Path.join(dir, "**/*"), match_dot: true),
        File.regular?(file),
        into: %{},
        do: {file, File.read!(file)}
  end

  defp assert_data_untouched(ctx, before) do
    assert snapshot(ctx) == before
    assert map_size(before) > 0

    for {_program, args} <- FakeRunner.calls(), arg <- args, String.contains?(arg, ["/", "\\"]) do
      assert Guard.check(arg, ctx) == :ok,
             "a program was handed #{arg}, which overlaps a data directory"
    end
  end

  defp release(version), do: %{version: version, tag: "v" <> version}

  defp app(id), do: Catalogue.get(id)

  # --- macOS ------------------------------------------------------------------------

  defp mac_release(version) do
    zip =
      FakeGitHub.zip([
        {"Zipapp.app/Contents/Info.plist", FakeGitHub.plist(version)},
        {"Zipapp.app/Contents/MacOS/Zipapp", "launcher #{version}"}
      ])

    %{version: version, files: %{"zipapp_app_macos_aarch64.zip" => zip}}
  end

  test "Mac: install, update, rollback keep the data, the previous app, and stop politely", %{
    tmp: tmp
  } do
    ctx = FakeMachine.context(tmp, :macos)
    File.mkdir_p!(hd(ctx.mac_apps))
    before = fill_data(ctx)
    machine = FakeMachine.start(ctx)

    FakeGitHub.serve(%{"Example/Zipapp" => mac_release("1.0.0")})
    assert :ok = Installer.install(app("zipapp"), release("1.0.0"), ctx)
    assert %{version: "1.0.0", previous: nil} = Installer.installed(app("zipapp"), ctx)

    assert :ok = Installer.start(app("zipapp"), ctx)
    assert FakeMachine.running?(machine, "Zipapp.app")

    FakeGitHub.serve(%{"Example/Zipapp" => mac_release("1.1.0")})

    # Open: refused at once, nothing downloaded, swapped or stopped.
    assert {:error, {:running, "Zipapp"}} =
             Installer.install(app("zipapp"), release("1.1.0"), ctx)

    assert {:error, {:running, "Zipapp"}} = Installer.rollback(app("zipapp"), ctx)
    assert %{version: "1.0.0", previous: nil} = Installer.installed(app("zipapp"), ctx)
    refute {"kill", ["-TERM", "4242"]} in FakeRunner.calls()

    # Stopped with SIGTERM to the launcher, by the Stop button.
    assert :ok = Installer.stop(app("zipapp"), ctx)
    assert {"kill", ["-TERM", "4242"]} in FakeRunner.calls()
    refute FakeMachine.running?(machine, "Zipapp.app")

    assert :ok = Installer.install(app("zipapp"), release("1.1.0"), ctx)
    assert %{version: "1.1.0", previous: "1.0.0"} = Installer.installed(app("zipapp"), ctx)
    # Nobody starts it again: it was closed on purpose.
    refute FakeMachine.running?(machine, "Zipapp.app")
    refute Enum.any?(FakeRunner.calls(), fn {p, args} -> p == "kill" and "-9" in args end)

    assert :ok = Installer.rollback(app("zipapp"), ctx)
    assert %{version: "1.0.0", previous: "1.1.0"} = Installer.installed(app("zipapp"), ctx)

    assert_data_untouched(ctx, before)
  end

  test "Mac: an open app is refused, and one that will not stop times out with an error", %{
    tmp: tmp
  } do
    ctx = FakeMachine.context(tmp, :macos)
    File.mkdir_p!(hd(ctx.mac_apps))
    before = fill_data(ctx)
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{"Example/Zipapp" => mac_release("1.0.0")})
    assert :ok = Installer.install(app("zipapp"), release("1.0.0"), ctx)

    FakeMachine.start(ctx, running: ["Zipapp.app"], stubborn: true)
    FakeGitHub.serve(%{"Example/Zipapp" => mac_release("1.1.0")})

    assert {:error, {:running, "Zipapp"}} =
             Installer.install(app("zipapp"), release("1.1.0"), ctx)

    # The Stop button on an app that never closes: an error after the
    # context's stop timeout, not a wait without end.
    started = System.monotonic_time(:millisecond)
    assert {:error, :did_not_stop} = Installer.stop(app("zipapp"), ctx)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert %{version: "1.0.0", previous: nil} = Installer.installed(app("zipapp"), ctx)

    assert_data_untouched(ctx, before)
  end

  test "Mac: an Applications folder inside a data directory is refused before anything is written",
       %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :macos)
    before = fill_data(ctx)
    [{_id, data} | _] = Guard.protected(ctx, [app("zipapp")])
    ctx = %{ctx | mac_apps: [Path.join(data, "Applications")]}
    File.mkdir_p!(hd(ctx.mac_apps))
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{"Example/Zipapp" => mac_release("1.0.0")})

    assert {:error, {:data_dir, "zipapp", _}} =
             Installer.install(app("zipapp"), release("1.0.0"), ctx)

    # Only the empty folder this test made itself is new in there.
    assert Map.keys(snapshot(ctx)) == Map.keys(before)
  end

  test "an app with rollback off is refused before anything is looked at", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :macos)
    FakeMachine.start(ctx)
    app = %{app("zipapp") | rollback: false}

    assert {:error, :no_rollback} = Installer.rollback(app, ctx)
    assert FakeRunner.calls() == []
  end

  test "a command that outlives its deadline ends as a timeout error, not a wait", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :macos)
    FakeRunner.script(fn _program, _args, _opts -> {"no answer", 124} end)

    assert {:error, {:timeout, "osascript"}} = Installer.run(ctx, "osascript", ["-e", "x"])
  end

  test "the real runner gives up on a program that does not finish" do
    case System.find_executable("sleep") do
      nil ->
        :ok

      sleep ->
        started = System.monotonic_time(:millisecond)
        assert {message, 124} = Ascella.Runner.System.cmd(sleep, ["30"], timeout: 200)
        assert message =~ "no answer"
        assert System.monotonic_time(:millisecond) - started < 5_000
    end
  end

  # --- Windows ----------------------------------------------------------------------

  test "Windows: Setup.exe, then Update.exe apply, the data never moved", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :windows)
    before = fill_data(ctx)
    machine = FakeMachine.start(ctx)

    FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.0.0", files: %{"Zipapp-1.0.0-win-Setup.exe" => "setup"}}
    })

    assert :ok = Installer.install(app("zipapp"), release("1.0.0"), ctx)
    assert %{state: :installed, version: "1.0.0"} = Installer.installed(app("zipapp"), ctx)

    assert :ok = Installer.start(app("zipapp"), ctx)
    assert FakeMachine.running?(machine, "Zipapp.exe")

    FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.1.0", files: %{"ZipappApp-1.1.0-full.nupkg" => "pkg"}}
    })

    assert {:error, {:running, "Zipapp"}} =
             Installer.install(app("zipapp"), release("1.1.0"), ctx)

    assert :ok = Installer.stop(app("zipapp"), ctx)
    assert :ok = Installer.install(app("zipapp"), release("1.1.0"), ctx)
    assert %{version: "1.1.0"} = Installer.installed(app("zipapp"), ctx)

    # Closed through its window, never terminated; started again.
    assert Enum.any?(FakeRunner.calls(), fn {p, args} ->
             p == "powershell" and Enum.any?(args, &(&1 =~ "PostMessageW"))
           end)

    refute Enum.any?(FakeRunner.calls(), fn {p, args} -> p == "taskkill" and "/F" in args end)
    refute FakeMachine.running?(machine, "Zipapp.exe")

    assert_data_untouched(ctx, before)
  end

  test "Windows: an install folder holding a database is refused, and its updater never runs", %{
    tmp: tmp
  } do
    ctx = FakeMachine.context(tmp, :windows)
    FakeMachine.start(ctx)

    FakeGitHub.serve(%{
      "Example/Hallapp" => %{version: "1.0.0", files: %{"Hallapp-Setup.exe" => "setup"}}
    })

    assert :ok = Installer.install(app("hallapp"), release("1.0.0"), ctx)

    # An old install that keeps its data where the uninstaller can reach it.
    root = Path.join(ctx.local_app_data, "HallappApp")
    File.write!(Path.join(root, "hallapp.db"), "somebody's tournament")

    FakeRunner.script(fn
      "tasklist", _args, _opts -> {"INFO: No tasks.
", 0}
      program, args, _opts -> flunk("#{program} #{Enum.join(args, " ")} ran")
    end)

    FakeGitHub.serve(%{
      "Example/Hallapp" => %{version: "1.1.0", files: %{"HallappApp-1.1.0-full.nupkg" => "pkg"}}
    })

    assert {:error, {:install_folder_holds_data, ^root, "hallapp.db"}} =
             Installer.install(app("hallapp"), release("1.1.0"), ctx)

    assert File.read!(Path.join(root, "hallapp.db")) == "somebody's tournament"
  end

  test "Windows: a copy installed for everyone is left to its .msi", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :windows)
    FakeMachine.start(ctx)
    File.mkdir_p!(Path.join([ctx.program_files, "ZipappApp", "current"]))

    assert %{state: :per_machine} = Installer.installed(app("zipapp"), ctx)

    FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.1.0", files: %{"ZipappApp-1.1.0-full.nupkg" => "pkg"}}
    })

    assert {:error, :per_machine} = Installer.install(app("zipapp"), release("1.1.0"), ctx)
  end

  # --- Linux, install script ----------------------------------------------------------

  defp linux_release(version) do
    tar =
      FakeGitHub.tar_gz([
        {"hallapp/VERSION", version <> "\n"},
        {"hallapp/install.sh", "#!/bin/sh\n"},
        {"hallapp/update.sh", "#!/bin/sh\n"},
        {"hallapp/bin/hallapp", "#!/bin/sh\n"}
      ])

    %{version: version, files: %{"hallapp-linux-x86_64.tar.gz" => tar}}
  end

  test "Linux: install.sh, then update.sh --from, then back; /var/lib untouched", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :linux)
    before = fill_data(ctx)
    machine = FakeMachine.start(ctx)

    FakeGitHub.serve(%{"Example/Hallapp" => linux_release("1.0.0")})
    assert :ok = Installer.install(app("hallapp"), release("1.0.0"), ctx)
    assert %{version: "1.0.0"} = Installer.installed(app("hallapp"), ctx)
    assert FakeMachine.running?(machine, "hallapp.service")

    FakeGitHub.serve(%{"Example/Hallapp" => linux_release("1.1.0")})

    assert {:error, {:running, "Hallapp"}} =
             Installer.install(app("hallapp"), release("1.1.0"), ctx)

    assert :ok = Installer.stop(app("hallapp"), ctx)
    assert :ok = Installer.install(app("hallapp"), release("1.1.0"), ctx)
    assert %{version: "1.1.0", previous: "1.0.0"} = Installer.installed(app("hallapp"), ctx)
    assert Enum.any?(FakeRunner.calls(), &match?({"sudo", ["-n", "sh", _, "--from", _]}, &1))

    assert :ok = Installer.rollback(app("hallapp"), ctx)
    assert %{version: "1.0.0"} = Installer.installed(app("hallapp"), ctx)

    assert_data_untouched(ctx, before)
  end

  # --- portable -----------------------------------------------------------------------

  defp portable_release(version) do
    zip =
      FakeGitHub.zip([
        {"zipapp_portable/zipapp.sh", "#!/bin/sh\n"},
        {"zipapp_portable/VERSION", version}
      ])

    %{version: version, files: %{"zipapp_portable_linux_x86_64.zip" => zip}}
  end

  test "portable: versions side by side, one word switched, the data elsewhere and untouched", %{
    tmp: tmp
  } do
    ctx = FakeMachine.context(tmp, :linux)
    before = fill_data(ctx)
    machine = FakeMachine.start(ctx)

    for version <- ["1.0.0", "1.1.0", "1.2.0"] do
      FakeGitHub.serve(%{"Example/Zipapp" => portable_release(version)})
      assert :ok = Installer.install(app("zipapp"), release(version), ctx)

      if version == "1.0.0" do
        assert :ok = Installer.start(app("zipapp"), ctx)

        # Open: the next version waits until it is closed.
        FakeGitHub.serve(%{"Example/Zipapp" => portable_release("1.1.0")})

        assert {:error, {:running, "Zipapp"}} =
                 Installer.install(app("zipapp"), release("1.1.0"), ctx)

        assert :ok = Installer.stop(app("zipapp"), ctx)
      end
    end

    assert %{version: "1.2.0", previous: "1.1.0"} = Installer.installed(app("zipapp"), ctx)
    base = Path.join(ctx.programs, "zipapp")
    refute File.exists?(Path.join(base, "1.0.0"))
    assert {"kill", ["-TERM", "4243"]} in FakeRunner.calls()
    refute FakeMachine.running?(machine, "zipapp.sh")

    assert :ok = Installer.rollback(app("zipapp"), ctx)
    assert %{version: "1.1.0", previous: "1.2.0"} = Installer.installed(app("zipapp"), ctx)

    assert_data_untouched(ctx, before)
  end

  # --- the guard itself ---------------------------------------------------------------

  test "Fs refuses to remove, move into, or replace a data directory or its parent", %{tmp: tmp} do
    for family <- [:windows, :macos, :linux] do
      ctx = FakeMachine.context(tmp, family)
      before = fill_data(ctx)

      for {id, dir} <- Guard.protected(ctx) do
        assert {:error, {:data_dir, ^id, ^dir}} = Fs.rm_rf(dir, ctx)
        assert {:error, {:data_dir, _, _}} = Fs.rm_rf(Path.dirname(dir), ctx)
        assert {:error, {:data_dir, _, _}} = Fs.rename(dir, dir <> ".old", ctx)
        assert {:error, {:data_dir, _, _}} = Fs.write(Path.join(dir, "x"), "x", ctx)
        assert {:error, {:data_dir, _, _}} = Fs.rename(Path.join(tmp, "elsewhere"), dir, ctx)
        # Case and slashes do not get round it where the file system ignores them.
        if family != :linux do
          assert {:error, {:data_dir, _, _}} = Fs.rm_rf(String.upcase(dir), ctx)
        end
      end

      assert snapshot(ctx) == before
    end
  end

  test "a catalogue whose pack id is a data folder is refused when it is read" do
    entry = %{
      "id" => "doomed",
      "name" => "Doomed",
      "repo" => "Example/Doomed",
      "mark" => "alnasl.svg",
      "platforms" => %{
        "windows-x86_64" => %{
          "method" => "velopack",
          "setup" => "Doomed-Setup.exe",
          "package" => "DoomedData-{version}-full.nupkg",
          "pack_id" => "DoomedData",
          "main_exe" => "Doomed.exe",
          "window_class" => "DoomedLauncher"
        }
      },
      "data" => %{"windows" => ["{localappdata}/DoomedData"]}
    }

    assert_raise ArgumentError, ~r/pack id DoomedData is the name of a data folder/, fn ->
      Catalogue.parse!(%{"apps" => [entry]})
    end
  end
end
