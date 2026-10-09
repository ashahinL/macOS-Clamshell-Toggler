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

printf '\n\033[1mthe built-in screen\033[0m  (a black screen nobody asked for is the worst outcome)\n\n'

# maybe_sleep_display is driven directly rather than through the watch loop:
# --watch demands root, and these cases need the lid, the display count and the
# preference varied independently. Sourcing with `version` defines every
# function without starting anything.
screen_check() { # name expected_calls polls want displays lid_rc pref
	local name="$1" expect="$2" polls="$3" want="$4" disp="$5" lid="$6" pref="$7" got
	got="$(
		set -- version
		export CLAMSHELL_LOG_FILE="$screen_log"
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		lid_is_closed() { return "$lid"; }
		read_screen()   { printf '%s' "$pref"; }
		pmset()         { printf 'pmset %s\n' "$*" >> "$screen_calls"; return 0; }
		: > "$screen_calls"
		for ((i = 0; i < polls; i++)); do maybe_sleep_display "$want" "$disp"; done
		/usr/bin/grep -c displaysleepnow "$screen_calls" 2>/dev/null || true
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

screen_log="$(mktemp)"
screen_calls="$(mktemp)"

# pref: `off` = screen goes dark when the lid shuts (default), `on` = stays lit.
#            name                                       calls polls want disp lid pref
screen_check 'lid shut, no monitor       → screen off'     1     2    1    0   0  off
screen_check 'stays off, re-armed not spammed'             1    10    1    0   0  off
screen_check 'one closed sample alone    → left alone'     0     1    1    0   0  off
screen_check 'monitor attached           → left alone'     0     5    1    1   0  off
screen_check 'mac not held awake         → left alone'     0     5    0    0   0  off
screen_check 'lid open                   → left alone'     0     5    1    0   1  off
# Deliberately lid-CLOSED: with the lid open this would pass on the lid check
# alone and never exercise the preference at all.
screen_check 'user asked to keep it lit  → left alone'     0     5    1    0   0  on

rm -f "$screen_log" "$screen_calls"

printf '\n\033[1mthe sleep flag\033[0m  (other tools write it too)\n\n'

# Same sourcing trick as above. `live` is what pmset reports right now.
flag_check() { # name expected_writes want live
	local name="$1" expect="$2" want="$3" live="$4" got
	got="$(
		set -- version
		export CLAMSHELL_LOG_FILE="$flag_log"
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		pmset() { printf 'pmset %s\n' "$*" >> "$flag_calls"; return 0; }
		: > "$flag_calls"
		apply_sleep_flag "$want" 0 "$live"
		/usr/bin/grep -c "disablesleep $want" "$flag_calls" 2>/dev/null || true
	)"
	got="${got:-0}"
	if [[ "$got" == "$expect" ]]; then
		printf '  \033[32mok\033[0m   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s — expected %s write(s), got %s\n' "$name" "$expect" "$got"
		fail=$((fail + 1))
	fi
}

flag_log="$(mktemp)"
flag_calls="$(mktemp)"

#          name                                      writes want live
flag_check 'reset behind our back      → rewritten'     1     1    0
flag_check 'already set                → left alone'    0     1    1
flag_check 'unreadable, want sleep     → written'       1     0    ''

rm -f "$flag_log" "$flag_calls"

printf '\n\033[1mpower readings\033[0m  (one pmset call each per pass)\n\n'

# Same sourcing trick. `batt` is `pmset -g batt`, `settings` is `pmset -g`.
# The stub returns 1 when it prints nothing, as pmset does on failure.
readings_check() { # name expected batt settings
	local name="$1" expect="$2" batt="$3" settings="$4" got
	got="$(
		set -- version
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		pmset() {
			local out
			# $2, not "$*": IFS is '|' here, because the read prefix reaches the process substitution.
			if [[ "${2:-}" == batt ]]; then out="$batt"; else out="$settings"; fi
			printf '%s' "$out"
			[[ -n "$out" ]]
		}
		read_power_settings
		read_battery
		printf '%s|%s|%s|%s' "$PM_SLEEP_DISABLED" "$PM_LOW_POWER" "$PM_SOURCE" "$PM_PERCENT"
	)"
	if [[ "$got" == "$expect" ]]; then
		printf '  \033[32mok\033[0m   %s\n' "$name"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s — expected %s, got %s\n' "$name" "$expect" "$got"
		fail=$((fail + 1))
	fi
}

