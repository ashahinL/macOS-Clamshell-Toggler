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

[[ $EUID -eq 0 ]] || die 'run with sudo:  sudo clamshell-uninstall'

say 'unloading daemon'
launchctl bootout "system/$LABEL" 2>/dev/null || true

say 'removing files'
rm -f "$PLIST" /usr/local/bin/clamshell /usr/local/bin/clamshell-uninstall
rm -f /var/log/clamshell.log /var/log/clamshell.err /var/log/clamshell.err.prev

say 'restoring sleep behaviour'
pmset -b disablesleep 0 || true
pmset -a disablesleep 0 || true

echo
say "done — SleepDisabled is now $(pmset -g | awk '/SleepDisabled/{print $2}')"
echo '    Your ~/.config/clamshell/mode file was left in place.'
