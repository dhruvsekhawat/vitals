# Changelog

## 1.0.1 (2026-09-06)

- Releases are signed with Developer ID and notarized. Downloaded builds open with a double-click; no right-click, no quarantine workaround.
- Swap is judged against physical RAM instead of the size of the swap files, which grow on demand and made the old percentage meaningless.
- Per-app memory uses physical footprint, matching Activity Monitor, instead of resident size.
- An app whose CPU is mostly compilers, encoders, or indexers is reported as working hard rather than taking over, with no kill button.
- Quitting an app never escalates to a kill. If it declines, the panel says so and offers Kill explicitly.
- Escalations from warning to bad now notify. Verdicts no longer flap while the panel is open.
- Turning off start at login no longer stops the running app.
- One-line installer and a universal (Apple silicon and Intel) build.

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