ac_70=$'Now drawing from \'AC Power\'\n -InternalBattery-0 (id=1)\t70%; charging; 0:40 remaining present: true'
ac_85=$'Now drawing from \'AC Power\'\n -InternalBattery-0 (id=1)\t85%; charged; 0:00 remaining present: true'
batt_14=$'Now drawing from \'Battery Power\'\n -InternalBattery-0 (id=1)\t14%; discharging; 1:05 remaining present: true'
batt_nopct="Now drawing from 'Battery Power'"
settings_on=$' SleepDisabled\t\t1\n lowpowermode\t\t1'
settings_off=$' SleepDisabled\t\t0\n lowpowermode\t\t0'

#           name                                   expected          batt        settings
readings_check 'AC, charging, 70%                → AC Power, 70'     '||AC Power|70'    "$ac_70"    ''
readings_check 'AC, charged, 85%                 → AC Power, 85'     '||AC Power|85'    "$ac_85"    ''
readings_check 'battery, 14%                     → Battery Power, 14' '||Battery Power|14' "$batt_14" ''
readings_check 'battery, no percentage line      → percent empty'    '||Battery Power|' "$batt_nopct" ''
readings_check 'SleepDisabled and low power on   → 1, 1'             '1|1||'            ''          "$settings_on"
readings_check 'SleepDisabled and low power off  → 0, 0'             '0|0||'            ''          "$settings_off"
readings_check 'pmset prints nothing             → all empty'        '|||'              ''          ''

printf '\n\033[1mbattery floor\033[0m  (a closed Mac must not drain itself flat)\n\n'

