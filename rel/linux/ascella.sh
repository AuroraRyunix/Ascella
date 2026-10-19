#!/bin/sh
# Starts Ascella from this folder, in this terminal, without installing
# anything: to try it, or on a box you would rather not install a service on.
# install.sh, beside this file, is the other way. Installing the other apps
# from here wants root; a terminal that is not root gets as far as asking.
#
# It listens on 127.0.0.1 only. A box without a screen is reached through
# ssh: `ssh -L 4090:127.0.0.1:4090 box`, then http://localhost:4090 here.
#
# The data goes to ~/.ascella (or ASCELLA_DATA), not into this folder: a new
# version unpacked beside the old one finds it.
set -e
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PORT=${PORT:-4090}
export PORT

# `./ascella.sh details [--once | --json]`: the numbers the Windows launcher's
# Details panel shows (version, uptime, CPU, memory, the BEAM) and the last
# lines of the log, in this terminal. It asks
# the Ascella already running from this data folder, through a second,
# short-lived runtime (`eval` starts nothing of the server); see
# Ascella.LauncherDetails.CLI and docs/launcher-details.md.
if [ "${1:-}" = details ]; then
  shift
  exec "$here/bin/ascella" eval "Ascella.LauncherDetails.CLI.main()" "$@"
fi

# `./ascella.sh open [--print]`: the link that lets a browser into the
# service's page. Under the systemd service the page wants a key (written at
# every start to /run/ascella/token, readable by root and by the user named
# ASCELLA_RUN_AS in /etc/ascella/ascella.env); this reads it and opens
# http://localhost:PORT/?k=KEY in the default browser, or prints it with
# --print (to paste in the browser of a machine you reached the box from
# through `ssh -L 4090:127.0.0.1:4090`). Run as root it only prints: a browser
# opened by root is not what anybody wants. Nothing to read when Ascella is
# started in a terminal (this script's other use): then it says so.
if [ "${1:-}" = open ]; then
  shift
  token_file=${ASCELLA_TOKEN_FILE:-/run/ascella/token}
  if [ ! -e "$token_file" ]; then
    echo "No key file at $token_file: the Ascella service is not running here, or it was started"
    echo "in a terminal, which needs none. Open http://localhost:$PORT"
    exit 1
  fi
  if [ ! -r "$token_file" ]; then
    echo "Cannot read $token_file. It is readable by root and by the user named by"
    echo "ASCELLA_RUN_AS in /etc/ascella/ascella.env; run this as that user, or with sudo."
    exit 1
  fi
  # The service's port is the one in its env file, when that says one.
  port=$(sed -n 's/^PORT=\([0-9][0-9]*\)$/\1/p' /etc/ascella/ascella.env 2>/dev/null | tail -n 1)
  url="http://localhost:${port:-$PORT}/?k=$(cat "$token_file")"
  if [ "${1:-}" = --print ] || [ "$(id -u)" = 0 ] || ! command -v xdg-open >/dev/null 2>&1; then
    echo "$url"
  else
    xdg-open "$url" >/dev/null 2>&1 || echo "$url"
  fi
  exit 0
fi

echo "Starting Ascella on http://localhost:$PORT"
echo "Data: ${ASCELLA_DATA:-$HOME/.ascella}"
echo "Press Ctrl-C to stop it. The apps it started keep running without it."
echo
exec "$here/bin/ascella" start
