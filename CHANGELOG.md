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
