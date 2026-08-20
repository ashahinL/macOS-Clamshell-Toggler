#!/bin/bash
#
# Installs the clamshell watcher as a system LaunchDaemon.
# Usage: sudo ./scripts/install.sh
#
# SPDX-License-Identifier: MIT

set -euo pipefail

readonly LABEL='local.clamshell'
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"
readonly BIN='/usr/local/bin/clamshell'
readonly UNINSTALL_BIN='/usr/local/bin/clamshell-uninstall'

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == 'Darwin' ]] || die 'macOS only.'
[[ $EUID -eq 0 ]] || die 'run with sudo:  sudo ./scripts/install.sh'

# Who are we installing for? Not root — the mode file has to stay writable by
# the human, so switching modes later never needs a password.
TARGET_USER="${SUDO_USER:-}"
[[ -z "$TARGET_USER" || "$TARGET_USER" == 'root' ]] && TARGET_USER="$(stat -f '%Su' /dev/console)"
[[ -n "$TARGET_USER" && "$TARGET_USER" != 'root' ]] ||
	die 'cannot determine the login user; run via sudo as your normal account.'

TARGET_HOME="$(dscl . -read "/Users/$TARGET_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -d "$TARGET_HOME" ]] || die "cannot resolve home directory for $TARGET_USER"

MODE_DIR="$TARGET_HOME/.config/clamshell"
MODE_FILE="$MODE_DIR/mode"

say "installing for user: $TARGET_USER"

say "installing $BIN"
install -d -o root -g wheel -m 755 /usr/local/bin
install -o root -g wheel -m 755 "$REPO/bin/clamshell" "$BIN"

say "installing $UNINSTALL_BIN"
install -o root -g wheel -m 755 "$REPO/scripts/uninstall.sh" "$UNINSTALL_BIN"

say "creating $MODE_FILE"
install -d -o "$TARGET_USER" -g staff -m 755 "$MODE_DIR"
if [[ ! -f "$MODE_FILE" ]]; then
	echo auto > "$MODE_FILE"
	chown "$TARGET_USER:staff" "$MODE_FILE"
fi

say "installing $PLIST"
sed "s|__MODE_FILE__|$MODE_FILE|g" "$REPO/launchd/${LABEL}.plist.in" > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null || die 'generated plist is malformed'

say 'loading daemon'
launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

say 'waiting for first poll'
for _ in $(seq 1 15); do
	[[ "$(pmset -g | awk '/SleepDisabled/{print $2}')" == '1' ]] && break
	sleep 1
done

echo
sudo -u "$TARGET_USER" env CLAMSHELL_MODE_FILE="$MODE_FILE" "$BIN" status || true
echo

displays="$(ioreg -r -k SinkDeviceOUI -d1 -w0 2>/dev/null | awk '/^\+-o /{n++} END{print n+0}')"
if [[ "$(pmset -g | awk '/SleepDisabled/{print $2}')" == '1' ]]; then
	say 'installed — closing the lid now keeps this Mac awake.'
elif [[ "$displays" == '0' ]]; then
	say 'installed — no external display attached, so sleep is (correctly) still enabled.'
	echo '    Plug in a monitor and re-run `clamshell status` to verify.'
else
	warn 'a display is attached but SleepDisabled did not flip.'
	echo '    Check /var/log/clamshell.err and /var/log/clamshell.log'
fi
echo
echo "Uninstall any time with:  sudo clamshell-uninstall"
