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

echo "Starting Ascella on http://localhost:$PORT"
echo "Data: ${ASCELLA_DATA:-$HOME/.ascella}"
echo "Press Ctrl-C to stop it. The apps it started keep running without it."
echo
exec "$here/bin/ascella" start
