# Changelog

What changed in Ascella, newest first. The format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and each entry is
tagged so that a version can be skimmed:

| tag | meaning |
|---|---|
| [Feature] | something new you can do |
| [Fix] | something that was broken |
| [Change] | existing behaviour works differently |
| [Removed] | something is gone |
| [Security] | a hole closed, or judged not to be one |
| [Verified] | checked against the real thing, no code change |

A version is released when its number is in `mix.exs` **and** it has a
section here: the release's page on GitHub is that section, word for word.
See [docs/releasing.md](docs/releasing.md).

## [Unreleased]

- [Change] **The Mac app is signed with a Developer ID and notarised by Apple.** Until now it was signed with nothing but good intentions, and every Mac that downloaded it asked the arbiter to override Gatekeeper by hand, which is a strange way to greet someone who just installed your software. The release workflow now signs every binary inside Ascella.app, hardened runtime and BEAM entitlements included, sends the bundle to Apple, staples the ticket and checks the verdict with `spctl` before the zip exists. A fork without the secrets still builds, with a warning, ad-hoc signed. The workflow can also be started by hand with *mac_only* to test all this without publishing anything.

## [0.3.4] - 2026-10-20

- [Fix] **Stopping an app from Ascella actually stops it, and a self-update gets past "Stopping".** Every hall app's Mac window waited for its server to end inside the very queue that was to bring the news, so the server ended and the window said "Stopping" until somebody force-quit it. Quit from the menu never had the problem, which is how it survived. Ascella's own window is fixed here; the other programs get the same fix in their next release. Any stop that hangs anyway now ends after forty seconds.
- [Feature] **"What's new" before the update, not after.** Beside every offered update, Ascella's own included, there is now a button that reads the release notes of each version between the one installed and the latest, newest first, straight from GitHub. Until now the way to learn what an update did was to install it and look around. The notes are fetched only when you ask, shown as text with bullets, bold, code and https links and nothing else (GitHub's text is not trusted with HTML), and if GitHub does not answer the page says so while the update button carries on regardless.

- [Feature] **Every program now has an Intel Mac build to offer.** OpenPairings, Alnasl, Arkab, Polis and Nunki publish one since their latest releases, so the "No build for Intel Macs yet" tiles are gone from Intel Macs. The sentence stays in the code for the next program that arrives without one.

## [0.3.3] - 2026-10-19

- [Feature] **Ascella for Intel Macs, from macOS 10.13.** macOS 10 exists only on Intel Macs, and Intel Macs had been struck off on the 14th because their build cost thirteen minutes on every push. It is back, and it is built only when there is a release to put it in (or when somebody starts the workflow by hand), so the other pushes are as quick as they were. Ascella chooses the zip for the Mac it is on, for its own updates and for everything it installs; an Intel Ascella running under Rosetta on an Apple Silicon Mac is still treated as the Apple Silicon Mac it is. Every program in the bundle is checked against the oldest macOS promised, as before.
- [Change] **Programs with no Intel build say so.** Until the other programs publish an Intel zip, an Intel Mac sees "No build for Intel Macs yet" on their tiles, instead of being handed the Apple Silicon zip, which would have opened as damaged and explained nothing. Adding one later is a line in `priv/catalogue.json`.
- [Fix] **A self-update no longer waits forever for the old Ascella to leave.** On a real Mac the old copy was asked to quit, did not, and two minutes later the update gave up with the new version sitting unopened in Applications. The helper now asks again after thirty seconds and stops asking after sixty, writes down what was still running, and opens the new version anyway. Every step goes into `logs/self-update.log` in the data folder, which, unlike `server.log`, survives the restart it is about.
- [Fix] **Quitting Ascella is quicker.** The page left open in a browser held the stop for up to fifteen seconds; it now gets three, as in the other hall apps. The Mac launcher writes into the log how long a stop took.

## [0.3.2] - 2026-10-19

- [Change] **Nothing, on purpose.** This version exists so that 0.3.1 has something to update itself to on a Mac. An updater that has never updated is a theory.

## [0.3.1] - 2026-10-19

