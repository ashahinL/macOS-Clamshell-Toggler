#!/bin/bash
#
# Removes the clamshell watcher and restores stock macOS sleep behaviour.
# Usage: sudo clamshell-uninstall     (or: sudo ./scripts/uninstall.sh)
#
# SPDX-License-Identifier: MIT

set -euo pipefail

readonly LABEL='local.clamshell'
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# The plist form keeps a home path with spaces whole.
home_of() {
	dscl -plist . -read "/Users/$1" NFSHomeDirectory 2>/dev/null |
		plutil -extract 'dsAttrTypeStandard:NFSHomeDirectory.0' raw -o - - 2>/dev/null
}

# Open at Login may have fallen back to a LaunchAgent in the user's home.
remove_login_agent() {
	local user="${SUDO_USER:-}" home agent
	[[ -z "$user" || "$user" == 'root' ]] && user="$(stat -f '%Su' /dev/console)"
	home="$(home_of "$user" || true)"
	agent="$home/Library/LaunchAgents/local.clamshell.menubar.plist"
	[[ -n "$home" && -e "$agent" ]] || return 0
	say 'removing the login agent'
	launchctl bootout "gui/$(id -u "$user")/local.clamshell.menubar" 2>/dev/null || true
	rm -f "$agent"
}

[[ $EUID -eq 0 ]] || die 'run with sudo:  sudo clamshell-uninstall'

say 'unloading daemon'
launchctl bootout "system/$LABEL" 2>/dev/null || true

remove_login_agent

say 'removing files'
echo '    /Applications/Clamshell.app, the CLI, the event helper, the watcher and the logs'
pkill -x Clamshell || true
rm -f "$PLIST" /usr/local/bin/clamshell /usr/local/bin/clamshell-events /usr/local/bin/clamshell-uninstall
rm -rf /Applications/Clamshell.app
rm -f /var/log/clamshell.log /var/log/clamshell.err /var/log/clamshell.err.prev
pkgutil --forget local.clamshell.pkg >/dev/null 2>&1 || true

say 'restoring sleep behaviour'
pmset -b disablesleep 0 || true
pmset -a disablesleep 0 || true

echo
say "done — SleepDisabled is now $(pmset -g | awk '/SleepDisabled/{print $2}')"
echo '    Your settings in ~/.config/clamshell were left in place.'
