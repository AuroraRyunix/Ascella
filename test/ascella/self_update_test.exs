defmodule Ascella.SelfUpdateTest do
  @moduledoc """
  Ascella replacing itself. The decisions are plain functions; the Mac swap
  runs on a temporary folder with fake bundles and a runner that runs
  nothing; the Mac helper, a shell script, is run for real, against fake
  bundles in the same folder and stand-ins for `open`, `curl` and `pgrep`,
  so that its rollback is tested as what it is. Nothing here starts, stops
  or signals a process outside the test's own folder.
  """
  use ExUnit.Case, async: false

  alias Ascella.{FakeGitHub, FakeMachine, FakeRunner, Updates}
  alias Ascella.SelfUpdate.Mac

  setup do
    tmp =
      Path.expand("ascella-selfupdate-#{System.unique_integer([:positive])}", System.tmp_dir!())

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    on_exit(&FakeRunner.reset/0)
    {:ok, tmp: tmp}
  end

  # --- the decisions ----------------------------------------------------------------

  describe "Updates.decide/1" do
    @own %{version: "0.4.0", tag: "v0.4.0", kind: :macos_app}
    defp facts(overrides \\ %{}) do
      Map.merge(
        %{own: @own, current: "0.3.0", busy?: false, kind: :macos_app, writable?: true},
        Map.new(overrides)
      )
    end

    test "a newer release, nothing busy, a writable folder: go" do
      assert {:ok, :macos_app} = Updates.decide(facts())
    end

    test "nothing found, or nothing newer: no" do
      assert {:error, :no_update} = Updates.decide(facts(own: nil))
      assert {:error, :not_newer} = Updates.decide(facts(current: "0.4.0"))
      assert {:error, :not_newer} = Updates.decide(facts(current: "0.10.0"))
    end

    test "busy wins over everything that would otherwise be fine" do
      assert {:error, :busy} = Updates.decide(facts(busy?: true))
      assert {:error, :busy} = Updates.decide(facts(busy?: true, kind: :velopack))
    end

    test "a manual copy cannot be updated from here" do
      assert {:error, :manual} = Updates.decide(facts(kind: :manual))
    end

    test "a Mac app in a folder that cannot be written says where it is" do
      assert {:error, {:not_writable, "/x/Ascella.app"}} =
               Updates.decide(facts(writable?: false, bundle: "/x/Ascella.app"))

      # Windows and Linux do not ask the question.
      assert {:ok, :velopack} = Updates.decide(facts(kind: :velopack, writable?: false))
    end

    test "newer?/2 compares versions, not strings" do
      assert Updates.newer?("0.10.0", "0.9.0")
      refute Updates.newer?("0.9.0", "0.10.0")
      refute Updates.newer?("0.3.0", "0.3.0")
      refute Updates.newer?("nonsense", "0.3.0")
    end
  end

  describe "where the app is" do
    test "bundle_from/1 finds the .app a release root lies in" do
      assert Path.expand("/Applications/Ascella.app") ==
               Mac.bundle_from("/Applications/Ascella.app/Contents/Resources/app")

      assert nil == Mac.bundle_from("/opt/ascella/releases/current")
      assert nil == Mac.bundle_from(nil)
    end

    test "the previous copy is one folder, beside the app", %{tmp: tmp} do
      assert Path.join([tmp, ".ascella-previous", "Ascella.app"]) ==
               Mac.previous_path(Path.join(tmp, "Ascella.app"))
    end

    test "a folder that is not there, or a translocated copy, is not writable", %{tmp: tmp} do
      assert Mac.writable?(Path.join(tmp, "Ascella.app"))
      refute Mac.writable?(Path.join([tmp, "nowhere", "Ascella.app"]))
      refute Mac.writable?("/private/var/folders/x/AppTranslocation/ABC/d/Ascella.app")
    end
  end

  # --- the swap, on a fake machine -----------------------------------------------------

  describe "Mac.apply/3" do
    setup %{tmp: tmp} do
      ctx = FakeMachine.context(tmp, :macos)
      apps = hd(ctx.mac_apps)
      bundle = Path.join(apps, "Ascella.app")
      write_bundle(bundle, "0.3.0", "old")
      status = Path.join(tmp, "status")
      FakeRunner.reset()

      opts = [
        bundle: bundle,
        launcher_pid: "4242",
        port: 4090,
        status_file: status,
        open: "/fake/open",
        curl: "/fake/curl",
        pgrep: "/fake/pgrep",
        seconds: 7,
        tick: 1
      ]

      {:ok, ctx: ctx, bundle: bundle, opts: opts, apps: apps}
    end

    defp write_bundle(path, version, marker) do
      File.mkdir_p!(Path.join(path, "Contents/MacOS"))
      File.write!(Path.join(path, "Contents/Info.plist"), FakeGitHub.plist(version))
      File.write!(Path.join(path, "Contents/MacOS/Ascella"), marker)
    end

    defp release_zip(version, marker) do
      FakeGitHub.zip([
        {"Ascella.app/Contents/Info.plist", FakeGitHub.plist(version)},
        {"Ascella.app/Contents/MacOS/Ascella", marker}
      ])
    end

    defp serve(version, zip, extra \\ []) do
      FakeGitHub.serve(%{
        "teapot-chess/Ascella" =>
          Map.merge(
            %{version: version, files: %{"ascella-macos-aarch64.zip" => zip}},
            Map.new(extra)
          )
      })
    end

    # Ditto unpacks for real (into the temp folder), xattr says what the test
    # says, everything else is recorded and succeeds.
    defp script(parent, opts \\ []) do
      quarantined? = Keyword.get(opts, :quarantined, false)
      helper_status = Keyword.get(opts, :helper_status, 0)

      FakeRunner.script(fn program, args, _opts ->
        send(parent, {:ran, program, args})

        case {Path.basename(program), args} do
          {"ditto", ["-x", "-k", zip, dest]} ->
            {:ok, _} = :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(dest))
            {"", 0}

          {"xattr", ["-p" | _]} ->
            if quarantined?, do: {"0081;5f;Safari;", 0}, else: {"", 1}

          {"env", _} ->
            {"", helper_status}

          _other ->
            {"", 0}
        end
      end)
    end

    test "downloads, swaps, keeps exactly the previous app, starts the helper, asks to quit", c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      script(self())

      assert :ok = Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "new"
      previous = Mac.previous_path(c.bundle)
      assert File.read!(Path.join(previous, "Contents/MacOS/Ascella")) == "old"
      refute File.exists?(Path.join(c.apps, ".ascella-staging-ascella"))

      # The helper: a clean environment, /bin/sh -c, the script as one
      # argument, every other value an argument of its own.
      assert_received {:ran, "/usr/bin/env", ["-i" | words]}
      assert [_path | _] = Enum.take_while(words, &(&1 =~ ~r/\A[A-Z_]+=/))
      refute Enum.any?(words, &String.starts_with?(&1, ["PORT=", "ASCELLA_", "RELEASE_"]))

      assert [
               "/bin/sh",
               "-c",
               script,
               "sh",
               "4242",
               bundle,
               ^previous,
               "4090",
               status,
               "/fake/open",
               "/fake/curl",
               "/fake/pgrep",
               "7",
               "0.4.0",
               "1"
             ] =
               Enum.drop_while(words, &(&1 =~ ~r/\A[A-Z_]+=/))

      assert script == Mac.helper_script()
      assert bundle == c.bundle
      assert status == c.opts[:status_file]

      # Then, and only then, the quit.
      assert_received {:ran, "kill", ["-TERM", "4242"]}
    end

    test "a second update replaces the kept copy, never adds a second one", c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      script(self())
      assert :ok = Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      serve("0.5.0", release_zip("0.5.0", "newer"))
      assert :ok = Mac.apply(%{version: "0.5.0", tag: "v0.5.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "newer"

      assert File.read!(Path.join(Mac.previous_path(c.bundle), "Contents/MacOS/Ascella")) ==
               "new"

      assert [".ascella-previous", "Ascella.app"] == c.apps |> File.ls!() |> Enum.sort()
    end

    test "a quarantine mark that is somehow there is removed from the new app", c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      script(self(), quarantined: true)

      assert :ok = Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      fresh = Path.join([c.apps, ".ascella-staging-ascella", "Ascella.app"])
      assert_received {:ran, "xattr", ["-p", "com.apple.quarantine", ^fresh]}
      assert_received {:ran, "xattr", ["-dr", "com.apple.quarantine", ^fresh]}
    end

    test "no mark, no xattr -d", c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      script(self())
      assert :ok = Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)
      refute_received {:ran, "xattr", ["-dr" | _]}
    end

    test "a folder that cannot be written: nothing is downloaded, nothing changes", c do
      script(self())
      bundle = Path.join([c.tmp, "nowhere", "Ascella.app"])

      assert {:error, {:not_writable, ^bundle}} =
               Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, bundle: bundle)

      refute_received {:ran, _, _}
    end

    test "a download that does not match its checksum changes nothing", c do
      serve("0.4.0", release_zip("0.4.0", "new"),
        sums: String.duplicate("0", 64) <> "  ascella-macos-aarch64.zip\n"
      )

      script(self())

      assert {:error, {:checksum_mismatch, _, _}} =
               Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "old"
      refute File.exists?(Mac.previous_path(c.bundle))
      refute_received {:ran, "kill", _}
    end

    test "a release without checksums is not used", c do
      serve("0.4.0", release_zip("0.4.0", "new"), sums: :none)
      script(self())

      assert {:error, :no_checksums} =
               Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "old"
    end

    test "a zip holding another version than its release says changes nothing", c do
      serve("0.4.0", release_zip("0.9.9", "new"))
      script(self())

      assert {:error, {:wrong_version, "0.9.9", "0.4.0"}} =
               Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "old"
      refute File.exists?(Mac.previous_path(c.bundle))
    end

    test "when the helper cannot be started the old app is put back and nobody is asked to quit",
         c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      script(self(), helper_status: 1)

      assert {:error, {:exit, "env", 1, _}} =
               Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, c.opts)

      assert File.read!(Path.join(c.bundle, "Contents/MacOS/Ascella")) == "old"
      refute_received {:ran, "kill", _}
    end

    test "without a launcher pid in the environment, pgrep is asked, before the swap", c do
      serve("0.4.0", release_zip("0.4.0", "new"))
      parent = self()

      FakeRunner.script(fn program, args, _opts ->
        send(parent, {:ran, program, args})

        case {Path.basename(program), args} do
          {"pgrep", _} ->
            {"31337\n", 0}

          {"ditto", ["-x", "-k", zip, dest]} ->
            {:ok, _} = :zip.extract(String.to_charlist(zip), cwd: String.to_charlist(dest))
            {"", 0}

          {"xattr", _} ->
            {"", 1}

          _ ->
            {"", 0}
        end
      end)

      System.delete_env("ASCELLA_LAUNCHER_PID")
      opts = Keyword.delete(c.opts, :launcher_pid)
      assert :ok = Mac.apply(%{version: "0.4.0", tag: "v0.4.0"}, c.ctx, opts)
      assert_received {:ran, "kill", ["-TERM", "31337"]}
    end
  end

  # --- the helper, for real, in the temp folder ------------------------------------------

  describe "the helper script" do
    @describetag :shell

    setup %{tmp: tmp} do
      sh = System.find_executable("sh")
      if is_nil(sh), do: flunk("no sh on this machine")

      bundle = Path.join(tmp, "Applications/Ascella.app")
      previous = Mac.previous_path(bundle)
      File.mkdir_p!(bundle)
      File.mkdir_p!(previous)
      File.write!(Path.join(bundle, "who"), "new")
      File.write!(Path.join(previous, "who"), "old")

      opened = Path.join(tmp, "opened")
      answer = Path.join(tmp, "answer")
      status = Path.join(tmp, "status")

      fake(tmp, "open", "echo \"$1 $(cat '#{bundle}/who' 2>/dev/null)\" >> '#{opened}'
")
      fake(tmp, "curl", "[ -e '#{answer}' ]
")
      fake(tmp, "pgrep", "exit 1\n")

      {:ok,
       sh: sh, bundle: bundle, previous: previous, opened: opened, answer: answer, status: status}
    end

    defp fake(tmp, name, body) do
      path = Path.join(tmp, "fake-" <> name)
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      path
    end

    defp run_helper(c, seconds) do
      # A pid that is not there, so there is nothing to wait for.
      args = [
        "-c",
        Mac.helper_script(),
        "sh",
        "4194999",
        c.bundle,
        c.previous,
        "4090",
        c.status,
        Path.join(c.tmp, "fake-open"),
        Path.join(c.tmp, "fake-curl"),
        Path.join(c.tmp, "fake-pgrep"),
        to_string(seconds),
        "0.4.0",
        "0.1"
      ]

      assert {_, 0} = System.cmd(c.sh, args, stderr_to_stdout: true)
    end

    defp wait_for(file) do
      deadline = System.monotonic_time(:millisecond) + 15_000

      Stream.repeatedly(fn ->
        receive do
        after
          50 -> File.read(file)
        end
      end)
      |> Enum.find(fn
        {:ok, text} when text != "" -> true
        _missing -> System.monotonic_time(:millisecond) > deadline
      end)
      |> case do
        {:ok, text} -> String.trim(text)
        _timeout -> flunk("the helper never wrote #{file}")
      end
    end

    test "the new app answers: it is opened once, and stays", c do
      File.write!(c.answer, "")
      run_helper(c, 5)

      assert wait_for(c.status) == "ok 0.4.0"
      assert File.read!(c.opened) == "#{c.bundle} new\n"
      assert File.read!(Path.join(c.bundle, "who")) == "new"
      assert File.read!(Path.join(c.previous, "who")) == "old"
    end

    test "the new app does not answer: the previous one is put back and opened", c do
      run_helper(c, 2)

      assert wait_for(c.status) == "rolled-back 0.4.0"
      assert File.read!(Path.join(c.bundle, "who")) == "old"
      refute File.exists?(c.previous)
      refute File.exists?(c.bundle <> ".failed")
      # Opened twice: the new one, which did not answer, then the old one.
      assert File.read!(c.opened) == "#{c.bundle} new\n#{c.bundle} old\n"
    end

    test "the script is plain sh: it parses", c do
      assert {_, 0} = System.cmd(c.sh, ["-n", "-c", Mac.helper_script()], stderr_to_stdout: true)
    end
  end
end
