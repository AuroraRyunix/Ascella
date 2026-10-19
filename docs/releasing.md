# Releasing Ascella

How a version gets from `main` to somebody's hall, what each downloaded
file is, and - because none of it has happened yet - what the first release
has to prove.

The machinery is Alnasl's, renamed and trimmed: no serial port, no
database, and on Linux a service that runs as root because installing other
programs is the whole point of it. Where this file and Alnasl's
`docs/releasing.md` say the same thing, they are meant to.

## Cutting a release

One commit on `main`:

1. `mix.exs`: the new `version:`.
2. `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   (and start a new, empty `## [Unreleased]` above it).

Push. `.github/workflows/release.yml` builds every target, starts each one
and looks at its answer, and then - only if every target passed - tags
`vX.Y.Z` at that commit and publishes the release with the changelog
section as its notes.

It publishes when **both** are true: `mix.exs` names a version without a
GitHub release, and the changelog has a section for exactly that version.
A version without notes publishes nothing (the run says so in a notice and
stays green); so does a push that changes neither. That second condition is
there because `main` says 0.1.0 from its first commit, and a release that
publishes itself the moment the workflow lands is a release nobody chose.

Do not tag by hand. If you do, the tag must be `v` + the version in
`mix.exs`, or the workflow refuses.

There is no way to un-release. A wrong release is followed by a right one
with a higher number; installed copies move forward only.

## What a release holds

All names are without a version, so that
`https://github.com/teapot-chess/Ascella/releases/latest/download/<name>`
is a link that stays right. The version is inside each file.

| File | What it is | Who asks for it by name |
|---|---|---|
| `Ascella-Setup.exe` | The Windows installer (Velopack, per user, one click) | the download page |
| `ascella-windows-x86_64-portable.zip` | The same release as a folder; installs nothing | the download page |
| `ascella-linux-x86_64.tar.gz` | The Linux release, PCs | `install.sh`, `update.sh`, the download page |
| `ascella-linux-aarch64.tar.gz` | The Linux release, 64-bit Raspberry Pi and other arm64 | the same |
| `ascella-macos-aarch64.zip` | `Ascella.app` for Apple Silicon (M1 and later), zipped with `ditto` | the download page, the Terminal install in `docs/macos.md`; a Mac copy's update notice (its size) |
| `ascella-macos-x86_64.zip` | `Ascella.app` for Intel Macs (macOS 10.13 and newer), built only for a release | the same, on an Intel Mac |
| `install.sh` | The one-line installer | `curl ... \| sudo sh` |
| `update.sh`, `uninstall.sh` | Copies of what the archive carries, for reading | nobody; a person |
| `SHA256SUMS` | Checksums of everything above and below | `install.sh`, `update.sh`, the Mac Terminal install |
| `releases.win.json` | Velopack's feed: which Windows versions exist | every installed Windows copy |
| `AscellaApp-X.Y.Z-full.nupkg` | The Windows program as Velopack fetches it | the same, via the feed |
| `AscellaApp-X.Y.Z-delta.nupkg` | The difference from the release before (from the second release on) | the same |

Never rename `releases.win.json` or a `.nupkg`, and never change the pack
id `AscellaApp`: installed copies look for those names, and one that cannot
find them stays on its version for ever without saying why.

## Where things are built from

| | |
|---|---|
| `mix.exs`, `releases/0` and `release_extras/1` | one release, `ascella`; per system, the files beside `bin/` |
| `config/runtime.exs`, `lib/ascella/data_home.ex` | where an installed copy keeps its data, and the refusal to keep it anywhere an installer owns |
| `rel/env.sh.eex`, `rel/env.bat.eex` | Erlang distribution off by default |
| `rel/windows/launcher.c` | `Ascella.exe`: starts the release, opens the browser, is the stop button, applies an update |
| `rel/windows/build_launcher.ps1` | compiles it with `zig cc` (run by `mix release`) |
| `rel/windows/build_installer.ps1` | `vpk pack`, with the checks that keep data out of harm's way |
| `rel/windows/build_icon.py` | draws `Ascella.ico` and `rel/macos/Ascella-icon.png` from `priv/logo/mark.svg`; run by hand when the mark changes |
| `rel/linux/install.sh`, `update.sh`, `uninstall.sh` | the Linux installation |
| `rel/linux/ascella.service`, `ascella-update.path`, `ascella-update.service` | the service (root), and the updater it hands its own update to so it is not killed halfway |
| `rel/macos/build_app.sh`, `launcher.sh`, `Info.plist` | `Ascella.app` around the release: its launcher (status window, Stop), the checks that it links nothing but the system and quarantines nothing it downloads |
| `rel/macos/sign_and_notarize.sh`, `entitlements.plist` | Developer ID signing and notarisation, once the Apple account exists (below) |
| `lib/ascella/updates.ex` | the check, the notice, the hand-over |
| `lib/ascella/launcher_details*`, `lib/ascella_web/plugs/launcher_stats.ex` | the launchers' Details panel (`docs/launcher-details.md`) |
| `tools/release_notes.sh` | the changelog section of one version |

## Signing the Mac app

Not done yet: there is no Apple Developer account. The macOS job builds
`Ascella.app` **ad-hoc signed** (Apple Silicon requires a signature on every
binary; Gatekeeper still asks once, see `docs/macos.md`, "Installing
Ascella the first time").

The signing step is already in `release.yml`, and skips itself while the
secret `APPLE_CERTIFICATE_P12_BASE64` is empty. Once the account exists,
add these repository secrets and nothing else changes:

| Secret | What |
|---|---|
| `APPLE_CERTIFICATE_P12_BASE64` | the *Developer ID Application* certificate with its private key, exported as `.p12`, then base64 |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s password |
| `APPLE_TEAM_ID` | the ten-character team id |
| `APPLE_ID` | the Apple ID that notarises |
| `APPLE_APP_PASSWORD` | an app-specific password for that Apple ID |

`rel/macos/sign_and_notarize.sh` then signs every binary with the hardened
runtime and the BEAM's entitlements (JIT, `dlopen` of whatever NIF a
dependency brings), notarises, staples, and asks Gatekeeper before the zip
is made. The same five secrets, under the same names, sign OpenPairings.app
and Alnasl.app. The first signed build needs a Mac test of its own.

