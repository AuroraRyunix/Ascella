defmodule Ascella.CleanEnvTest do
  @moduledoc """
  A program Ascella starts must not be told, by inheritance, that it is
  Ascella: Arkab once read PORT=4090, found Ascella on it, decided it was
  already running, and left. The fake runner hands the test the options each
  start was given.
  """
  use ExUnit.Case, async: false

  alias Ascella.{CleanEnv, Catalogue, FakeMachine, FakeRunner, Installer}

  setup do
    tmp = Path.expand("ascella-env-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(&FakeRunner.reset/0)
    {:ok, tmp: tmp}
  end

  test "unsets: the fixed names, plus whatever with a known prefix is actually set" do
    env = %{
      "PORT" => "4090",
      "RELEASE_NODE" => "x",
      "ERL_LIBS" => "y",
      "HOME" => "/h",
      "PATH" => "/bin",
      "ASCELLA_DATA" => "d"
    }

    unset = CleanEnv.unsets(env)

    for name <-
          ~w(PORT SECRET_KEY_BASE RELEASE_NODE ERL_LIBS ASCELLA_DATA BINDIR ROOTDIR EMU PROGNAME),
        do: assert({name, nil} in unset)

    refute List.keymember?(unset, "HOME", 0)
    refute List.keymember?(unset, "PATH", 0)
    assert Enum.all?(unset, fn {_name, value} -> value == nil end)
  end

  test "starting a Mac app passes the unsets to open", %{tmp: tmp} do
    ctx = FakeMachine.context(tmp, :macos)
    File.mkdir_p!(Path.join(ctx.mac_apps |> hd(), "Zipapp.app"))
    parent = self()

    FakeRunner.script(fn program, args, opts ->
      send(parent, {:ran, program, args, opts})
      {"", 0}
    end)

    assert :ok = Installer.start(Catalogue.get("zipapp"), ctx)
    assert_received {:ran, "open", [_bundle], opts}
    assert {"PORT", nil} in opts[:env]
    assert {"ASCELLA_DATA", nil} in opts[:env]
  end

  test "starting a portable app on Linux passes the unsets", %{tmp: tmp} do
    ctx = %{FakeMachine.context(tmp, :linux) | sudo: true}
    app = Catalogue.get("zipapp")
    base = Path.join(ctx.programs, app.id)
    File.mkdir_p!(Path.join([base, "1.0.0", "zipapp_portable"]))
    File.write!(Path.join([base, "1.0.0", "zipapp_portable", "zipapp.sh"]), "#!/bin/sh\n")
    File.write!(Path.join(base, "current"), "1.0.0\n")
    parent = self()

    FakeRunner.script(fn program, args, opts ->
      send(parent, {:ran, program, args, opts})
      {"4243\n", 0}
    end)

    assert :ok = Installer.start(app, ctx)
    assert_received {:ran, "sh", _args, opts}
    assert {"PORT", nil} in opts[:env]

    assert {"RELEASE_ROOT", nil} in opts[:env]
  end
end
