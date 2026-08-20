# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.1.0] - 2026-08-20

### Added
- **The built-in screen now sleeps behind a closed lid.** Blocking the lid-close
  sleep left the panel fully lit: measured at a steady 3640 uA of backlight
  current across a full minute with the lid shut, on battery, in `on` mode. The
  watcher now calls `pmset displaysleepnow` once the lid has read closed on
  consecutive polls with no external display attached, which drops the display
  without touching the rest of the machine — wifi, audio and running jobs carry
  on. Guarded so it can only fire when nothing can be looking at a screen: the
  Mac must be held awake by clamshell, there must be **zero** external displays,
  and a single stray "closed" sample is not enough.
- **`clamshell blank [on|off]`** to control that, defaulting to `on`. Stored
  beside the mode file, so it needs no sudo either.
- **`blankWhenClosed` and `backlightMicroAmps` in `clamshell json`**, and a
  `blank when closed` line in `clamshell status`.

### Changed
- The watch loop probes displays once per poll and passes the count down, so
  adding the blanking check costs one extra `ioreg` rather than three.
- `CLAMSHELL_LOG_FILE` overrides the log path. A redirection bash cannot open
  makes it skip the command entirely, so an unwritable log silently stopped
  `pmset` being called at all — which is also what let the tests reach it.

[1.1.0]: https://github.com/ashahinL/macos-clamshell/releases/tag/v1.1.0

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

[1.0.0]: https://github.com/ashahinL/macos-clamshell/releases/tag/v1.0.0
