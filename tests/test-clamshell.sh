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

printf '\n\033[1mblanking the built-in screen\033[0m  (a black screen nobody asked for is the worst outcome)\n\n'

# maybe_sleep_display is driven directly rather than through the watch loop:
# --watch demands root, and these cases need the lid, the display count and the
# preference varied independently. Sourcing with `version` defines every
# function without starting anything.
blank_check() { # name expected_calls polls want displays lid_rc pref
	local name="$1" expect="$2" polls="$3" want="$4" disp="$5" lid="$6" pref="$7" got
	got="$(
		set -- version
		export CLAMSHELL_LOG_FILE="$blank_log"
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		lid_is_closed() { return "$lid"; }
		read_blank()    { printf '%s' "$pref"; }
		pmset()         { printf 'pmset %s\n' "$*" >> "$blank_calls"; return 0; }
		: > "$blank_calls"
		for ((i = 0; i < polls; i++)); do maybe_sleep_display "$want" "$disp"; done
		/usr/bin/grep -c displaysleepnow "$blank_calls" 2>/dev/null || true
	)"
	got="${got:-0}"
	if [[ "$got" == "$expect" ]]; then
		printf '  \033[32mok\033[0m   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s — expected %s call(s), got %s\n' "$name" "$expect" "$got"
		fail=$((fail + 1))
	fi
}

blank_log="$(mktemp)"
blank_calls="$(mktemp)"

#           name                                       calls polls want disp lid pref
blank_check 'on + lid shut + no monitor  → screen off'     1     2    1    0   0  on
blank_check 'stays off, re-armed not spammed'              1    10    1    0   0  on
blank_check 'one closed sample alone     → left alone'     0     1    1    0   0  on
blank_check 'monitor attached            → left alone'     0     5    1    1   0  on
blank_check 'mac not held awake          → left alone'     0     5    0    0   0  on
blank_check 'lid open                    → left alone'     0     5    1    0   1  on
blank_check 'blanking turned off         → left alone'     0     5    1    0   1  off

rm -f "$blank_log" "$blank_calls"

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
