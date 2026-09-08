# Decisions

Durable calls and why. Newest first. Reverse one by adding a new entry that names the old rationale.

## 2026-09-08: Memory hogs get advice, not a Quit button

An app holding a large share of RAM is reported only when the kernel says memory is under pressure, and the fix offered is closing tabs or windows. Quitting the app the user is working in is not a fix for a 16 GB machine running a 28 GB workload. CPU hogs keep their Quit, since a runaway process is a different thing.

## 2026-09-07: Storage moves to the Trash, only the user empties it

Nothing in the Storage window unlinks a file. Items go to the Trash with `FileManager.trashItem`, which is instant and recoverable. Emptying goes through Finder after a confirmation, because `~/.Trash` is protected and because Finder emptying is what people expect. Installers and Spotify's music cache are never pre-selected; a `.dmg` can be a vault someone keeps on purpose.

## 2026-09-06: Swap is judged against RAM, not swap file size

macOS grows swap files on demand, so used/total sits near 100% whenever any swap exists. Thresholds are 25% and 50% of physical RAM. Snapshots store bytes.

## 2026-09-06: LaunchAgent, not SMAppService

The app registers a user LaunchAgent with KeepAlive on unsuccessful exit so a crash relaunches it. SMAppService cannot do that, and it refused ad hoc signed bundles on the author's machine. The app detects when it is the launchd job (`XPC_SERVICE_NAME`) so it never boots itself out.

## 2026-09-06: No dependencies, no Electron

The app is Swift, SwiftUI, AppKit, libproc and IOKit only. The project exists because two Electron renderers pinned a laptop for nineteen days; shipping Electron to fix that would be a joke. A dependency has to earn its place against the standard library and the platform.

## 2026-09-06: Sizes and CPU come from the kernel, and are tested against it

Per-process CPU is a delta of `proc_taskinfo` time in Mach ticks converted with `mach_timebase_info`. Memory is `ri_phys_footprint`. Disk sizes come from `fts` with hard links counted once. Each of these had a silent bug in an early build; each now has an integration test that measures a real process or a real directory tree.

## 2026-09-06: Signed, notarized releases; one-line install

Releases are built by CI on tags, signed with Developer ID, notarized, and published with a SHA-256. `install.sh` downloads the latest release, verifies the checksum, installs to `~/Applications`, and launches. No Homebrew tap until someone asks.

## 2026-09-06: Protected main, squash merges, no AI attribution

Every change lands through a pull request with green CI. Commits carry the maintainer's identity only. Prose has no em dashes and no emoji.
