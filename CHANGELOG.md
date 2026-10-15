# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.5.0] - 2026-10-15

### Changed
- **The watcher waits for events instead of polling.** Before, it checked the
  mode file every second and ran a full check every 5 seconds, starting several
  small programs each time. Activity Monitor ranked Clamshell high in energy
  use. A new helper, `clamshell-events`, watches the config folder, the lid,
  displays, the power source and battery level, Low Power Mode, the sleep flag
  and wake from sleep. It prints a line only when something changed. The
  watcher runs its check then, when a cutoff or the screen re-arm is due, and
  at least once a minute.
- **Measured on an M4 MacBook Air:** 12 hr Power in Activity Monitor went from
  14.68 to 1.68. The watcher and its helper went from 1.69 seconds of CPU per
  minute to about 0.1.
- **The helper decides nothing.** Every 5 seconds it re-reads the display
  count, the lid and the sleep flag itself, without starting any programs.
  All the rules stay in `bin/clamshell`.
- **Polling is the fallback.** If the helper is missing, never starts, exits or
  goes quiet for 150 seconds, the watcher logs `events helper gone (<reason>),
  polling` and goes back to the 1.4.0 polling.
- **Readings that confirm a cutoff count only 5 seconds apart.** The lid, the
  battery floor, Low Power Mode and resume on charger still need two readings,
  so two events a moment apart cannot confirm anything.
- **The app reads the status when the helper reports a change,** plus every 2
  minutes as a backstop, instead of every 15 seconds. Without the helper it
  goes back to every 15 seconds. The open panel still refreshes every 2
  seconds.
- **The installer, the uninstaller and the `.pkg` include the helper.** `make`
  builds it, and `make events` builds it alone. A missing helper is only a
  warning at install time.

### Fixed
- **Rewriting `on` within a second of a failed cut now counts.** If a cutoff
  could not write `off`, writing `on` again in the same second was ignored. The
  mode file check now uses the file time to the nanosecond.
- **A timer that fails to save no longer leaves Always Awake on.** `clamshell
  on` wrote the mode before the deadline, so a failed deadline write left `on`
  running with no timer. It now writes the deadline first. `clamshell timer`
  while on and resume on charger had the same order and are fixed the same way.
- **A display probe that fails part way counts as no display.** If `ioreg`
  printed some output and then failed, the partial count was used, which could
  keep the Mac awake in Automatic.
- **The menu bar icon no longer says "sleeps" when it cannot read the status.**
  It shows the warning icon and "Unable to read clamshell status", like the
  panel.
- **Uninstall removes the login agent.** When Open at Login fell back to a
  LaunchAgent, uninstall left it behind, pointing at the deleted app.
- **The panel closes when you click another menu bar icon.** It used to stay
  open under the other app's menu until you clicked the Clamshell icon again.
- **A home folder with a space in its path works.** The installer read the
  home path only up to the first space.

