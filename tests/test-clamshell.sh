#!/bin/bash
#
# Behavioural tests for the mode → SleepDisabled decision.
#
# The display probe is stubbed with a fake `ioreg` on PATH, so the whole truth
# table can be exercised without physically unplugging a monitor. Run with:
#   ./tests/test-clamshell.sh
#
# SPDX-License-Identifier: MIT

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO
readonly CLAMSHELL="$REPO/bin/clamshell"

pass=0
fail=0

# Stub ioreg to report N attached external displays, then ask clamshell what
# SleepDisabled value the given mode resolves to.
want_with() {
	local displays="$1" mode="$2" tmp out i
	tmp="$(mktemp -d)"

	if [[ "$displays" == 'broken' ]]; then
		printf '#!/bin/sh\necho "ioreg: failure" >&2\nexit 1\n' > "$tmp/ioreg"
	else
		{
			echo '#!/bin/sh'
			for ((i = 0; i < displays; i++)); do
				echo "echo '+-o DisplayPort  <class IOPortTransportStateDisplayPort>'"
			done
			echo 'exit 0'
		} > "$tmp/ioreg"
	fi
	chmod +x "$tmp/ioreg"

	case "$mode" in
		missing) : ;;
		garbage) echo 'not-a-mode' > "$tmp/mode" ;;
		*)       echo "$mode" > "$tmp/mode" ;;
	esac

	out="$(PATH="$tmp:$PATH" CLAMSHELL_MODE_FILE="$tmp/mode" \
		"$CLAMSHELL" --want 2>/dev/null)"
	rm -rf "$tmp"
	printf '%s' "$out"
}

check() {
	local desc="$1" displays="$2" mode="$3" expected="$4" actual
	actual="$(want_with "$displays" "$mode")"
	if [[ "$actual" == "$expected" ]]; then
		printf '  \033[32mok\033[0m   %s\n' "$desc"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s (expected %s, got %s)\n' \
			"$desc" "$expected" "${actual:-<empty>}"
		fail=$((fail + 1))
	fi
}

printf '\n\033[1mmode → SleepDisabled\033[0m  (1 = stay awake with lid closed)\n\n'

check 'auto + monitor attached  → stay awake' 1 auto 1
check 'auto + two monitors      → stay awake' 2 auto 1
check 'auto + no monitor        → sleep'      0 auto 0
check 'on   + monitor attached  → stay awake' 1 on   1
check 'on   + no monitor        → stay awake' 0 on   1
check 'off  + monitor attached  → sleep'      1 off  0
check 'off  + no monitor        → sleep'      0 off  0

printf '\n\033[1mfail-safe\033[0m  (unknown state must never keep the Mac awake)\n\n'

check 'missing mode file        → auto'  1 missing 1
check 'garbage mode file        → auto'  0 garbage 0
check 'ioreg failure + auto     → sleep' broken auto 0

printf '\n\033[1mdaemon environment\033[0m  (launchd supplies PATH and nothing else)\n\n'

# Regression: an unbound $HOME under `set -u` used to kill the watcher on
# startup, which KeepAlive turned into a silent respawn loop.
env_err="$(env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin bash "$CLAMSHELL" --want 2>&1 >/dev/null)"
if [[ -z "$env_err" ]]; then
	printf '  \033[32mok\033[0m   starts with no HOME in the environment\n'
	pass=$((pass + 1))
else
	printf '  \033[31mFAIL\033[0m starts with no HOME: %s\n' "$env_err"
	fail=$((fail + 1))
fi

printf '\n\033[1msyntax\033[0m\n\n'
for f in "$REPO"/bin/clamshell "$REPO"/scripts/*.sh "$REPO"/tests/*.sh; do
	if bash -n "$f" 2>/dev/null; then
		printf '  \033[32mok\033[0m   %s parses\n' "${f#"$REPO"/}"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s\n' "${f#"$REPO"/}"
		fail=$((fail + 1))
	fi
done

if command -v shellcheck >/dev/null 2>&1; then
	printf '\n\033[1mshellcheck\033[0m\n\n'
	if shellcheck -s bash --severity=warning "$REPO"/bin/clamshell "$REPO"/scripts/*.sh "$REPO"/tests/*.sh; then
		printf '  \033[32mok\033[0m   clean\n'
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
	fi
fi

printf '\n%s passed, %s failed\n\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
