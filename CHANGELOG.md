# Changelog

## 1.0 (2026-09-06)

First release.

- Menu bar dot with issue count. Green, yellow, red.
- Live stats: load, memory and memory pressure, swap, disk, uptime, power, thermal state.
- Per-app rollup: every helper and renderer summed under its parent app, with CPU as a share of the whole machine.
- Issues: stuck processes, processes working hard (compilers, encoders), apps taking over CPU or RAM, leaked helper processes, memory pressure, swap, disk, uptime, thermal.
- One-click remedies: stop a process, quit an app normally, clear everything, free disk, restart.
- Notifications with a Clear action.
- Thirty days of history. Recurring problems are called out as patterns.
- Runs as a user LaunchAgent and relaunches after a crash.
- `--snapshot` renders the panel to a PNG for checking the UI from a shell.