## Building one by hand

Windows, with Elixir, `zig` and `vpk` (`dotnet tool install -g vpk
--version 1.2.0`) on the PATH. Set `ASCELLA_DATA` to a scratch folder first:
any `MIX_ENV=prod` task reads the runtime configuration, and without it
would create the real data folder of the PC you are sitting at.

```
set MIX_ENV=prod
set ASCELLA_DATA=%CD%\tmp\release-data
mix deps.get --only prod
mix compile
mix assets.deploy
mix release ascella --overwrite
.\rel\windows\build_installer.ps1 -PayloadDir _build\prod\rel\ascella -OutputDir installer_out
mix phx.digest.clean --all
```

Linux: the same four `mix` lines, then
`tar -czf ascella-linux-$(uname -m).tar.gz -C _build/prod/rel ascella`. Built
on your machine it runs on your machine's glibc or newer; the workflow
builds on Ubuntu 22.04 for a reason.

**Building an installer is harmless. Running one is not a test to do on the
PC you work on.** Use a Windows Sandbox or a spare machine. A sister program
lost real data to an installer run "just to see". Ascella, whose job is
running installers, doubles that advice rather than halving it.

## What the first release has to prove

Nothing below has been done. Each line is a claim the code makes and nobody
has watched come true. Work down the list with the first release and strike
what holds.

**The workflow**

- [ ] `ci.yml` and `release.yml` parse and run at all. (They are Alnasl's,
      which do; the deletions are what is new.)
- [ ] `shellcheck --severity=warning` passes on `rel/linux/*.sh` (it was
      not available where they were edited; they pass `sh -n`).
- [ ] The smoke tests pass on all four targets: `/help` answers with
      `id="manual"`, nothing listens but 127.0.0.1:4096, no epmd, and
      `secret_key_base` is in the data folder.
- [ ] A push with a version and no changelog section publishes nothing; a
      push with both publishes once; the next push publishes nothing.
- [ ] The release notes are the changelog section.

**Windows**

- [ ] `Ascella-Setup.exe` installs to `%LOCALAPPDATA%\AscellaApp`, makes the
      Start menu and desktop entries, and starts the launcher.
- [ ] The launcher's window appears, the browser opens when the site
      answers, a second double-click opens a tab instead of a second server.
- [ ] Closing the window stops the program without asking (there is
      nothing to warn about); no `erl.exe` of Ascella's is left.
- [ ] An app Ascella started is still running after Ascella's window is
      closed. The launcher's job object kills everything inside it on
      close; it allows breakaway (`JOB_OBJECT_LIMIT_BREAKAWAY_OK`), so this
      holds only if Ascella starts the apps in a way that leaves the job.
- [ ] The data is in `%LOCALAPPDATA%\AscellaData`, and **is still there
      after uninstalling**.
- [ ] Installing again finds the data.
- [ ] A PC that never had Erlang or the Visual C++ runtime starts it (the
      three DLLs beside `erl.exe` are there for this).
- [ ] From the second release on: the notice appears, "Download and
      install" stops the program, the launcher downloads and applies, the
      new version starts. And with no network at that moment, the old
      version comes back.
- [ ] SmartScreen says what the README says it says.
- [ ] Symantec and Defender leave `Setup.exe`, the portable zip and the
      installed `Ascella.exe` alone. A program that downloads and starts
      other programs is exactly what heuristics are paid to dislike; this
      one is worth measuring rather than assuming.
- [ ] "Start with Windows" starts it, minimised, without a browser.

**Linux**

- [ ] `install.sh` on Debian 12, Ubuntu 22.04 and Raspberry Pi OS Bookworm
      64-bit: directories, units, service up, as root.
- [ ] The unit starts, and from it Ascella can run another app's
      `install.sh`: writes to `/opt`, `/etc/systemd/system`, `/var/lib`,
      `useradd`, `systemctl daemon-reload`, `systemctl enable --now`.
- [ ] It answers on 127.0.0.1:4090 and on nothing else; through
      `ssh -L 4090:127.0.0.1:4090` from another machine.
- [ ] `update.sh` to a newer release: download, checksum, switch, restart,
      answer. And to a release that does not start: the old one is back.
- [ ] "Download and install" on the page: the request file appears,
      `ascella-update.path` fires, the page comes back on the new version.
- [ ] `uninstall.sh` removes the program and **leaves `/var/lib/ascella`**,
      and every app Ascella installed.
- [ ] Offline install from an unpacked archive.

**macOS** (the full list, for a person with a Mac, is in `docs/macos.md`)

- [ ] `macos-15` builds it, `build_app.sh` finds no Homebrew library, and
      the app starts from a read-only bundle on the runner.
- [ ] Installed the Terminal way, it opens without a Gatekeeper question.
      Downloaded in a browser, it opens after "Open Anyway".
- [ ] An app Ascella downloads opens without a Gatekeeper question.
- [ ] The data is in `~/Library/Application Support/AscellaData`, and is
      still there after the app is binned.

## Version numbers

`0.1.0` is in `mix.exs` and has never been released, so the first release
can simply be `0.1.0`: no bump, only the changelog heading. From then on:
patch for fixes, minor for anything somebody would notice, and 1.0.0 the
day a hall has been set up from nothing by Ascella alone.