[1.5.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.5.0

## [1.4.0] - 2026-10-12

### Added
- **Always Awake comes back when you plug in.** After a battery floor or Low
  Power Mode cutoff, the watcher turns `on` back on once the Mac is on a
  charger. A floor cut while you were using the Mac left it off after charging,
  so every later lid close slept it.

[1.4.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.4.0

## [1.3.0] - 2026-10-10

### Changed
- **A panel replaces the menu.** Clicking the menu bar icon opens a panel with
  the state, a three-way mode switch, the auto-off and battery floor pickers,
  the Low Power Mode switch and Open at Login. Each hint is a short line that
  is always shown. The menu kept them in tooltips, and the tooltip on a submenu
  covered the submenu.
- **Values set from the CLI show as they are.** A 25% floor or a 45-minute
  timer appears in its picker instead of leaving nothing selected.
- **macOS 13 or later is required** (was 11). The panel's controls need it.

### Fixed
- **The battery floor now fires when the power source cannot be read.** Before,
  a failed `pmset -g batt` left Always Awake on until the battery ran out.
- **One missed Low Power Mode reading no longer ends the hold** that keeps
  Always Awake on when you chose it during Low Power Mode.
- **A cutoff fires once.** If writing `off` failed, every poll cut again, with
  a new log line, a new sleep attempt and a new notification each time.
- **The sleep flag is cleared even if the log cannot be opened.** Bash skipped
  the `pmset` call when its error redirect failed.
- **`clamshell json` stays valid** when the mode file path has a quote or a
  backslash in it.

### Added
- **A downloadable installer.** Each release has a `.pkg` that installs the app,
  the CLI and the watcher. It is not signed, so macOS asks you to allow it once.
- **`make preview`** draws the panel in five sample states, light and dark, to
  `build/preview/`.

[1.3.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.3.0

## [1.2.0] - 2026-10-09

### Added
- **A battery floor.** `clamshell floor [N|off]` turns Always Awake off once the
  battery is at or below N% on two polls in a row. Default 15%, range 5 to 50.
  It only applies on battery, so a plugged-in Mac never trips it.
- **An auto-off timer.** `clamshell timer [off|1h|2h|MIN]` turns Always Awake off
  a set time after it is switched on. The deadline is a file the root watcher
  enforces, so quitting the menu app or rebooting does not cancel it.
- **A Low Power Mode cutoff.** `clamshell lpm on` turns Always Awake off while on
  battery with Low Power Mode on. It is off by default. Choosing Always Awake
  while Low Power Mode is already on keeps it awake until Low Power Mode ends.
- **Sleeping a shut lid when a cutoff fires.** If the lid reads shut on two polls
  and no external display is attached, the watcher runs `pmset sleepnow`. An open
  lid or a monitor is left alone.
- **Menu controls for all of this.** Battery floor and Auto-off submenus, a Low
  Power Mode checkmark, a countdown row, an armed menu bar icon while Always Awake
  runs on battery, and a notification when a cutoff turns it off.
- **New fields in `clamshell json` and `clamshell status`.** Battery percent,
  floor, timer, Low Power Mode state and the last cutoff are now reported.

### Changed
- **Fewer `pmset` calls.** `pmset -g` and `pmset -g batt` are each read once per
  poll. The new cutoffs add no extra calls.
- **Corrected the AC note.** `-b` does not limit `disablesleep` to battery. On AC,
  `on` also keeps the Mac awake with the lid shut.

### Security
- **The watcher writes as the file owner.** Every write and delete in the config
  folder runs as the owner of the mode file, so a planted symlink cannot make
  root write through it.

[1.2.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.2.0

## [1.1.0] - 2026-08-20

### Added
- **The built-in screen now sleeps behind a closed lid.** Blocking the lid-close
  sleep left the panel fully lit: with this blanking disabled, 100 consecutive
  samples over 50s with the lid shut and no monitor attached showed the built-in
  panel's `IOMFBBrightnessLevel` holding at 10047921 and never reaching 0. Docked,
  the same probe reads 0, so macOS handles real clamshell mode and only the
  headless case stays lit. The
  watcher now calls `pmset displaysleepnow` once the lid has read closed on
  consecutive polls with no external display attached, which drops the display
  without touching the rest of the machine — wifi, audio and running jobs carry
  on. Guarded so it can only fire when nothing can be looking at a screen: the
  Mac must be held awake by clamshell, there must be **zero** external displays,
  and a single stray "closed" sample is not enough.
- **`clamshell screen [on|off]`** to control that: `off` (the default) means the
  built-in screen goes dark once the lid is shut, `on` keeps it lit. Stored
  beside the mode file, so it needs no sudo either.
- **`screenWhenClosed` and `internalPanelOn` in `clamshell json`**, plus
  `screen when closed` and `built-in screen` lines in `clamshell status`.
  `internalPanelOn` is a tri-state — `null` when the panel state cannot be read,
  since "cannot tell" must not be reported as "off".

### Fixed
- **CI was failing.** `LABEL` in `bin/clamshell` had been unused since the
  initial commit and is an SC2034 warning, which `shellcheck --severity=warning`
  exits non-zero on, failing `make test`. Removed.
- **`clamshell status` pointed at a command that does not exist.** When the
  watcher was not running it advised `sudo clamshell-install`; only
  `clamshell-uninstall` is ever installed. It now prints the `launchctl
  bootstrap` line that actually starts the daemon.
- **Every GitHub URL pointed at the wrong repository**, in the CLI header, the
  `help` output, the README, CONTRIBUTING and the CHANGELOG release links.
- **The app bundle version had drifted** a release behind the CLI. Bumped, and
  the suite now asserts the two match so it cannot drift silently again.
- **"Open Log" did nothing when no log existed yet**, which reads as a broken
  menu item. It is greyed out until the watcher has recorded a change.
- **The panel-state probe was measuring the wrong thing.** `AppleARMBacklight`'s
  `BrightnessMicroAmps` tracks the *configured* backlight current for the current
  brightness setting, and read an identical 3640 with the lid open, closed and
  docked, and closed and undocked — including while the panel was demonstrably
  off. It reports what brightness is selected, not whether anything is lit. The
  probe now reads `IOMFBBrightnessLevel` from the built-in framebuffer, the node
  matched as `disp0` (external ports appear as `dispext0`/`dispext1` and report a
  constant 65536), which reads 0 when the panel is off.

### Changed
- **The menu bar app polls only when someone is looking.** `clamshell json`
  spawns half a dozen short-lived processes and costs ~140ms; running it every
  2s whether or not the menu was open burned a steady ~7% of a core in an app
  whose purpose is saving battery. Now 2s while the menu is open and 15s while
  it is shut, which is ample for the icon.
- **A reinstall now starts against an empty error log.** Errors left by a
  version that has just been replaced read as live failures — a stale
  `HOME: unbound variable` from an already-fixed crash loop looked like a fresh
  one. The installer rotates `/var/log/clamshell.err` to `.err.prev` between
  `bootout` and `bootstrap`, the only window where launchd does not hold the
  file open. Rotated rather than deleted, one generation deep, so reinstalling
  to fix a problem does not throw away the evidence of it.
- The watch loop probes displays once per poll and passes the count down, so
  adding the blanking check costs one extra `ioreg` rather than three.
- `CLAMSHELL_LOG_FILE` overrides the log path. A redirection bash cannot open
  makes it skip the command entirely, so an unwritable log silently stopped
  `pmset` being called at all — which is also what let the tests reach it.

[1.1.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.1.0

## [1.0.0] - 2026-08-20

### Added
- **Closed-lid operation on battery** via pmset's `disablesleep` flag, scoped to
  battery power so behaviour on AC is unchanged.
- **Display-aware watcher** running as a `launchd` system daemon. The override is
  enabled only while an external display is attached, so a lid closed with no
  monitor still sleeps normally.
- **External display detection** through IOKit `SinkDeviceOUI` registry nodes,
  which works without a GUI session and costs ~23 ms per poll.
- **Sub-second mode switching.** The watcher re-reads the mode file every
  second and re-probes displays every five, so switching mode and immediately
  closing the lid no longer races a stale flag.
- **Three modes** — `auto` (display-aware), `on` (always awake), `off` (stock
  behaviour) — switchable without sudo via `~/.config/clamshell/mode`.
- **Menu bar app** (Swift/AppKit, `LSUIElement`) showing live state and offering
  one-click mode switching.
- **Custom laptop icon**, drawn with `NSBezierPath` so the two states differ in
  the place that carries the meaning: a lit screen means the Mac keeps running
  with the lid shut, an empty one means it will sleep. A warning triangle means
  the watcher has stopped.
- **Compact menu.** Mode explanations are tooltips rather than inline subtitles,
  and hidden warnings carry no title — `isHidden` stops an item drawing but
  AppKit still measures it, so hidden text was padding the menu's width.
- **Open at Login** toggle using `SMAppService` on macOS 13+, falling back to a
  LaunchAgent when registration is refused for a locally built app.
- **`clamshell json`** for machine-readable status.
- **Behavioural test suite** stubbing the display probe on `PATH`, covering the
  full mode truth table plus fail-safe paths.
- **Installer and uninstaller** that resolve the invoking user, generate the
  LaunchDaemon from a template, and self-verify the result.

[1.0.0]: https://github.com/ashahinL/macOS-Clamshell-Toggler/releases/tag/v1.0.0
