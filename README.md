# Clamshell

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011%2B-brightgreen.svg)
![Architecture: Apple Silicon](https://img.shields.io/badge/Arch-Apple%20Silicon-orange.svg)
![Version: 1.0.0](https://img.shields.io/badge/Version-1.0.0-purple.svg)

Use your Mac with the lid closed **on battery power** — no charger required.

macOS only supports closed-display ("clamshell") mode while the machine is plugged
in. Unplug the charger and the Mac sleeps the moment you shut the lid, even at 100%
battery. Clamshell fixes that, and does it *safely*: the lid-closed override is
enabled **only while an external display is actually attached**, so a laptop shut in
a bag still sleeps like it always did.

```
┌──────────────────────────────────────┐
│  Lid closed → stays awake            │
│  1 external display · lid closed ·   │
│  battery                             │
│ ──────────────────────────────────── │
│ ✓ Automatic     Awake only w/ display│
│   Always Awake  Even with no display │
│   Off           Normal macOS sleep   │
│ ──────────────────────────────────── │
│ ✓ Open at Login                      │
│   Open Log                           │
│   Quit                               │
└──────────────────────────────────────┘
```

The menu bar icon is a closed MacBook: **solid** when closing the lid will keep
the Mac awake, **outlined** when it will sleep, and a warning triangle if the
watcher has stopped.

## Features

- **Works on battery** — closed-lid operation without the charger plugged in
- **Safe by default** — the override only applies while an external display is connected
- **Menu bar app** — see the current state and switch modes in one click
- **No password after install** — mode switching writes a file in your home directory
- **Fails safe** — if anything is unreadable or unexpected, normal sleep wins
- **Survives reboots** — runs as a `launchd` system daemon
- **Tiny** — a shell script and a ~250-line menu bar app; no background frameworks
- **Cleanly reversible** — `sudo make uninstall` restores stock behaviour

## How it works

macOS keeps an undocumented power-management flag, `disablesleep`, which is what
actually governs whether closing the lid sleeps the machine:

```
external display attached?
        │
        ├── yes ──►  pmset -b disablesleep 1   ──►  lid closed = stays awake
        │
        └── no  ──►  pmset -b disablesleep 0   ──►  lid closed = sleeps (normal)
```

A small root daemon polls every 10 seconds and flips the flag when the state
changes. `-b` scopes the change to battery power, so behaviour on AC is untouched.

### Detecting an external display

The daemon runs with no GUI session, so the usual CoreGraphics display APIs are not
available. Instead it counts IOKit registry nodes carrying a `SinkDeviceOUI` key:

```sh
ioreg -r -k SinkDeviceOUI -d1 -w0 | awk '/^\+-o /{n++} END{print n+0}'
```

That key holds the manufacturer OUI read out of the monitor's EDID, so it exists
only when a display is *physically connected* over DisplayPort or HDMI. The built-in
panel never publishes it, which cleanly separates internal from external. The probe
costs about 23 ms.

## Requirements

- macOS 11 or later
- **Apple Silicon.** Developed and tested on an M4 running macOS 26. The display
  probe relies on the Apple Silicon display-coprocessor registry layout; Intel Macs
  expose displays differently and will likely need a different probe.

## Install

```sh
git clone https://github.com/ashahinL/macos-clamshell.git
cd macos-clamshell

make                    # build the menu bar app
sudo make install       # install the CLI, the watcher and the app
```

The installer prints the resulting state and tells you plainly whether the flag took
effect. Then launch the menu bar app:

```sh
open /Applications/Clamshell.app
```

Tick **Open at Login** in the menu to have it start automatically. That uses
`SMAppService` on macOS 13+, so the entry appears under System Settings → Login
Items; macOS may ask you to approve it there the first time. On older releases,
or if registration is refused for a locally built app, it falls back to a
LaunchAgent at `~/Library/LaunchAgents/local.clamshell.menubar.plist`.

## Usage

Click the menu bar icon to see the current state and switch modes. Everything is
also available from the command line:

```sh
clamshell            # status
clamshell auto       # awake with lid closed, only while a display is attached
clamshell on         # awake with lid closed, display or not
clamshell off        # normal macOS behaviour
clamshell log        # recent state changes
clamshell json       # machine-readable status
```

```
$ clamshell
clamshell 1.0.0

  mode                auto
  external displays   1
  lid                 closed
  power               Battery Power
  sleep disabled      1
  watcher             running (pid 6108)
  mode file           /Users/you/.config/clamshell/mode

→ Closing the lid keeps this Mac awake.
```

### Modes

| Mode | Display attached | No display | Use it for |
|---|---|---|---|
| `auto` *(default)* | stays awake | **sleeps** | Everyday desk use |
| `on` | stays awake | stays awake | Headless jobs — a long build or download with the lid shut |
| `off` | sleeps | sleeps | Temporarily restoring stock behaviour |

> **`on` keeps the Mac awake with no display attached.** In a closed bag that means
> battery drain and heat. Switch back to `auto` when you are done.

Switching modes never requires a password: the mode lives in
`~/.config/clamshell/mode`, and the root watcher reads it.

## Uninstall

```sh
sudo make uninstall
```

Or, from anywhere, without the repo checked out:

```sh
sudo clamshell-uninstall
```

Both unload the daemon, remove the installed files, and reset `disablesleep` to `0`.

## Testing

```sh
make test
```

The display probe is stubbed with a fake `ioreg` on `PATH`, so the full truth table
— including the no-display and probe-failure paths — is verified without physically
unplugging a monitor:

```
mode → SleepDisabled  (1 = stay awake with lid closed)

  ok   auto + monitor attached  → stay awake
  ok   auto + no monitor        → sleep
  ok   on   + no monitor        → stay awake
  ok   off  + monitor attached  → sleep

fail-safe  (unknown state must never keep the Mac awake)

  ok   missing mode file        → auto
  ok   garbage mode file        → auto
  ok   ioreg failure + auto     → sleep
```

## Troubleshooting

**Switching to `off` with the lid already closed does not sleep the Mac.**
Expected. macOS decides whether to sleep at the moment the lid closes; clearing
the flag afterwards does not retroactively trigger that decision, and nothing
re-evaluates until the next lid event. Open and close the lid and it sleeps.
Forcing it would mean calling `pmset sleepnow` behind your back, which is a
worse surprise than the wait.

**A mode switch takes a moment to take effect.** About a second. The watcher
re-reads the mode file every second and re-probes displays every five, so
closing the lid the instant after switching can still catch the old value.

**The flag does not flip.** Check that the watcher is alive and read its log:

```sh
clamshell status
clamshell log
cat /var/log/clamshell.err
```

**`clamshell status` says the watcher is not running.** Re-run `sudo make install`,
or load it manually:

```sh
sudo launchctl bootstrap system /Library/LaunchDaemons/local.clamshell.plist
```

**`external displays` reads 0 with a monitor plugged in.** The probe may not match
your hardware. Please open an issue including:

```sh
ioreg -r -k SinkDeviceOUI -d1 -w0 | head -40
```

**The menu bar icon is missing.** The app is a background agent with no Dock icon.
Confirm it is running with `pgrep -fl Clamshell`, then check whether the menu bar is
simply full — hidden items are common on notched displays.

## Layout

```
bin/clamshell                     CLI and watcher
launchd/local.clamshell.plist.in  LaunchDaemon template
gui/Clamshell/                    menu bar app (Swift/AppKit)
scripts/install.sh                installer
scripts/uninstall.sh              uninstaller
tests/test-clamshell.sh           behavioural tests
```

## License

MIT — see [LICENSE](LICENSE).
