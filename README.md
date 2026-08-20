# Clamshell

![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
![Platform: macOS](https://img.shields.io/badge/Platform-macOS%2011%2B-brightgreen.svg)
![Architecture: Apple Silicon](https://img.shields.io/badge/Arch-Apple%20Silicon-orange.svg)
![Version: 1.1.0](https://img.shields.io/badge/Version-1.1.0-purple.svg)

Use your Mac with the lid closed **on battery power** — no charger required.

macOS only supports closed-display ("clamshell") mode while the machine is plugged
in. Unplug the charger and the Mac sleeps the moment you shut the lid, even at 100%
battery. Clamshell fixes that, and does it *safely*: the lid-closed override is
enabled **only while an external display is actually attached**, so a laptop shut in
a bag still sleeps like it always did.

```
┌──────────────────────────────────────┐
│  Lid closed → stays awake            │
│  1 display · closed · battery        │
│ ──────────────────────────────────── │
│ ✓ Automatic                          │
│   Always Awake                       │
│   Off                                │
│ ──────────────────────────────────── │
│ ✓ Open at Login                      │
│   Open Log                           │
│   Quit                               │
└──────────────────────────────────────┘
```

Each mode explains itself on hover. The menu bar icon is a laptop whose screen
carries the state: **lit** when the
Mac keeps running with the lid shut, **empty** when closing the lid will put it
to sleep, and a warning triangle if the watcher has stopped.

## Features

- **Works on battery** — closed-lid operation without the charger plugged in
- **Safe by default** — the override only applies while an external display is connected
- **Menu bar app** — see the current state and switch modes in one click
- **No password after install** — mode switching writes a file in your home directory
- **Screen off, machine on** — the built-in panel sleeps behind a closed lid
  instead of staying lit, while wifi, audio and running jobs carry on
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

A small root daemon flips the flag whenever the state changes. `-b` scopes the
change to battery power, so behaviour on AC is untouched.

The two inputs are polled at different rates, because they have different
urgency. The chosen mode is re-read **every second** — a mode switch is a
deliberate act and you may close the lid straight afterwards, so a stale flag
would look like the switch had failed. Displays are re-probed **every five
seconds**, since that probe costs ~23 ms and nothing races it.

### Turning the built-in screen off

Blocking the sleep leaves one thing behind: macOS never tells the built-in
display to go dark. Measured on an M4 Air in `on` mode, backlight current sat at
a steady 3640 µA for a full minute with the lid shut — heat and battery spent
lighting the inside of a closed laptop.

So once the lid has been shut for a couple of polls with **no external display
attached**, the daemon calls `pmset displaysleepnow`. That sleeps the display
alone; wifi, audio, downloads and any running job carry on. Opening the lid
wakes it as usual.

It is deliberately narrow. The screen is only ever put to sleep when all of
these hold, and the moment any stops holding the daemon backs off:

- the Mac is being held awake by clamshell in the first place
- **zero** external displays — `displaysleepnow` would take a monitor down with
  it, and that is the one screen you are actually looking at
- the lid has read closed on consecutive polls, so no single bad sample can
  blank a screen you are using

In practice that means it fires only in `on` mode with no monitor — the headless
case. With a monitor attached macOS already handles the internal panel, and in
`auto` mode with no monitor the machine simply sleeps.

Turn it off with `clamshell blank off` if you need the panel lit behind a closed
lid.

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
clamshell blank off  # keep the built-in screen lit behind a closed lid
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
  blank when closed   on
  watcher             running (pid 6108)
  mode file           /Users/you/.config/clamshell/mode

→ Closing the lid keeps this Mac awake.
```

### Modes

| Mode | Display attached | No display | Use it for |
|---|---|---|---|
| `auto` *(default)* | stays awake | **sleeps** | Everyday desk use |
| `on` | stays awake | stays awake, screen off | Headless jobs — a long build or download with the lid shut |
| `off` | sleeps | sleeps | Temporarily restoring stock behaviour |

> **`on` keeps the Mac awake with no display attached.** The built-in screen is
> put to sleep once the lid has been shut for a few seconds, so it is not also
> burning backlight — but the machine itself is still running. In a closed bag
> that is battery drain and heat. Switch back to `auto` when you are done.

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

daemon environment  (launchd supplies PATH and nothing else)

  ok   starts with no HOME in the environment

blanking the built-in screen  (a black screen nobody asked for is the worst outcome)

  ok   on + lid shut + no monitor  → screen off
  ok   stays off, re-armed not spammed
  ok   one closed sample alone     → left alone
  ok   monitor attached            → left alone
  ok   mac not held awake          → left alone
  ok   lid open                    → left alone
  ok   blanking turned off         → left alone
```

## Troubleshooting

**Switching to `off` with the lid already closed does not sleep the Mac.**
Expected. macOS decides whether to sleep at the moment the lid closes; clearing
the flag afterwards does not retroactively trigger that decision, and nothing
re-evaluates until the next lid event. Open and close the lid and it sleeps.
Forcing it would mean calling `pmset sleepnow` behind your back, which is a
worse surprise than the wait.

**The screen stays lit behind a closed lid.** Blanking only applies with no
external display attached, since `pmset displaysleepnow` would take a monitor
down with it. Check `clamshell blank` reads `on`, and `clamshell log` for a
`display asleep` line. With a monitor attached, macOS handles the internal panel
itself.

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