- [Feature] **Ascella updates itself on a Mac.** It used to be the one program on the page that could not update itself on a Mac, which is the cobbler's children again. The page now says "Ascella X.Y.Z, update available" with a button; the zip is checked against the release's checksums like every other download, unpacked beside the running app, and swapped in with one previous copy kept. A helper then opens the new Ascella, and puts the old one back if the new one does not answer within 45 seconds, saying so on the page. If `Ascella.app` is somewhere it cannot be replaced (Downloads, a folder that wants an administrator), nothing is attempted and the page says where it is and to move it to /Applications. The first Ascella from a browser still needs to be allowed once; that is Gatekeeper's rule and not ours.
- [Change] **Ascella updates last, and never while it is busy.** "Update all" now includes Ascella when it has an update (Mac, Windows installer, Linux service), after every other program. Updating Ascella is refused while anything is being installed, updated or rolled back, and everything else is refused while Ascella is replacing itself. One place decides (`Ascella.Updates.decide/1`, asked by `Ascella.Apps`).
- [Change] **The update line on the page** reads "Ascella X.Y.Z, update available", says which version this is, says "waiting for the other programs" while it is queued behind them, and shows why an update was refused instead of nothing.

## [0.3.0] - 2026-10-19

- [Security] **On Linux the page wants a key.** The service is root and listens on 127.0.0.1, which every process on the box can reach, so another login (or a compromised service account) could fetch the page, take its CSRF token and press Install, Update or "remove with its data" as root. The service now writes a random key at every start to `/run/ascella/token`, readable by root and the `ASCELLA_RUN_AS` user only; `ascella.sh open` turns it into a link (`/?k=...`) that the page trades for a signed cookie and redirects away; pages and LiveView sockets without that cookie are refused. Windows, macOS and a terminal start have none of this.
- [Fix] **OpenPairings under the Linux service now actually starts.** The program lives under `/var/lib/ascella`, which is `0750 root`, and it was started as the `ASCELLA_RUN_AS` user, who could not get in; the shell failed its redirect, still printed a pid, and Ascella reported success. Ascella now gives that user a way to walk to the program and a log folder of its own, and a program that is gone a moment after it started is a failed start, with the end of its log (or what the shell said) on the tile.
- [Fix] **A stale pid file can no longer point Stop at somebody else's process.** After a reboot or a crash the number in the `pid` file can be any process; as root, Stop sent it SIGTERM, and install and update refused for ever because "it is running". The pid is now stored with the process's start time and trusted only when that matches; otherwise the file is deleted. A pid file from before this is trusted once, as it always was.
- [Fix] **A first install on Windows no longer hands Setup.exe Ascella's own environment.** Velopack's Setup may start the app it just installed, and an app that finds `PORT=4090` in its environment concludes Ascella is already running it and leaves. Setup now runs with the variables of Ascella's own release removed.

## [0.2.2] - 2026-10-18

- [Fix] **Stopping no longer ends in a red stack trace.** On the way out the launcher-details process tidied up its secret by asking the application controller, which at that point is busy dying and answers everyone with an exit. The secret goes with the VM anyway, so now it lets the question go unanswered and leaves quietly.

- [Change] **New address.** The repository moved to github.com/teapot-chess; old links still redirect, out of politeness rather than obligation.
## [0.2.1] - 2026-10-18

- [Fix] **"Keep in Dock" on a Mac now goes through the Dock's own preferences daemon.** The Dock keeps its settings in `cfprefsd`, which caches them and ignores a plist file written behind its back; Ascella wrote the file, so ticking the box often did nothing and unticking it removed nothing. Now: `defaults export com.apple.dock`, edit `persistent-apps` in that copy (a proper file tile with its `file:///Applications/Name.app/` URL; removal deletes every tile pointing at the bundle), `defaults import`, `killall Dock`. Whether the app is in the Dock is read from an export too, so the checkbox shows what the Dock shows instead of what Ascella remembers.
- [Change] **An app that is open is no longer updated.** The update used to ask it to stop and wait up to a minute, which looks exactly like a hang when the app is mid-round and nobody is answering. Now the tile says "Close X first, then update" at once, before anything is downloaded or swapped, with a Stop button beside the message. Going back to the previous version has the same rule. Nothing is started again afterwards: you closed it, you start it.
- [Fix] **Nothing Ascella runs can wait for ever.** Every command goes through the runner with a deadline (thirty seconds for the ones that ask a quick question, such as `osascript`, `defaults` or PowerShell; ten minutes for unpacking and installers), and one that is still silent then ends the action with an error the tile shows in words, instead of a spinner that outlives everyone's patience.
- [Change] **No way back for OpenPairings and Alnasl.** Their databases migrate forward on an update; an older program over a newer database is how tournaments get damaged. The catalogue has a new `"rollback": false` for such apps: the button is gone, `rollback` refuses with a plain error, and the tile says in one line why. Arkab, Polis and Nunki have no migrating database and keep theirs.
- [Verified] **A SIGTERM does not make the Mac launchers ask "Stop X?".** Alnasl's and Arkab's `Launcher.swift` catch SIGTERM, set `noQuestions` and call `NSApp.terminate`, which skips the dialog; then they stop the server (twenty seconds for the BEAM, thirty for the shell script, then SIGKILL). A dialog already open from an earlier Cmd-Q is a different matter and can keep the launcher waiting.

