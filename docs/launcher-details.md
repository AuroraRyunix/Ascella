# Launcher details: `GET /_launcher/stats`

What the Windows launcher's **Details** panel, the Mac app's **Details**
window and `./ascella.sh details` show. Alnasl and OpenPairings have the same
endpoint with the same shape (their `docs/launcher-details.md`); only the
app-specific block differs, and Ascella's is the smallest, there being no
database, no boards and nothing to relay.

## Who gets an answer

All three, or a plain `404 Not Found` with no hint which one failed:

1. **From this machine.** The socket's peer address is `127.0.0.0/8` or
   `::1`. Forwarded headers are never read as an address. The whole site
   listens on 127.0.0.1 only; this endpoint checks the peer anyway.
2. **With this start's secret** in the header `x-launcher-token`, compared in
   constant time.
3. **Without a proxy header** (`x-forwarded-for`, `forwarded`, `x-real-ip`,
   `cf-connecting-ip`, `x-forwarded-host`). A box somebody put behind a
   tunnel sees its public traffic arrive from loopback; those requests carry
   one of these and get the 404. The launchers and the terminal command talk
   to the socket directly and send none. An `ssh -L` tunnel sends none
   either, and arrives from loopback: whoever can ssh in as a user who can
   read the token file is already past every door this one guards.

Where no secret exists (`config :ascella, launcher_details: false`, which the
tests set) the answer is always 404.

It is `GET` only and sits in the endpoint ahead of the request logger, so
polling does not fill the log it shows.

## The secret

A launcher makes one per start (random, at least 16 characters; the Windows
launcher uses 48 hex digits, the Mac app two UUIDs without dashes) and passes
it to the release in `ASCELLA_LAUNCHER_TOKEN`. Nothing is written to disk.

A release started without it (`ascella.sh`, the systemd service, a terminal)
makes its own and writes it to `<data>/run/launcher.token`:

```
<secret>
<port>
```

mode `0600` in a `0700` directory on Linux and macOS (on Windows the profile
folder's own rights apply), written empty-then-chmod-then-filled so the secret
is never in a readable file, and deleted on a clean stop. A crash leaves it;
the next start overwrites it, and an old secret opens nothing. `<data>` is
Ascella's data folder (`ASCELLA_DATA`).

## The answer

`200`, `application/json`, `cache-control: no-store`. `?lang=nl` words the
`summary` in Dutch; anything else is English. Typical cost is well under a
millisecond: nothing is read but the runtime's own counters and one
dictionary key per process.

```json
{
  "app": "ascella",
  "version": "0.1.0",
  "uptime_s": 3121,
  "started_at": "2026-10-17T19:40:12Z",
  "system": {"os": "windows", "os_version": "10.0.26100", "arch": "x86_64-pc-windows",
             "cores": 8, "otp": "29", "elixir": "1.20.4", "load_average": null},
  "beam": {"memory_bytes": {"total": 0, "processes": 0, "ets": 0, "binary": 0, "code": 0},
           "processes": 310, "schedulers": 8, "run_queue": 0, "cpu_percent": 0.4},
  "log": {"source": "file", "path": "C:\\Users\\...\\AscellaData\\launcher.log"},
  "ascella": {"live_views": 1, "data_dir": "C:\\Users\\...\\AscellaData"},
  "summary": [
    {"label": "Version", "value": "Ascella 0.1.0"},
    {"label": "Pages open", "value": "1"}
  ]
}
```

| field | meaning |
|---|---|
| `uptime_s`, `started_at` | since the runtime started |
| `system.load_average` | Linux only (`/proc/loadavg`), `null` elsewhere |
| `beam.cpu_percent` | scheduler utilisation since the previous request; `null` on the first request of a start |
| `log.source` | `file` (a launcher's `launcher.log`), `journald` (with `unit`, under systemd) or `stdout` (a terminal) |
| `ascella.live_views` | pages open in a browser |
| `ascella.data_dir` | the data folder. In the JSON, not in `summary`: the summary gets pasted into mails, and a path names its user |
| `summary` | the same numbers as label/value lines in words and units, in a fixed order (`Ascella.LauncherDetails.Stats.labels/1`) |

No token and no key is in the answer. Fields are added, not renamed; a
reader ignores what it does not know.

## Showing it

- **Windows** (`rel/windows/launcher.c`): *Details* beside the buttons grows
  the window with the summary (every 2 s, WinHTTP), the last 500 lines of
  `launcher.log` (every second, opened with every share flag so the server's
  writes are never blocked; left alone while somebody has scrolled up or
  selected), *Copy* (title, summary, log path and the last 200 log lines) and
  *Open log folder*. English or Dutch, like the rest of that window.
- **macOS** (`rel/macos/Launcher.swift`): *Details* (also Cmd-D) opens a
  window of its own with the summary (every 2 s, `URLSession`), the end of
  `<data>/logs/server.log` (every second), *Copy* and *Open log folder*
  (Finder, file selected).
- **Linux and macOS terminals** (`./ascella.sh details`, built on
  `bin/ascella eval`): refreshes every 2 s with the last 20 log lines below
  (`q` or Ctrl-C quits); `--once` prints one snapshot, `--json` the raw answer.
  It reads `<data>/run/launcher.token`, so it must run as the user Ascella runs
  as - on an installed Linux box that is root:
  `sudo env ASCELLA_DATA=/var/lib/ascella RELEASE_TMP=/tmp RELEASE_DISTRIBUTION=none /opt/ascella/current/bin/ascella eval "Ascella.LauncherDetails.CLI.main()" --once`.
  A `journald` log is read with `journalctl -u ascella.service`.
