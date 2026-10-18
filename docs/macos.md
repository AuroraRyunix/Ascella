# Ascella on macOS

Every push to `main` builds **`Ascella.app`** for Apple Silicon Macs, and a
release attaches it. The build is Alnasl's, renamed, minus the serial port
and the database. Nobody on the project has a Mac on hand for every build:
everything here was built and started on GitHub's macOS runners, and the
[test list](#testing-a-build-on-a-real-mac) at the end is what a person
with a Mac still has to confirm.

| | |
|---|---|
| Apple Silicon only (M1 and later) | `ascella-macos-aarch64.zip`, built on `macos-15` |
| Runtime | Erlang/OTP 29.0.5 compiled on the runner by `rel/macos/build_otp.sh`, for macOS 11, with OpenSSL 3.5 compiled the same way and linked into `crypto` statically; Elixir 1.20 from its own precompiled zip. Cached, so only the first run with a given set of versions pays. Linux and Windows use `erlef/setup-beam`; on macOS that would be `erlef/otp_builds`, which is built for macOS 15 (see [Why the runtime is built here](#why-the-runtime-is-built-here)) |
| Oldest macOS | 11 (Big Sur). Everything compiled on the runner is built for it (`MACOSX_DEPLOYMENT_TARGET=11.0`), and `build_app.sh` fails the build, naming the files, if any binary asks for newer; what they accept goes into `Info.plist` |
| Signed | ad-hoc only, for now - see [Installing Ascella the first time](#installing-ascella-the-first-time) |

## Installing Ascella the first time

Ascella is an unsigned, zipped `.app` (ad-hoc signed: every binary carries
a signature, which Apple Silicon insists on, but Gatekeeper does not know
who made it). A file a **browser** downloads gets the quarantine flag
(`com.apple.quarantine`), and a quarantined unsigned app is refused on its
first start. That is the one manual step, once, for Ascella itself.

### The recommended way: Terminal

`curl` does not set the quarantine flag, so an app fetched with it opens
like any other. Open *Terminal* (Applications > Utilities) and paste this
as one line:

```sh
cd ~/Downloads && curl -fLO https://github.com/teapot-chess/Ascella/releases/latest/download/ascella-macos-aarch64.zip && curl -fLO https://github.com/teapot-chess/Ascella/releases/latest/download/SHA256SUMS && grep ' ascella-macos-aarch64.zip$' SHA256SUMS | shasum -a 256 -c - && ditto -x -k ascella-macos-aarch64.zip /Applications && open /Applications/Ascella.app
```

In order: download the zip and the release's checksums into Downloads,
check the zip against its line (`ascella-macos-aarch64.zip: OK`; anything
else stops the line there), unpack it into Applications with `ditto`
(which keeps the bundle's modes and signature, unlike some unzippers), and
start it. No question from Gatekeeper, because nothing was quarantined to
ask about. The checksum catches a download that broke, not a release that
was tampered with: the sums come from the same place as the zip.

### The Finder way

1. Download `ascella-macos-aarch64.zip` from the release page in the
   browser.
2. Double-click it in Downloads; Finder unzips it to `Ascella.app`.
3. Drag `Ascella.app` into **Applications**.
4. Double-click it. macOS says it **cannot be opened** (on macOS 15 and
   newer: "could not verify..."). Click *Done* (or *OK*).
5. *System Settings > Privacy & Security*, scroll down to
   "Ascella was blocked to protect your Mac", **Open Anyway**.
6. Confirm with your password or Touch ID, then *Open*.

From then on it opens with a double-click. (On macOS 14 and older,
right-click the app > **Open** > *Open* does the same; Sequoia removed that
shortcut.) If macOS says **"Ascella is damaged and can't be opened"**, it is
not; the quarantine flag is, and in Terminal
`xattr -dr com.apple.quarantine /Applications/Ascella.app` removes it.

### Why nothing Ascella downloads afterwards is quarantined

Quarantine is not something the file system does on its own: an
application marks the files it writes, and only if it is a quarantining
application. Browsers, Mail and AirDrop are. A process is one when its
`Info.plist` sets `LSFileQuarantineEnabled` (or when it calls the
quarantine API itself, which Ascella does not); without that key, what it
writes carries no flag. Ascella's `Info.plist` does not set it - the file
says so in a comment, `rel/macos/build_app.sh` refuses to build an app whose
plist has it, the release workflow checks the built bundle again, and
`test/ascella/release_files_test.exs` checks the source. So the apps
Ascella downloads and unpacks open without the dance above, which is most
of the reason to install Ascella first.

The same holds for what they download in turn, as long as they do not
quarantine either. It does not make anything trustworthy that was not:
Ascella checks each download against the checksums of the release it came
from before it unpacks anything.

## What the app is

```
Ascella.app/Contents/
  Info.plist              rel/macos/Info.plist, version from the release's VERSION
  MacOS/Ascella           rel/macos/Launcher.swift, compiled (arm64, macOS 11+)
  Resources/launcher.sh   rel/macos/launcher.sh
  Resources/app/          the release (bin/ascella), whole
  Resources/Ascella.icns  from rel/macos/Ascella-icon.png
```

`rel/macos/build_app.sh` builds it on the runner and compiles the launcher
there with `swiftc` (plain AppKit, one file, no Xcode project). The icon is
`rel/macos/Ascella-icon.png`, 1024 pixels with Apple's margin, drawn from
`priv/logo/mark.svg` by `rel/windows/build_icon.py` like the Windows one.
The two halves:

- **`Launcher.swift`** is what you see. A normal **Dock icon**: the running
  dot, *Options > Keep in Dock*, Cmd-Tab. A **small window** - "Ascella is
  running at http://localhost:4090", *Open in browser*, *Stop Ascella* - in
  English, or Dutch when the Mac's first language is Dutch. Closing the
  window only hides it; clicking the Dock icon brings it back, and the Dock
  icon's menu has *Open in browser* too. The browser opens by itself once
  the site answers.
- **`launcher.sh`** is what it runs: the release, with distribution off and
  everything it writes outside the bundle; it waits until the port answers
  and stops the server on SIGTERM (clean `init:stop()`, twenty seconds, then
  insists). It also watches its parent: if the app is force-quit, the server
  goes with it.

**Quitting stops the server, and does not ask.** Alnasl's app asks first,
because it has boards to stop reading; stopping Ascella interrupts nothing
but Ascella. The question is still in the code (`askBeforeStopping`),
switched off. Logging out and shutting down stop it cleanly too. A second
start opens the browser at the running copy instead of a second server. If
the server stops by itself, the app says so and names the log.

Nothing is written into the app: a fresh download runs from a read-only,
"translocated" copy, and a write would break the bundle's seal. The
release's runtime files go to the temporary folder and crash dumps to the
data folder; CI starts the app from a read-only bundle and checks its seal
afterwards.

There is no "Start with macOS" switch (Windows has one). Add the app to
*System Settings > General > Login Items* if it should start with the Mac.

## Details

The app's window has a *Details* button (Cmd-D too). It opens a window of its
own with the numbers the running server reports about itself and the end of
`logs/server.log`, with *Copy* (numbers plus the last 200 log lines, for a
mail) and *Open log folder* (Finder, the file selected). The app makes a
secret at every start and hands it to the server in `ASCELLA_LAUNCHER_TOKEN`;
the server answers `GET /_launcher/stats` only to this machine, only with that
secret and only without a proxy header. The contract is
`docs/launcher-details.md`.

## Where the data is

`~/Library/Application Support/AscellaData` - `secret_key_base`, what
Ascella knows about the apps it manages, and `logs/server.log` - the
server's output for the current run (a fresh file on every start; the
previous run is kept once as `server.log.1`). Never inside the app:
replacing the app (an update) or binning it (an uninstall) leaves it alone.
`Ascella.DataHome` refuses to start with a data folder inside any `.app`
(`ASCELLA_DATA` included).

## Updates

`launcher.sh` sets `ASCELLA_UPDATER=macos-app`, which only tells the page
what kind of copy this is. There is no in-place updater on the Mac: a new
`Ascella.app` replaces the old one, by hand or with the Terminal line
above - after quitting Ascella and binning the old app: `ditto` merges
into a bundle that is already there, and a merged bundle fails its seal.

Velopack (which updates the Windows copy in place) was considered and not
used, for the same reasons as in Alnasl: its Mac installer is a `.pkg`
installing into `/Applications` as root, an unsigned `.pkg` meets the same
Gatekeeper refusal as the app, and nobody has tried an update over an
ad-hoc signed bundle. Worth another look once the app is signed.

## What can still ask, signed or not

- *"Do you want the application beam.smp to accept incoming network
  connections?"* - should not happen: Ascella listens on 127.0.0.1 only.
  If it does, something is wrong, and *Deny* is the right answer.
- *Local network* (macOS 15 and newer) - should not be asked either: Ascella
  talks to its own machine and to GitHub. The apps it starts may ask for
  themselves.

**Signing, when the account exists**, is five repository secrets -
`APPLE_CERTIFICATE_P12_BASE64`, `APPLE_CERTIFICATE_PASSWORD`,
`APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_PASSWORD` - see
[releasing.md, "Signing the Mac app"](releasing.md#signing-the-mac-app). The
step is in the workflow already and skips itself while they are missing.
Then the first start is a double-click, browser or not.

## Why the runtime is built here

`erlef/setup-beam` on macOS installs `erlef/otp_builds`, which is built on
the newest runner without a deployment target, so `beam.smp`, `erlexec` and
the OTP NIFs all say "macOS 15 or newer" (`minos 15.0` in
`LC_BUILD_VERSION`). Alnasl shipped that once, and a Mac on 14.6 answered
*You can't use this version of the application with this version of macOS*.

So `rel/macos/build_otp.sh` compiles OpenSSL (static) and Erlang/OTP (no
wx, no Java, no ODBC, no docs) with `MACOSX_DEPLOYMENT_TARGET=11.0`, checks
each download against a SHA-256 in the script, and installs Elixir's
precompiled zip for that OTP major. `actions/cache` keeps the result under a
key of the OTP, OpenSSL and Elixir versions, the target, the runner and the
script itself. The versions are in the workflow's `env`; a version bump
also needs its checksum in the script, which fails loudly without one. The
deployment target is in the deps cache key so a NIF built for another
macOS cannot come back from it.

`build_app.sh` fails the build if any Mach-O file in the bundle asks for a
macOS newer than 11.0, and prints each of them with its `minos`.

## What CI checks on every push

In the macOS job of `.github/workflows/release.yml`:

1. `build_app.sh`: `Info.plist` has no `LSFileQuarantineEnabled`;
   `Launcher.swift` compiles (swiftc's errors become annotations on the
   run); every binary links only to the system - `/usr/lib` (the Swift
   runtime in `/usr/lib/swift` included) and `/System`; none asks for a
   macOS newer than 11.0, and the oldest macOS they accept goes into
   `Info.plist`; the ad-hoc signature verifies.
2. The zip is unpacked as a person would, the bundle made read-only.
   `Info.plist` has neither `LSUIElement` nor `LSFileQuarantineEnabled`,
   and `CFBundleExecutable` is a Mach-O arm64 executable.
3. The bundle's own executable, with `--headless` (no window, no browser;
   it runs `launcher.sh` and passes signals on), starts it with a scratch
   data folder on port 4096. It must serve its help page on
   `127.0.0.1:4096` alone, without `epmd`.
4. A second start must leave at once.
5. SIGTERM to the launcher must stop the server, leaving nothing running;
   the bundle's seal must still verify; `secret_key_base` must be in the
   data folder.

The zip is uploaded as the workflow artifact `release_assets_macos-aarch64`
on every push, and attached to the release when one is published. What CI
cannot check: the window, the Dock, Gatekeeper on a download, and whether
what Ascella downloads really opens without a question. That is the list
below.

## Testing a build on a real Mac

About twenty minutes.

**Get the build**

1. On GitHub: **Actions > Build and release**, open the newest green run
   (for `main`, or for the branch you were asked to test - *Run workflow* on
   that branch builds one without publishing anything).
2. Under *Artifacts*, download **`release_assets_macos-aarch64`** (signed in
   to GitHub). This is a browser download: expect the Finder way above.
3. Open it until you have **`Ascella.app`** (the artifact is a zip holding
   `ascella-macos-aarch64.zip`, which holds the app), and drag it into
   **Applications**.

**First start**

4. Double-click it. Expect the refusal and Open Anyway, as in
   [The Finder way](#the-finder-way). Note the message you saw.
5. Expect within about ten seconds: an Ascella icon in the **Dock** with a
   running dot (the white tile with the eight squares, sized like its
   neighbours), a small window **"Ascella is running at
   http://localhost:4090"** (in Dutch if your Mac is in Dutch), and the
   browser on Ascella's site. No Terminal window.
6. `xattr /Applications/Ascella.app` lists `com.apple.quarantine` (it came
   from a browser); that is expected and harmless now.

**The data folder**

7. Finder > *Go > Go to Folder...* >
   `~/Library/Application Support/AscellaData`: `secret_key_base` and
   `logs/server.log`.

**What it downloads**

8. Install one app from Ascella's page. Then, in Terminal, `xattr` on what
   it unpacked: **no** `com.apple.quarantine`. Start that app from Ascella:
   no Gatekeeper question. This is the step the whole quarantine section is
   about; if it fails, note the app and the macOS version.

**Running, stopping**

9. Close the browser tab, *Open in browser*: it comes back. Cmd-Tab:
   Ascella is in the list.
10. Close the small window: the Dock icon keeps its dot. Click the Dock
    icon: the window comes back.
11. Double-click the app in Applications again: a browser tab, still one
    Dock icon, no second server.
12. **Stop Ascella**: no question; it stops, `http://localhost:4090` no
    longer answers, *Activity Monitor* has no `beam` of Ascella's. The app
    installed in step 8, if it was started, is still running.
13. Cmd-Q and the Dock's *Quit*: the same clean stop.

**The Terminal way**

14. Quit Ascella, bin it, and install it with the Terminal line in
    [Installing Ascella the first time](#installing-ascella-the-first-time):
    the checksum line says `OK`, the app opens with no Gatekeeper question,
    and `xattr /Applications/Ascella.app` lists no quarantine.

**Removing it**

15. Quit Ascella, drag it from Applications to the Bin, empty the Bin.
16. `~/Library/Application Support/AscellaData` is **still there**, and the
    apps it installed are still installed.

**Report back**: macOS version, the Gatekeeper message (step 4), step 8's
`xattr` output, any step that went otherwise, and `logs/server.log` if
something failed.
