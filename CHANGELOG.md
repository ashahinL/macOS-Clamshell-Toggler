# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
- **`clamshell blank [on|off]`** to control that, defaulting to `on`. Stored
  beside the mode file, so it needs no sudo either.
- **`blankWhenClosed` and `internalPanelOn` in `clamshell json`**, plus
  `blank when closed` and `built-in screen` lines in `clamshell status`.
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
