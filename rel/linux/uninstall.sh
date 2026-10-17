#!/bin/sh
# Removes the Ascella program from a box installed with install.sh.
#
#   sudo /opt/ascella/uninstall.sh
#
# It removes the service, its units and /opt/ascella. It does NOT remove the
# data or the service's settings, and it does NOT remove the programs
# Ascella installed: they are services of their own, with uninstall.sh
# scripts of their own, and they run perfectly well without the program
# that put them there. The last lines say what is left.

set -eu

INSTALL_DIR="/opt/ascella"
DATA_DIR="/var/lib/ascella"
UNIT_DIR="/etc/systemd/system"

main() {
    [ "$(id -u)" = 0 ] || { echo "run this as root: sudo $0" >&2; exit 1; }

    for unit in ascella-update.path ascella-update.service ascella.service; do
        systemctl disable --now "$unit" >/dev/null 2>&1 || true
        rm -f "$UNIT_DIR/$unit"
    done
    systemctl daemon-reload || true

    # The program, and what the updater noted about its last run. Nothing
    # else: the two paths are spelled out so that no variable can be empty.
    rm -rf /opt/ascella
    rm -rf /var/lib/ascella-update

    echo "Ascella is removed from $INSTALL_DIR."
    echo "Your data is untouched, in $DATA_DIR, and so are the settings in /etc/ascella."
    echo "Installing Ascella again finds both."
    echo "The programs it installed are still installed, and still running."
    echo "To delete Ascella's data for good - there is no way back - that is yours to do:"
    echo "  the folder $DATA_DIR and the folder /etc/ascella."
}

main "$@"
