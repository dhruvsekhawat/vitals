# Security

Vitals runs as you, reads every process you own, and on request kills processes, quits apps, deletes cache directories, and writes a LaunchAgent. A bug in the wrong place could stop something you cared about or delete something you needed. That makes it worth reporting quietly first.

## Reporting

Use GitHub's private reporting: https://github.com/dhruvsekhawat/vitals/security/advisories/new

Include the version (`Vitals --version`), macOS version, and enough detail to reproduce. You should hear back within a week.

## What counts

- Any way to make `Remedies` act on a process or path outside the ones the panel showed
- Any way for another user or process on the machine to influence what Vitals kills or deletes
- Command lines or other process data leaving memory (they are never meant to be logged or persisted)
- A crash that launchd would relaunch into repeatedly

## What does not

- Vitals killing a process you explicitly clicked Kill on
- Thresholds you can change with `defaults write`
- The app not being sandboxed. It cannot be; see `Vitals.entitlements`.
