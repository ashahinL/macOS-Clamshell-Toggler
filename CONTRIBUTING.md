# Contributing

Thanks for taking a look.

## Getting set up

```sh
git clone https://github.com/ashahinL/macos-clamshell.git
cd macos-clamshell
make          # build the menu bar app
make test     # run the tests
```

## Before opening a pull request

- `make test` passes. It runs the behavioural suite, checks that every script
  parses, and runs `shellcheck` when it is installed (`brew install shellcheck`).
- New behaviour comes with a test. The suite stubs `ioreg` on `PATH`, so you can
  cover display states without physically unplugging anything — see
  `tests/test-clamshell.sh`.
- Shell style matches what is there: tabs, `set -uo pipefail`, and functions that
  do one thing.

## The rule that matters

**An unknown state must never keep the Mac awake.** Anything unreadable,
unparseable, or unexpected has to resolve to "let it sleep". A machine that
wrongly sleeps is a small annoyance; a machine that wrongly stays awake in a
closed bag gets hot and flattens its battery. The fail-safe tests exist to
protect that property — please keep them passing.

## Porting to Intel

The display probe relies on the Apple Silicon display-coprocessor registry
layout. Intel Macs expose displays differently and will need a different probe.
If you want to take that on, `external_displays()` in `bin/clamshell` is the only
function that needs to change. Please include the output of:

```sh
ioreg -r -k SinkDeviceOUI -d1 -w0 | head -40
```

## Reporting a bug

Include your macOS version, your Mac model, and the output of:

```sh
clamshell status
clamshell log
```