expect_eq() { # name expected actual
	if [[ "$3" == "$2" ]]; then
		printf '  \033[32mok\033[0m   %s\n' "$1"
		pass=$((pass + 1))
	else
		printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       got:      %s\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

cut_dir="$(mktemp -d)"
[[ -d "$cut_dir" ]] || { printf 'battery floor: no temp dir\n' >&2; exit 1; }

# Runs maybe_cut `polls` times against a real mode file in a temp dir. pmset
# and sudo are stubs; sudo still runs the command, as the current user, so the
# writes really happen. `pct` is a number, or `none` for a line without one.
cut_run() { # mode source pct floor lid displays polls
	local mode="$1" src="$2" pct="$3" floor="$4"
	export cut_lid="$5" cut_disp="$6" cut_polls="$7" cut_src="$src" cut_pct="$pct"
	rm -f "$cut_dir/mode" "$cut_dir/floor" "$cut_dir/last-cut" "$cut_dir/until"
	printf '%s\n' "$mode" > "$cut_dir/mode"
	[[ -z "$floor" ]] || printf '%s\n' "$floor" > "$cut_dir/floor"
	: > "$cut_dir/log"; : > "$cut_dir/calls"; : > "$cut_dir/batt"
	(
		set -- version
		export CLAMSHELL_MODE_FILE="$cut_dir/mode" CLAMSHELL_LOG_FILE="$cut_dir/log"
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		lid_is_closed() { return "$cut_lid"; }
		pmset() {
			if [[ "${1:-}" == -g && "${2:-}" == batt ]]; then
				echo x >> "$cut_dir/batt"
				printf "Now drawing from '%s'\n" "$cut_src"
				[[ "$cut_pct" == none ]] ||
					printf ' -InternalBattery-0 (id=1)\t%s%%; discharging; 0:40 remaining present: true\n' "$cut_pct"
			else
				printf 'pmset %s\n' "$*" >> "$cut_dir/calls"
			fi
		}
		sudo() { printf 'sudo %s\n' "$*" >> "$cut_dir/calls"; shift 3; "$@"; }
		for ((i = 0; i < cut_polls; i++)); do maybe_cut "$cut_disp"; done
	)
}

# One line: mode, how many floor cuts were logged, the pmset writes in order.
cut_summary() {
	printf 'mode=%s cuts=%s pmset=[%s]' \
		"$(tr -d '[:space:]' < "$cut_dir/mode")" \
		"$(/usr/bin/grep -c 'cut reason=floor' "$cut_dir/log" || true)" \
		"$(/usr/bin/grep '^pmset ' "$cut_dir/calls" | sed 's/^pmset //' | paste -sd';' -)"
}

tripped='mode=off cuts=1 pmset=[-b disablesleep 0;sleepnow]'
quiet='mode=on cuts=0 pmset=[]'

cut_run on 'Battery Power' 14 '' 0 0 2
expect_eq 'on, battery 14%, floor 15, 2 polls, lid shut, no monitor → cut, then sleep' "$tripped" "$(cut_summary)"
expect_eq 'the cut is logged with reason and percent' 1 \
	"$(/usr/bin/grep -c 'cut reason=floor percent=14$' "$cut_dir/log" || true)"
last_cut="$(cat "$cut_dir/last-cut" 2>/dev/null)"
expect_eq 'last-cut records reason, epoch and percent' 1 \
	"$([[ "$last_cut" =~ ^floor\ [0-9]+\ 14$ ]] && echo 1 || echo 0)"
expect_eq 'every watcher write ran as the file owner via sudo' 3 \
	"$(/usr/bin/grep -c "^sudo -n -u #$(id -u) " "$cut_dir/calls" || true)"

cut_run on 'Battery Power' 14 '' 0 0 1
expect_eq 'one poll under the floor → nothing yet' "$quiet" "$(cut_summary)"
cut_run on 'Battery Power' 14 off 0 0 5
expect_eq 'floor off → no cut' "$quiet" "$(cut_summary)"
cut_run on 'AC Power' 10 '' 0 0 5
expect_eq 'on AC at 10% → no cut' "$quiet" "$(cut_summary)"
cut_run auto 'Battery Power' 10 '' 0 0 5
expect_eq 'auto mode ignores the floor' 'mode=auto cuts=0 pmset=[]' "$(cut_summary)"
expect_eq 'auto mode does not even read the battery' 0 "$(wc -l < "$cut_dir/batt" | tr -d ' ')"
cut_run on 'Battery Power' 14 '' 1 0 2
expect_eq 'lid open → cut, but no sleepnow' 'mode=off cuts=1 pmset=[-b disablesleep 0]' "$(cut_summary)"
cut_run on 'Battery Power' 14 '' 0 1 2
expect_eq 'monitor attached → cut, but no sleepnow' 'mode=off cuts=1 pmset=[-b disablesleep 0]' "$(cut_summary)"
cut_run on 'Battery Power' none '' 0 0 2
expect_eq 'battery with no percentage → cut (fail-safe)' "$tripped" "$(cut_summary)"
cut_run on 'Battery Power' 14 banana 0 0 2
expect_eq 'garbage floor file → treated as 15' "$tripped" "$(cut_summary)"
cut_run on 'Battery Power' 16 '' 0 0 2
expect_eq 'above the floor → no cut' "$quiet" "$(cut_summary)"

# read_floor and write_floor, in a temp dir.
floor_check() { # name expected command...
	local name="$1" expect="$2"; shift 2
	local cmd=("$@")   # `set -- version` below replaces $@
	expect_eq "$name" "$expect" "$(
		set -- version
		export CLAMSHELL_MODE_FILE="$cut_dir/mode"
		# shellcheck disable=SC1090
		source "$CLAMSHELL" >/dev/null
		rm -f "$cut_dir/floor"
		( "${cmd[@]}" ) >/dev/null 2>&1; echo "rc=$? $(read_floor)"
	)"
}
floor_check 'floor 3 is clamped up to 5'    'rc=0 5'  write_floor 3
floor_check 'floor 80 is clamped down to 50' 'rc=0 50' write_floor 80
floor_check 'floor off is stored'           'rc=0 off' write_floor off
floor_check 'floor x is refused'            'rc=1 15' write_floor x
floor_check 'no floor file reads as 15'     'rc=0 15' true

