defmodule Ascella.CleanStartTest do
  @moduledoc """
  A program Ascella starts must not be told, by inheritance, that it is
  Ascella: Arkab once read PORT=4090, found Ascella on it, decided it was
  already running, and left. The fake runner hands the test the exact argv.
  """
  use ExUnit.Case, async: false

  alias Ascella.{CleanStart, Catalogue, FakeMachine, FakeRunner, Installer}

  @names ~w(HOME USER LOGNAME LANG LC_ALL LC_TIME DISPLAY WAYLAND_DISPLAY XAUTHORITY XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS PORT ASCELLA_DATA RELEASE_ROOT)

  setup do
    tmp = Path.expand("ascella-env-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)

    saved = Map.new(@names, &{&1, System.get_env(&1)})

    for {name, value} <-
          [
            {"HOME", "/home/me"},
            {"USER", "me"},
            {"LOGNAME", "me"},
            {"LANG", "nl_BE.UTF-8"},
            {"LC_ALL", nil},
            {"LC_TIME", "nl_BE.UTF-8"},
            {"DISPLAY", ":0"},
            {"WAYLAND_DISPLAY", nil},
            {"XAUTHORITY", nil},
            {"XDG_RUNTIME_DIR", "/run/user/1000"},
            {"DBUS_SESSION_BUS_ADDRESS", nil},
            {"PORT", "4090"},
            {"ASCELLA_DATA", "/somewhere"},
            {"RELEASE_ROOT", "/somewhere/else"}
          ] do
      if value, do: System.put_env(name, value), else: System.delete_env(name)
    end

    on_exit(fn ->
      for {name, value} <- saved,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(tmp)
      FakeRunner.reset()
    end)

    {:ok, tmp: tmp}
  end

  test "the allowlist: the home, the locale, a system PATH; nothing of Ascella's" do
    assert {"/usr/bin/env",
            [
              "-i",
              "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
              "HOME=/home/me",
              "USER=me",
              "LOGNAME=me",
              "LANG=nl_BE.UTF-8",
              "LC_TIME=nl_BE.UTF-8",
              "/usr/bin/open",
              "/Applications/Arkab.app"
            ]} = CleanStart.command(:macos, "/usr/bin/open", ["/Applications/Arkab.app"])
  end

  test "on Linux the display session comes along when it is set" do
    {"/usr/bin/env", ["-i" | words]} = CleanStart.command(:linux, "sh", ["-c", "x"])

    assert "DISPLAY=:0" in words
    assert "XDG_RUNTIME_DIR=/run/user/1000" in words
    refute Enum.any?(words, &String.starts_with?(&1, "WAYLAND_DISPLAY"))
    refute Enum.any?(words, &(&1 =~ ~r/\A(PORT|ASCELLA_|RELEASE_)/))
  end

  test "starting a Mac app runs open under env -i, exactly", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :macos)
    File.mkdir_p!(Path.join(hd(ctx.mac_apps), "Zipapp.app"))
    parent = self()

    FakeRunner.script(fn program, args, _opts ->
      send(parent, {:ran, program, args})
      {"", 0}
    end)

    assert :ok = Installer.start(Catalogue.get("zipapp"), ctx)
    bundle = Path.join(hd(ctx.mac_apps), "Zipapp.app")

    assert_received {:ran, "/usr/bin/env",
                     [
                       "-i",
                       "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                       "HOME=/home/me",
                       "USER=me",
                       "LOGNAME=me",
                       "LANG=nl_BE.UTF-8",
                       "LC_TIME=nl_BE.UTF-8",
                       "/usr/bin/open",
                       ^bundle
                     ]}
  end

  test "starting a portable app on Linux runs the launch under env -i", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :linux)
    app = Catalogue.get("zipapp")
    base = Path.join(ctx.programs, app.id)
    File.mkdir_p!(Path.join([base, "1.0.0", "zipapp_portable"]))
    File.write!(Path.join([base, "1.0.0", "zipapp_portable", "zipapp.sh"]), "#!/bin/sh\n")
    File.write!(Path.join(base, "current"), "1.0.0\n")
    parent = self()

    FakeRunner.script(fn program, args, _opts ->
      send(parent, {:ran, program, args})
      {"4243\n", 0}
    end)

    assert :ok = Installer.start(app, ctx)
    assert_received {:ran, "/usr/bin/env", ["-i", "PATH=" <> _ | rest]}
    assert "DISPLAY=:0" in rest
    refute Enum.any?(rest, &(&1 =~ ~r/\A(PORT|ASCELLA_|RELEASE_)/))
    assert ["sh", "-c", _nohup, script, _log] = Enum.drop_while(rest, &(&1 =~ "="))
    assert script =~ "zipapp.sh"
  end

  test "unset/1 names Ascella's own variables, whatever their case, and nothing else" do
    env = %{
      "PORT" => "4090",
      "ASCELLA_DATA" => "/x",
      "RELEASE_ROOT" => "/y",
      "ReLeAsE_TmP" => "/z",
      "BINDIR" => "/erts",
      "ERL_AFLAGS" => "+B",
      "SystemRoot" => "C:\\Windows",
      "PATH" => "/bin",
      "TEMP" => "/tmp",
      "PORTABLE_MODE" => "1"
    }

    unset = env |> CleanStart.unset() |> Enum.sort()

    assert unset ==
             Enum.sort([
               {"ASCELLA_DATA", nil},
               {"BINDIR", nil},
               {"ERL_AFLAGS", nil},
               {"PORT", nil},
               {"RELEASE_ROOT", nil},
               {"ReLeAsE_TmP", nil}
             ])
  end

  test "Windows: the first install runs Setup.exe without Ascella's own variables", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :windows)
    parent = self()

    FakeRunner.script(fn program, args, opts ->
      send(parent, {:ran, Path.basename(program), args, opts})
      {"", 0}
    end)

    Ascella.FakeGitHub.serve(%{
      "Example/Zipapp" => %{version: "1.0.0", files: %{"Zipapp-1.0.0-win-Setup.exe" => "setup"}}
    })

    release = %{version: "1.0.0", tag: "v1.0.0"}
    assert :ok = Installer.install(Catalogue.get("zipapp"), release, ctx)

    assert_received {:ran, "Zipapp-1.0.0-win-Setup.exe", ["--silent"], opts}
    env = Keyword.fetch!(opts, :env)
    assert {"PORT", nil} in env
    assert {"ASCELLA_DATA", nil} in env
    assert {"RELEASE_ROOT", nil} in env
    refute Enum.any?(env, fn {_name, value} -> value != nil end)
  end
end
