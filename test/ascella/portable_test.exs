defmodule Ascella.PortableTest do
  @moduledoc """
  The portable install on Linux, where it goes wrong quietly: Ascella (root)
  starts a program as another user and used to say "started" whatever
  happened, and it kept a pid it would signal without asking whose it had
  become.
  """
  use ExUnit.Case, async: false

  alias Ascella.{Catalogue, FakeMachine, FakeRunner, Installer}

  setup do
    tmp = Path.expand("ascella-portable-#{System.unique_integer([:positive])}", System.tmp_dir!())
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(&FakeRunner.reset/0)

    app = Catalogue.get("zipapp")
    ctx = FakeMachine.context(tmp, :linux)
    base = Path.join(ctx.programs, app.id)
    File.mkdir_p!(Path.join([base, "1.0.0", "zipapp_portable"]))
    File.write!(Path.join([base, "1.0.0", "zipapp_portable", "zipapp.sh"]), "#!/bin/sh\n")
    File.write!(Path.join(base, "current"), "1.0.0\n")

    {:ok, tmp: tmp, app: app, ctx: ctx, base: base}
  end

  # What a script says to the calls it does not care about: yes.
  defp record(parent, fun) do
    FakeRunner.script(fn program, args, opts ->
      send(parent, {:ran, Path.basename(program), args})
      fun.(Path.basename(program), args, opts)
    end)
  end

  describe "starting as another user (ASC-2)" do
    setup %{ctx: ctx} do
      %{ctx: %{ctx | sudo: false, run_as: "hall"}}
    end

    test "the way is made walkable, the log folder is the user's, the log is in it", %{
      app: app,
      ctx: ctx,
      base: base
    } do
      record(self(), fn
        "env", _args, _opts -> {"4243\n", 0}
        _other, _args, _opts -> {"", 0}
      end)

      assert :ok = Installer.start(app, ctx)

      logs = Path.join(base, "logs")
      assert File.dir?(logs)
      assert_received {:ran, "chown", ["--", "hall", ^logs]}
      programs = ctx.programs
      data = Path.dirname(programs)
      assert_received {:ran, "chmod", ["o+x", ^data, ^programs, ^base]}

      assert_received {:ran, "env", words}
      log = Path.join(logs, "zipapp.log")
      assert log in words
      assert "runuser" in words
    end

    test "a program that is gone a moment later did not start, and its log says why", %{
      app: app,
      ctx: ctx,
      base: base
    } do
      File.mkdir_p!(Path.join(base, "logs"))
      File.write!(Path.join([base, "logs", "zipapp.log"]), "line 3: permission denied\n")

      record(self(), fn
        "env", _args, _opts -> {"4243\n", 0}
        "kill", ["-0", "4243"], _opts -> {"", 1}
        _other, _args, _opts -> {"", 0}
      end)

      assert {:error, {:died, "zipapp.sh", tail}} = Installer.start(app, ctx)
      assert tail =~ "permission denied"
      assert AscellaWeb.Words.reason({:died, "zipapp.sh", tail}) =~ "permission denied"
      refute File.exists?(Path.join(base, "pid"))
    end

    test "when the shell could not even open the log, what it said is the error", %{
      app: app,
      ctx: ctx
    } do
      record(self(), fn
        "env", _args, _opts ->
          {"sh: 1: cannot create /x/logs/zipapp.log: Permission denied\n4243\n", 0}

        "kill", ["-0", "4243"], _opts ->
          {"", 1}

        _other, _args, _opts ->
          {"", 0}
      end)

      assert {:error, {:died, _program, tail}} = Installer.start(app, ctx)
      assert tail =~ "Permission denied"
    end

    test "a program that is still there is started", %{app: app, ctx: ctx, base: base} do
      record(self(), fn
        "env", _args, _opts -> {"4243\n", 0}
        _other, _args, _opts -> {"", 0}
      end)

      assert :ok = Installer.start(app, ctx)
      assert File.read!(Path.join(base, "pid")) =~ ~r/\A4243\s*\z/
    end
  end

  describe "the pid file (ASC-3)" do
    # /proc/<pid>/stat as Linux writes it: the name in parentheses (here one
    # with a space and a parenthesis in it), the state, 18 more fields, then
    # field 22, the start time.
    defp proc_stat(ctx, pid, started) do
      dir = Path.join([ctx.root, "proc", pid])
      File.mkdir_p!(dir)
      middle = Enum.join(List.duplicate("0", 18), " ")
      File.write!(Path.join(dir, "stat"), "#{pid} (odd ) name) S #{middle} #{started} 0 0\n")
    end

    defp write_pid(base, text), do: File.write!(Path.join(base, "pid"), text)

    test "the process that was started is the one that is running", %{
      app: app,
      ctx: ctx,
      base: base
    } do
      record(self(), fn _program, _args, _opts -> {"", 0} end)
      proc_stat(ctx, "999", "5000")
      write_pid(base, "999 5000\n")

      assert Installer.running?(app, ctx)
      assert File.exists?(Path.join(base, "pid"))
    end

    test "a pid that now belongs to another process is not running, is not signalled, and the file goes",
         %{app: app, ctx: ctx, base: base} do
      record(self(), fn _program, _args, _opts -> {"", 0} end)
      # The box rebooted; pid 999 is something else, started at another time.
      proc_stat(ctx, "999", "777")
      write_pid(base, "999 5000\n")

      refute Installer.running?(app, ctx)
      refute File.exists?(Path.join(base, "pid"))
      refute_received {:ran, "kill", _args}

      write_pid(base, "999 5000\n")
      assert :ok = Installer.stop(app, ctx)
      refute_received {:ran, "kill", ["-TERM", _pid]}
      refute File.exists?(Path.join(base, "pid"))
    end

    test "a pid with nothing behind it is stale too", %{app: app, ctx: ctx, base: base} do
      record(self(), fn _program, _args, _opts -> {"", 0} end)
      write_pid(base, "4242 5000\n")

      refute Installer.running?(app, ctx)
      refute File.exists?(Path.join(base, "pid"))
    end

    test "stop signals the pid that is ours", %{app: app, ctx: ctx, base: base} do
      record(self(), fn _program, _args, _opts -> {"", 0} end)
      proc_stat(ctx, "999", "5000")
      write_pid(base, "999 5000\n")

      # The fake process never dies, so the wait for it ends in a refusal;
      # what is asserted is that the signal went to the right pid.
      _ = Installer.stop(app, ctx)
      assert_received {:ran, "kill", ["-TERM", "999"]}
    end

    test "a pid file from before the start time was kept is trusted as it always was", %{
      app: app,
      ctx: ctx,
      base: base
    } do
      record(self(), fn _program, _args, _opts -> {"", 0} end)
      write_pid(base, "999\n")

      assert Installer.running?(app, ctx)
    end

    test "a started program's pid file carries the start time", %{app: app, ctx: ctx, base: base} do
      proc_stat(ctx, "4243", "31337")

      record(self(), fn
        "env", _args, _opts -> {"4243\n", 0}
        _other, _args, _opts -> {"", 0}
      end)

      assert :ok = Installer.start(app, ctx)
      assert File.read!(Path.join(base, "pid")) == "4243 31337\n"
    end
  end
end