# After a cut the mode file may still say `on` (root-owned, sudo broken). The
# cut has to hold anyway, until the mode file changes.
held="$(
	set -- version
	export CLAMSHELL_MODE_FILE="$cut_dir/mode"
	# shellcheck disable=SC1090
	source "$CLAMSHELL" >/dev/null
	printf 'on\n' > "$cut_dir/mode"
	CUT_STAMP=$(mode_stamp)
	if held_by_cut; then a=true; else a=false; fi
	printf 'auto\n' > "$cut_dir/mode"
	if held_by_cut; then b=true; else b=false; fi
	printf '%s %s [%s]' "$a" "$b" "$CUT_STAMP"
)"
expect_eq 'a cut holds until the mode file changes' 'true false []' "$held"

rm -rf "$cut_dir"

printf '\n\033[1minstaller\033[0m\n\n'

# The error log is rotated so a reinstall does not present stale failures as
# live ones. It has to happen in the window where nothing holds the file open:
# launchd owns StandardErrorPath, so truncating after `bootstrap` would race the
# daemon it just started. Assert the ordering, since a later edit could move it
# without anything else noticing.
inst="$REPO/scripts/install.sh"
line_of() { /usr/bin/grep -n "$1" "$inst" | head -1 | cut -d: -f1; }
n_bootout="$(line_of 'launchctl bootout')"
n_rotate="$(line_of 'mv -f "\$ERR_LOG"')"
n_bootstrap="$(line_of 'launchctl bootstrap')"

if [[ -n "$n_bootout" && -n "$n_rotate" && -n "$n_bootstrap" ]] &&
   (( n_bootout < n_rotate && n_rotate < n_bootstrap )); then
	printf '  \033[32mok\033[0m   error log is rotated between bootout and bootstrap\n'
	pass=$((pass + 1))
else
	printf '  \033[31mFAIL\033[0m error log rotation is outside the bootout/bootstrap window\n'
	printf '       bootout=%s rotate=%s bootstrap=%s\n' \
		"${n_bootout:-?}" "${n_rotate:-?}" "${n_bootstrap:-?}"
	fail=$((fail + 1))
fi

# Rotate, do not delete: reinstalling to fix a problem must not destroy the
# evidence of it.
if /usr/bin/grep -q 'ERR_LOG_PREV' "$inst" && ! /usr/bin/grep -q 'rm -f "\$ERR_LOG"' "$inst"; then
	printf '  \033[32mok\033[0m   previous error log is kept, not deleted\n'
	pass=$((pass + 1))
else
	printf '  \033[31mFAIL\033[0m previous error log is not preserved\n'
	fail=$((fail + 1))
fi

# ...and the uninstaller has to take the rotated copy with it.
if /usr/bin/grep -q 'clamshell.err.prev' "$REPO/scripts/uninstall.sh"; then
	printf '  \033[32mok\033[0m   uninstall removes the rotated log too\n'
	pass=$((pass + 1))
else
	printf '  \033[31mFAIL\033[0m uninstall leaves clamshell.err.prev behind\n'
	fail=$((fail + 1))
fi

printf '\n\033[1mversions\033[0m\n\n'

# The app bundle carries its own version string, which drifted to a release
# behind the CLI once already. Nothing at build time reconciles them, so assert
# it here.
cli_version="$("$CLAMSHELL" version)"
plist_version="$(plutil -extract CFBundleShortVersionString raw "$REPO/gui/Clamshell/Info.plist" 2>/dev/null)"
if [[ "$cli_version" == "$plist_version" ]]; then
	printf '  \033[32mok\033[0m   app bundle version matches the CLI (%s)\n' "$cli_version"
	pass=$((pass + 1))
else
	printf '  \033[31mFAIL\033[0m version drift — CLI %s, Info.plist %s\n' \
		"$cli_version" "$plist_version"
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
