#!/bin/sh
# Installs Ascella on a Linux box - a small PC or a Raspberry Pi in the hall -
# as a service that starts with the machine. Ascella then installs, updates,
# starts and stops the hall's other programs on that box.
#
#   curl -fsSL https://github.com/teapot-chess/Ascella/releases/latest/download/install.sh | sudo sh
#
# or, in a hall without internet, from a release unpacked on a stick:
#
#   tar -xzf ascella-linux-x86_64.tar.gz && sudo sh ascella/install.sh
#
# Options (after `sh -s --` when piped):
#   --version X.Y.Z   that release instead of the latest
#
# There is no --lan, and that is not an oversight. Ascella runs as root (it
# runs installers) and listens on 127.0.0.1, always. A box without a screen
# is reached through ssh, from the machine you are sitting at:
#
#   ssh -L 4090:127.0.0.1:4090 you@box     then http://localhost:4090
#
# What it does, and nothing more:
#   /opt/ascella            the program, owned by root; replaced by updates
#   /var/lib/ascella        the data, owned by root; never replaced, never
#                          removed - not by an update, not by uninstall.sh
#   /etc/ascella/ascella.env the service's one setting (the port); written
#                          once and then left to you
#   ascella.service, ascella-update.path, ascella-update.service
#
# No user of its own: the service runs as root, for the reason given in
# ascella.service.
#
# Run it again to repair an installation; it changes no setting and no data.
#
# Needs: a 64-bit system (x86_64 or arm64) with systemd and glibc 2.35 or
# newer - Debian 12, Ubuntu 22.04, Raspberry Pi OS (64-bit) "Bookworm", or
# later. The runtime is inside; nothing else is installed.

set -eu

REPO="teapot-chess/Ascella"
INSTALL_DIR="/opt/ascella"
DATA_DIR="/var/lib/ascella"
CONF_DIR="/etc/ascella"

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "install.sh: $*" >&2; exit 1; }

main() {
    wanted=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --version) wanted="$2"; shift 2 ;;
            -h | --help) sed -n '2,30p' "$0"; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done

    [ "$(id -u)" = 0 ] || die "run this as root (sudo)."
    [ "$(uname -s)" = Linux ] || die "this installs on Linux. For Windows there is Ascella-Setup.exe."
    command -v systemctl >/dev/null 2>&1 || die "this needs systemd, and found none."

    for tool in curl tar sha256sum; do
        command -v "$tool" >/dev/null 2>&1 || die "this needs '$tool', which is not installed."
    done

    case "$(uname -m)" in
        x86_64 | amd64) cpu=x86_64 ;;
        aarch64 | arm64) cpu=aarch64 ;;
        armv7l | armv6l) die "this is a 32-bit system ($(uname -m)). Ascella is built for 64-bit only: install the 64-bit Raspberry Pi OS." ;;
        *) die "there is no build for this processor ($(uname -m))." ;;
    esac

    # The runtime inside the release was built against glibc 2.35. On an
    # older system it dies at start with a line about GLIBC_2.3x; better to
    # say so here, in words.
    libc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
    if [ -n "$libc" ]; then
        major=${libc%%.*}
        minor=${libc#*.}
        minor=${minor%%.*}
        if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 35 ]; }; then
            die "this system's C library is glibc $libc; Ascella needs 2.35 or newer (Debian 12, Ubuntu 22.04, Raspberry Pi OS Bookworm)."
        fi
    else
        die "this system does not use glibc (Alpine?). There is no build for it."
    fi

    # A release this script stands in, or one to fetch.
    here=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || echo "")
    tmp=""
    trap 'if [ -n "$tmp" ]; then rm -rf "$tmp"; fi' EXIT

    if [ -z "$wanted" ] && [ -n "$here" ] && [ -x "$here/bin/ascella" ] && [ -r "$here/VERSION" ]; then
        src="$here"
        say "Installing the release in $src."
    else
        file="ascella-linux-$cpu.tar.gz"
        if [ -n "$wanted" ]; then
            base="https://github.com/$REPO/releases/download/v$wanted"
        else
            base="https://github.com/$REPO/releases/latest/download"
        fi

        tmp=$(mktemp -d /tmp/ascella-install.XXXXXX)
        say "Downloading $base/$file"
        curl -fsSL --retry 2 -o "$tmp/$file" "$base/$file" || die "the download did not succeed."
        curl -fsSL --retry 2 -o "$tmp/SHA256SUMS" "$base/SHA256SUMS" || die "the checksums could not be downloaded."
        (cd "$tmp" && grep " $file\$" SHA256SUMS | sha256sum -c - >/dev/null 2>&1) ||
            die "the download does not match its checksum."
        tar -xzf "$tmp/$file" -C "$tmp"
        src="$tmp/ascella"
    fi

    [ -x "$src/bin/ascella" ] || die "that is not an Ascella release: no bin/ascella in it."

    install -d -o root -g root -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/releases" "$CONF_DIR"
    install -d -o root -g root -m 0755 /var/lib/ascella-update
    install -d -o root -g root -m 0750 "$DATA_DIR"
    # Where the Setup page leaves its request for an update.
    install -d -o root -g root -m 0750 "$DATA_DIR/update"

    # Written once. An installation that is repaired or updated keeps what
    # the arbiter made of it.
    if [ ! -e "$CONF_DIR/ascella.env" ]; then
        {
            echo "# Settings of the Ascella service. Restart it after a change:"
            echo "#   sudo systemctl restart ascella"
            echo "PORT=4090"
            echo ""
            echo "# The user the hall's programs run as, and who may read the key to Ascella's"
            echo "# page (ascella.sh open). Without it Ascella starts no program and only root"
            echo "# can open the page. Example: your own login."
            echo "#ASCELLA_RUN_AS=pi"
            echo ""
            echo "# The address is not a setting: Ascella answers on 127.0.0.1 only."
            echo "# From another machine: ssh -L 4090:127.0.0.1:4090 <this box>"
        } >"$CONF_DIR/ascella.env"
        chmod 0644 "$CONF_DIR/ascella.env"
    fi

    # The release, the units and the two scripts: update.sh knows how, and
    # is how it is done every time after this one.
    sh "$src/update.sh" --from "$src" --no-restart

    systemctl daemon-reload
    systemctl enable ascella.service ascella-update.path >/dev/null 2>&1
    systemctl restart ascella-update.path
    systemctl restart ascella.service

    version=$(tr -d ' \t\r\n' <"$src/VERSION")
    say ""
    say "Ascella $version is installed and running."
    say "  The site:    on this box, and on this box only. Its page wants a key that only"
    say "               root and ASCELLA_RUN_AS (see $CONF_DIR/ascella.env) can read:"
    say "                 sh $INSTALL_DIR/current/ascella.sh open"
    say "               opens it in your browser (--print prints the link instead)."
    say "               From elsewhere: ssh -L 4090:127.0.0.1:4090 <this box>, and paste the link."
    say "  The data:    $DATA_DIR"
    say "  The program: $INSTALL_DIR"
    say "  Its log:     journalctl -u ascella"
    say "  Update:      on the Setup page, or: sudo $INSTALL_DIR/update.sh"
    say "  Remove:      sudo $INSTALL_DIR/uninstall.sh   (keeps the data)"
}

main "$@"
