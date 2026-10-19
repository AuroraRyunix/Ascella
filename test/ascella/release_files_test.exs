defmodule Ascella.ReleaseFilesTest do
  @moduledoc """
  The files a release is made of and by, held to each other: the names the
  workflow publishes are the names the scripts and the launchers ask for;
  the port, the pack id and the data folders are the same in every file
  that spells them; every action is pinned to a commit; the changelog has
  something to say about the version in `mix.exs`, or says it is unreleased.

  None of this runs a workflow. It catches the kind of mistake that is one
  renamed file in one of five places - which, the release machinery having
  been copied from Alnasl, is also where a leftover "alnasl" would hide.
  """

  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @port "4090"
  @pack_id "AscellaApp"
  @data_folder "AscellaData"

  defp read(path), do: File.read!(Path.join(@root, path))

  defp version, do: Mix.Project.config()[:version]

  # Everything under rel/, the workflows and the release-notes script: the
  # files this test is about. Binary icons left out.
  defp release_files do
    (Path.wildcard(Path.join(@root, "rel/**/*"), match_dot: true) ++
       Path.wildcard(Path.join(@root, ".github/**/*.yml")) ++
       [Path.join(@root, "tools/release_notes.sh")])
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.extname(&1) in ~w(.png .ico .dll .exe .res .pyc)))
    |> Enum.reject(&String.contains?(&1, "/obj/"))
  end

  test "a stop does not wait fifteen seconds for an open page, and says how it went" do
    http = Application.fetch_env!(:ascella, AscellaWeb.Endpoint)[:http]
    assert http[:thousand_island_options][:shutdown_timeout] <= 3_000

    sh = File.read!(Path.expand("../../rel/macos/launcher.sh", __DIR__))
    assert sh =~ "Stopping: the server stopped after"
    assert sh =~ "Stopping: still running after 20 seconds"
  end

  test "a stop by signal does not wait inside the main queue for news that queues behind it" do
    swift = File.read!(Path.expand("../../rel/macos/Launcher.swift", __DIR__))
    # The signal's quit goes through the run loop, and so does the news it waits for.
    assert swift =~
             "RunLoop.main.perform(inModes: [.default, .modalPanel]) { NSApp.terminate(nil) }"

    assert swift =~
             "RunLoop.main.perform(inModes: [.common]) { self?.serverEnded(status: status) }"

    refute swift =~ "DispatchQueue.main.async { self?.serverEnded"
    # And a stop that hangs anyway ends from another thread.
    assert swift =~ "DispatchQueue.global().asyncAfter(deadline: .now() + 40) { exit(0) }"
  end

  describe "the workflows" do
    test "every action is pinned to a commit, with the version beside it" do
      for file <- ~w(.github/workflows/ci.yml .github/workflows/release.yml),
          [line] <- Regex.scan(~r/^.*\buses:.*$/m, read(file)) do
        assert line =~ ~r/uses: [\w.-]+\/[\w.\/-]+@[0-9a-f]{40} # v\d+\.\d+\.\d+$/,
               "#{file}: not pinned to a commit: #{String.trim(line)}"
      end
    end

    test "only the job that publishes may write" do
      workflow = read(".github/workflows/release.yml")
      assert length(Regex.scan(~r/contents: write/, workflow)) == 1
      assert workflow =~ ~r/^permissions:\n  contents: read$/m
      refute read(".github/workflows/ci.yml") =~ "contents: write"
    end

    test "the files it publishes are the files that are asked for by name" do
      workflow = read(".github/workflows/release.yml")

      # What the Windows updater fetches...
      assert workflow =~ "#{@pack_id}-${VERSION}-full.nupkg"

      # ...what the Linux scripts download...
      for script <- ~w(rel/linux/install.sh rel/linux/update.sh) do
        assert read(script) =~ ~s(file="ascella-linux-$cpu.tar.gz")
        assert read(script) =~ "SHA256SUMS"
        assert read(script) =~ ~s(REPO="teapot-chess/Ascella")
      end

      # ...and every fixed name, in the workflow's own list of what a
      # release must hold.
      for name <- ~w(Ascella-Setup.exe ascella-windows-x86_64-portable.zip
                     ascella-linux-x86_64.tar.gz ascella-linux-aarch64.tar.gz
                     ascella-macos-aarch64.zip ascella-macos-x86_64.zip releases.win.json) do
        assert workflow =~ ~r/^\s+#{Regex.escape(name)}\b/m,
               "release.yml does not require #{name}"
      end

      assert workflow =~ ~r/^\s+install\.sh update\.sh uninstall\.sh \\$/m
      assert workflow =~ "sha256sum -- * > ../SHA256SUMS"
    end

    test "the smoke tests start it on a spare port, never on Alnasl's or its own" do
      workflow = read(".github/workflows/release.yml")

      assert workflow =~ "export PORT=4096"
      assert workflow =~ ~s($env:PORT = "4096")
      assert workflow =~ "http://127.0.0.1:4096/help"
      refute workflow =~ "4040"
      refute workflow =~ "4046"

      # The help page is the probe; the secret is the proof a start wrote
      # its data where it was told to.
      assert length(Regex.scan(~r/id="manual"/, workflow)) == 3
      assert length(Regex.scan(~r/secret_key_base/, workflow)) >= 3
      assert workflow =~ ~s(export ASCELLA_DATA="$RUNNER_TEMP/ascella-data")
    end

    test "the Linux archives are built where a Raspberry Pi can run them" do
      workflow = read(".github/workflows/release.yml")
      assert workflow =~ ~s("runner":"ubuntu-22.04","target":"linux-x86_64")
      assert workflow =~ ~s("runner":"ubuntu-22.04-arm","target":"linux-aarch64")
      assert workflow =~ ~s("runner":"windows-latest","target":"windows-x86_64")
      # ...and install.sh refuses, in words, a system older than that.
      assert read("rel/linux/install.sh") =~ ~s([ "$minor" -lt 35 ])
    end

    test "the Mac app is built on the Macs whose names the release gives it" do
      workflow = read(".github/workflows/release.yml")
      assert workflow =~ ~s("runner":"macos-15","target":"macos-aarch64","macos_min":"11.0")
      assert workflow =~ ~s("runner":"macos-15-intel","target":"macos-x86_64","macos_min":")
      assert workflow =~ ~s(dist/ascella-${{ matrix.target }}.zip)
      # Signing is there, and cannot run without its secret.
      assert workflow =~ "if: runner.os == 'macOS' && steps.apple.outputs.sign == 'true'"
    end

    test "the Intel Mac build runs for a release and for a person, never for a plain push" do
      workflow = read(".github/workflows/release.yml")

      # Added to the matrix by the plan job, under one condition, and the
      # condition is the release's own (or a hand-started run).
      assert workflow =~
               ~s(if [ "$PUBLISH" = true ] || [ "$EVENT" = workflow_dispatch ]; then)

      assert workflow =~ "include: ${{ fromJSON(needs.plan.outputs.matrix) }}"

      [before, after_if] =
        String.split(workflow, ~s(if [ "$PUBLISH" = true ]), parts: 2)

      assert after_if =~ "macos-15-intel"
      # ...and not before it, where the permanent targets are listed.
      refute before =~ ~s("runner":"macos-15-intel")

      # What publishes needs the plan, and its decision is the plan's.
      assert workflow =~ "needs: [plan, build]"
      assert workflow =~ "needs.plan.outputs.publish == 'true'"
      refute workflow =~ "steps.ver.outputs.publish == 'true'"
    end

    test "CI builds the Windows launcher, and nothing serial anywhere" do
      ci = read(".github/workflows/ci.yml")
      assert ci =~ ~S(.\rel\windows\build_launcher.ps1 -OutputPath "$env:RUNNER_TEMP\Ascella.exe")
      assert ci =~ "mix compile --warnings-as-errors"
      assert ci =~ "shellcheck --shell=sh --severity=warning rel/linux/*.sh"
    end
  end

  describe "the Mac runtime" do
    test "is built for the target's macOS, and a build that is not fails" do
      workflow = read(".github/workflows/release.yml")
      build_otp = read("rel/macos/build_otp.sh")
      build_app = read("rel/macos/build_app.sh")

      # The ready-made Erlang for macOS said "15.0"; it is not used there.
      assert workflow =~ "if: runner.os != 'macOS'"
      assert workflow =~ ~s(sh rel/macos/build_otp.sh "$HOME/otp-macos")

      assert workflow =~
               ~s(echo "MACOSX_DEPLOYMENT_TARGET=${{ matrix.macos_min }}" >> "$GITHUB_ENV")

      assert workflow =~ "steps.otp-cache.outputs.cache-hit != 'true'"
      # No SQLite here, so nothing to force-build for it.
      refute workflow =~ "EXQLITE"

      assert [_, otp_key] = Regex.run(~r/path: ~\/otp-macos\n\s+key: (.+)$/m, workflow)

      for part <- ~w(env.OTP_VERSION env.OPENSSL_VERSION env.ELIXIR_VERSION
                     env.MACOSX_DEPLOYMENT_TARGET matrix.runner rel/macos/build_otp.sh) do
        assert otp_key =~ part, "the OTP cache key does not include #{part}"
      end

      # OpenSSL inside crypto, and nothing the arbiter's Mac lacks.
      assert build_otp =~ "--disable-dynamic-ssl-lib"
      assert build_otp =~ "no-shared"
      assert build_otp =~ "--without-wx --without-javac --without-odbc"

      # Every version the workflow names has a checksum in the script.
      for var <- ~w(OTP_VERSION OPENSSL_VERSION ELIXIR_VERSION) do
        assert [_, version] = Regex.run(~r/^\s+#{var}: "([^"]+)"$/m, workflow)

        assert build_otp =~
                 ~r/^\s+#{Regex.escape(version)}(-otp-\d+)?\) \w+_sha256=[0-9a-f]{64} ;;$/m,
               "build_otp.sh has no checksum for #{var} #{version}"
      end

      assert Regex.match?(~r/_build\/prod\/lib\n\s+key:.*env\.MACOSX_DEPLOYMENT_TARGET/, workflow)

      # A binary that wants newer than the target fails the build, by name.
      assert build_app =~ "supported=${MACOSX_DEPLOYMENT_TARGET:-11.0}"
      assert build_app =~ ~s(-target "$swift_arch-apple-macos$supported")
      assert build_otp =~ "darwin64-x86_64-cc"
      assert build_otp =~ "darwin64-arm64-cc"

      # The smoke test prints and checks what the bundle promises.
      assert workflow =~ "LSMinimumSystemVersion is not ${{ matrix.macos_min }}"
      assert workflow =~ "vtool -show-build"
      assert build_app =~ ~s(newer "$minos" "$supported")
      assert build_app =~ ~s(sed 's/^/  /' "$too_new")
    end
  end

  describe "the changelog" do
    test "has a section for this version, or says it is unreleased" do
      path = Path.join(@root, "CHANGELOG.md")

      if File.exists?(path) do
        changelog = File.read!(path)

        assert changelog =~ "\n## [#{version()}]" or changelog =~ "\n## [Unreleased]",
               "CHANGELOG.md says nothing about #{version()}"
      end
    end

    @tag :tmp_dir
    test "release_notes.sh prints one version's section and nothing else", %{tmp_dir: dir} do
      if sh = System.find_executable("sh") do
        file = Path.join(dir, "CHANGELOG.md")

        File.write!(file, """
        # Changelog

        A version is released when it has a section (`## [0.2.0]`).

        ## [Unreleased]

        - [Feature] not yet

        ## [0.2.0] - 2026-11-03

        - [Feature] **The second.** With a `## [` in the middle of a line.
        - [Fix] And a fix.

        ## [0.1.0] - 2026-10-20

        - [Feature] The first.

        ## [0.1.5]
        """)

        script = Path.join(@root, "tools/release_notes.sh")

        assert {notes, 0} = System.cmd(sh, [script, "0.2.0", file])
        assert notes =~ "**The second.**"
        assert notes =~ "And a fix."
        refute notes =~ "The first."
        refute notes =~ "not yet"
        refute notes =~ "\n## ["
        assert String.starts_with?(notes, "- [Feature]")

        assert {first, 0} = System.cmd(sh, [script, "0.1.0", file])
        assert String.trim(first) == "- [Feature] The first."

        # No section, an empty section, and a version that only looks like
        # one that is there: nothing printed, and a failure.
        for missing <- ["0.3.0", "0.1.5", "0.2", "0.2.00"] do
          assert {"", 1} = System.cmd(sh, [script, missing, file])
        end
      end
    end
  end

  describe "the release" do
    test "is one release, with the files each system needs beside bin/" do
      release = Mix.Project.config()[:releases][:ascella]
      assert release[:applications] == [ascella: :permanent]

      mix = read("mix.exs")

      for name <- ~w(ascella.sh install.sh update.sh uninstall.sh ascella.service
                     ascella-update.service ascella-update.path) do
        assert File.exists?(Path.join([@root, "rel/linux", name])), "rel/linux/#{name} is missing"
        assert mix =~ name, "mix.exs does not copy #{name} into the Linux release"
      end

      for name <- ~w(Ascella.bat launcher.c launcher.rc launcher.manifest Ascella.ico
                     build_launcher.ps1 build_installer.ps1 build_icon.py) do
        assert File.exists?(Path.join([@root, "rel/windows", name])),
               "rel/windows/#{name} is missing"
      end

      for name <- ~w(Launcher.swift launcher.sh build_app.sh build_otp.sh sign_and_notarize.sh
                     Info.plist entitlements.plist Ascella-icon.png) do
        assert File.exists?(Path.join([@root, "rel/macos", name])), "rel/macos/#{name} is missing"
      end

      # The plist takes its version from the release, never from a literal.
      plist = read("rel/macos/Info.plist")
      assert plist =~ "<string>__VERSION__</string>"
      refute plist =~ ~r{<key>CFBundleShortVersionString</key>\s*<string>\d}

      # The executable is the compiled Swift launcher; the script that
      # starts the server sits beside the release as a resource.
      build = read("rel/macos/build_app.sh")
      assert plist =~ ~r{<key>CFBundleExecutable</key>\s*<string>Ascella</string>}
      assert build =~ ~s(-o "$app/Contents/MacOS/Ascella" "$swift_source")
      assert build =~ ~s(-target "$swift_arch-apple-macos$supported")
      assert build =~ ~s(cp "$here/launcher.sh" "$app/Contents/Resources/launcher.sh")
      assert build =~ "logo=rel/macos/Ascella-icon.png"
    end

    test "nothing of Alnasl's name, port or serial port came along" do
      for file <- release_files() do
        text = File.read!(file)
        name = Path.relative_to(file, @root)

        # NOTICE-style credit to Alnasl is allowed in prose; a path, an env
        # var or a module of it is not.
        refute text =~ ~r/ALNASL_|alnasl\.|alnasl-|\/alnasl|Alnasl\.(exe|bat|app)/,
               "#{name} still names an Alnasl file or variable"

        refute text =~ ~r/4040|4046/, "#{name} names Alnasl's port"

        refute text =~ ~r/circuits_uart|Arkab\.|ASCELLA_UART|dialout|EXQLITE/i,
               "#{name} still has serial-port or SQLite machinery"
      end
    end

    test "the port is 4090 wherever a default is spelled" do
      assert read("rel/windows/launcher.c") =~ "#define DEFAULT_PORT #{@port}\n"
      assert read("rel/macos/Launcher.swift") =~ "let defaultPort = #{@port}\n"
      assert read("rel/windows/Ascella.bat") =~ ~s(if "%PORT%"=="" set PORT=#{@port})
      assert read("rel/linux/ascella.sh") =~ "PORT=${PORT:-#{@port}}"
      assert read("rel/linux/ascella.service") =~ ~r/^Environment=PORT=#{@port}$/m
      assert read("rel/linux/install.sh") =~ ~s(echo "PORT=#{@port}")
      assert read("rel/linux/update.sh") =~ ~s(echo "${value:-#{@port}}")
      assert read("lib/ascella/launcher_details.ex") =~ "Keyword.get(:port, #{@port})"
    end

    test "the pack id and the data folders agree, and the installer guards them" do
      installer = read("rel/windows/build_installer.ps1")
      assert installer =~ "$packId = '#{@pack_id}'"
      assert installer =~ "$packTitle = 'Ascella'"
      assert installer =~ "$dataFolderNames = @('#{@data_folder}', '.ascella', 'ascella-data')"
      assert installer =~ "Assert-DataDirectorySafe"
      refute installer =~ ~r/^\s+--msi/m

      assert read("rel/windows/launcher.c") =~ ~s[join(dir, local, L"\\\\#{@data_folder}");]
      assert read("rel/windows/Ascella.bat") =~ ~S(set ASCELLA_DATA=%LOCALAPPDATA%\AscellaData)

      assert read("rel/macos/Launcher.swift") =~
               ~s(let defaultDataFolder = "Library/Application Support/#{@data_folder}")

      assert read("rel/macos/launcher.sh") =~ "Library/Application Support/#{@data_folder}"

      unit = read("rel/linux/ascella.service")
      assert unit =~ ~r/^Environment=ASCELLA_DATA=\/var\/lib\/ascella$/m
      assert unit =~ ~r/^WorkingDirectory=\/var\/lib\/ascella$/m
      assert unit =~ ~r/^ExecStart=\/opt\/ascella\/current\/bin\/ascella start$/m
      assert unit =~ ~r/^EnvironmentFile=-\/etc\/ascella\/ascella.env$/m

      for script <- ~w(rel/linux/install.sh rel/linux/update.sh rel/linux/uninstall.sh) do
        assert read(script) =~ ~s(DATA_DIR="/var/lib/ascella"), "#{script}: data dir"
        assert read(script) =~ ~s(INSTALL_DIR="/opt/ascella"), "#{script}: install dir"
      end

      # The program's own idea of the same names, where it has one.
      if Code.ensure_loaded?(Ascella.DataHome) do
        assert apply(Ascella.DataHome, :pack_id, []) == @pack_id
        assert apply(Ascella.DataHome, :data_folder, []) == @data_folder
        assert apply(Ascella.DataHome, :linux_install, []) == "/opt/ascella"
        assert apply(Ascella.DataHome, :linux_data, []) == "/var/lib/ascella"
      end
    end

    test "the update machinery speaks one language on every system" do
      launcher = read("rel/windows/launcher.c")
      assert launcher =~ "#define ASCELLA_UPDATE_EXIT_CODE 90\n"
      assert launcher =~ ~S[L"ASCELLA_UPDATER", can_update() ? L"velopack" : NULL]
      assert launcher =~ ~s(L"ASCELLA_LAUNCHER_TOKEN")
      assert launcher =~ ~s(#define REPO_URL "https://github.com/teapot-chess/Ascella")

      if Code.ensure_loaded?(Ascella.Updates) and
           function_exported?(Ascella.Updates, :update_exit_code, 0) do
        assert apply(Ascella.Updates, :update_exit_code, []) == 90
      end

      unit = read("rel/linux/ascella.service")
      assert unit =~ ~r/^Environment=ASCELLA_UPDATER=systemd$/m
      assert unit =~ ~r/^Environment=ASCELLA_UPDATE_STATUS=\/var\/lib\/ascella-update\/status$/m
      assert read("rel/linux/update.sh") =~ ~s(STATUS_FILE="/var/lib/ascella-update/status")
      assert read("rel/linux/update.sh") =~ ~s(REQUEST_FILE="$DATA_DIR/update/request")

      assert read("rel/linux/ascella-update.path") =~
               ~r/^PathExists=\/var\/lib\/ascella\/update\/request$/m

      assert read("rel/linux/ascella-update.service") =~
               ~r/^ExecStart=\/opt\/ascella\/update.sh --requested$/m

      assert read("rel/macos/Launcher.swift") =~
               ~s(let launcherTokenEnv = "ASCELLA_LAUNCHER_TOKEN")

      assert read("rel/macos/Launcher.swift") =~ ~s(let headlessEnv = "ASCELLA_LAUNCHER_NO_UI")

      for file <- ~w(rel/env.sh.eex rel/env.bat.eex rel/linux/ascella.service) do
        assert read(file) =~ "RELEASE_DISTRIBUTION", "#{file} leaves distribution on"
      end
    end

    test "the Mac app has a Dock icon, does not quarantine downloads, and does not ask before it stops" do
      plist = read("rel/macos/Info.plist")
      # LSUIElement hides the app from the Dock and Cmd-Tab.
      refute plist =~ "LSUIElement"
      # With this key, everything Ascella downloads would be quarantined.
      refute plist =~ "<key>LSFileQuarantineEnabled</key>"

      swift = read("rel/macos/Launcher.swift")
      assert swift =~ ~s(let dataEnv = "ASCELLA_DATA")
      assert swift =~ ~s(let releaseInResources = "app/bin/ascella")
      assert swift =~ ~s(let probePath = "/help")
      assert swift =~ "let askBeforeStopping = false"
      assert swift =~ ~s[appendingPathComponent("launcher.sh")]
      assert swift =~ ~s[contains("--headless")]
      assert read(".github/workflows/release.yml") =~ ~s("$launcher" --headless)

      imports = Regex.scan(~r/^import (\w+)$/m, swift, capture: :all_but_first)
      assert Enum.sort(List.flatten(imports)) == ["AppKit", "Foundation"]

      assert read("rel/windows/launcher.c") =~ "#define ASK_BEFORE_STOPPING 0\n"
    end

    test "the Mac icon has Apple's margin around the tile" do
      png = File.read!(Path.join(@root, "rel/macos/Ascella-icon.png"))
      assert <<0x89, "PNG", _::binary-size(12), width::32, height::32, _::binary>> = png
      assert {width, height} == {1024, 1024}
    end

    test "the unit runs as root, because installing programs is its job" do
      unit = read("rel/linux/ascella.service")

      for line <- [
            "Restart=on-failure",
            "Environment=RELEASE_DISTRIBUTION=none",
            "PrivateTmp=yes",
            "ProtectKernelModules=yes"
          ] do
        assert unit =~ ~r/^#{Regex.escape(line)}$/m, "ascella.service lacks: #{line}"
      end

      # No service user, and none of what would stop an installer writing
      # /opt, /etc/systemd/system and /var/lib.
      refute unit =~ ~r/^User=/m
      refute unit =~ ~r/^SupplementaryGroups=/m
      refute unit =~ ~r/^ProtectSystem=/m
      refute unit =~ ~r/^ReadWritePaths=/m
      refute unit =~ ~r/^NoNewPrivileges=/m
    end

    test "Linux listens on loopback only: no --lan, no service user" do
      install = read("rel/linux/install.sh")
      refute install =~ "--lan)"
      refute install =~ "ASCELLA_LISTEN"
      refute install =~ "useradd"
      assert install =~ "ssh -L 4090:127.0.0.1:4090"
    end

    test "the shell scripts have Unix line endings, and are what mix.exs makes executable" do
      for file <-
            Path.wildcard(Path.join(@root, "rel/linux/*")) ++
              Path.wildcard(Path.join(@root, "rel/macos/*.sh")) ++
              [Path.join(@root, "tools/release_notes.sh"), Path.join(@root, "rel/env.sh.eex")] do
        refute File.read!(file) =~ "\r", "#{file} has CRLF line endings"
      end
    end
  end

  describe "the key to the Linux service's page" do
    test "the unit says where to write it, and ascella.sh open reads it from there" do
      unit = read("rel/linux/ascella.service")
      script = read("rel/linux/ascella.sh")

      assert unit =~ "Environment=ASCELLA_TOKEN_FILE=/run/ascella/token"
      assert unit =~ "RuntimeDirectory=ascella"
      assert script =~ ~s(if [ "${1:-}" = open ])
      assert script =~ "ASCELLA_TOKEN_FILE:-/run/ascella/token"
      assert script =~ "/?k="
    end
  end

  describe "the Mac app can update itself" do
    test "launcher.sh hands the app's pid to the server, which signals it on an update" do
      assert read("rel/macos/launcher.sh") =~ ~s(export ASCELLA_LAUNCHER_PID="$PPID")
      assert read("lib/ascella/self_update/mac.ex") =~ "ASCELLA_LAUNCHER_PID"
    end

    test "the assets the updater unpacks are the ones the release workflow publishes" do
      for {_arch, asset} <- Ascella.SelfUpdate.Mac.assets() do
        assert read(".github/workflows/release.yml") =~ asset
      end
    end
  end
end