## [0.2.0] - 2026-10-18

- [Fix] **A program Ascella starts now starts the way Finder or the Start menu would start it.** Start on a Mac handed `open` everything Ascella had exported, `PORT=4090` among it; Arkab read that, found Ascella answering on 4090, concluded it was already running, and left with a clear conscience. Programs are now started from an empty environment (`env -i`) with only `HOME`, `USER`, `LOGNAME`, the locale, a system `PATH` and, on Linux, the display session. A list of what to remove would only be a list of what we remembered. systemd and WMI already start clean and are left as they are.

- [Feature] **Programs can be made easy to start.** Right after an install the tile asks, and every installed tile has a Shortcuts list. Windows: a Start menu and a Desktop shortcut (to pin to the taskbar you right-click the shortcut, because Windows closed every honest way to do it for you, and the dishonest ones are not Ascella's style). Mac: keep in the Dock, open at login. Linux: an entry in the applications menu, a file on the Desktop, GNOME favourites when `gsettings` is there. Ascella writes down what it made, removes only that, and leaves a shortcut with the same name that somebody else made exactly where it was.
- [Feature] **Shortcuts survive updates.** They point at the Velopack stub in the install folder, the `.app`, or a small wrapper that reads `current` when it runs; never at a versioned folder. After every install, update and rollback the file ones are written again anyway.
- [Feature] **Remove.** Each installed tile has one. The program is stopped, then taken away the way its system does it: its own `Update.exe` on Windows, the Bin on a Mac, the app's own `uninstall.sh` (or install reversed) on Linux; the shortcuts Ascella made go with it. The data is kept, and the confirmation says why: it lives outside the program. Deleting it too is a checkbox and a second confirmation. An app removed by something else loses its shortcuts the next time Ascella notices.
- [Feature] **Removing Ascella itself** has a page with the exact steps per system, because a program that uninstalls itself while running has opinions about the order.

## [0.1.0] - 2026-10-18

- [Feature] **One page for the hall's programs.** A tile each for OpenPairings, Alnasl, Arkab, Polis and Nunki, with its mark, what is installed, what is out and whether it runs; Install, Update, Start, Stop and Open per program, and Update all, which does them one at a time because a hall has one network and no patience. English and Dutch.
- [Feature] **The catalogue is data.** `priv/catalogue.json` says which programs there are, where on GitHub they live and what their downloads are called. A program that ships the way Alnasl does is one entry, so adding Polis or Nunki later is a paragraph of JSON, not a release of anything.
- [Feature] Windows: each program's own Velopack does the installing and updating, macOS gets its `.app` swapped in one rename with the previous one kept for a rollback, and Linux runs the programs' own install and update scripts and their own systemd units. Ascella provides the button and the nagging.
- [Feature] Ascella updates itself the way Alnasl does. The cobbler's children get shoes.
- [Security] **Every download is checked against the `SHA256SUMS` of its release**, and checked again just before it runs. No list, not on the list, or the wrong sum: refused and deleted. Only GitHub, only HTTPS, and a redirect anywhere else is a failed download rather than an adventure.
- [Security] **No data directory is ever written, moved or deleted.** Every file operation goes through a guard that knows every program's data folders, a Windows install folder holding a database stops the update cold, and a catalogue that would put a data folder where an uninstaller can reach it does not load. A program that will not stop is left running, unchanged; nothing is ever killed. Earlier experience suggests this is not paranoia.
- [Security] The page answers only on 127.0.0.1. A page that installs programs for anyone on the hall's wifi would be a remote installer with a nice font.
