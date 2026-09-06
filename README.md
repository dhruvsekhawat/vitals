# Vitals

A menu bar app for macOS that tells you what is eating your Mac, in plain language, and fixes it in one click.

![The Vitals panel](docs/panel.png)

## Why this exists

My laptop was hot, the fans were loud, and it felt slow for weeks. Activity Monitor showed hundreds of processes and no obvious answer. The actual causes turned out to be two Cursor renderer processes that had been pinned at 100% CPU for nineteen days, forty-odd Claude Code helper processes leaked by sessions that had long since closed, swap at 97% full, and no restart in forty-one days. None of that is hard to find if you know which command to run. Vitals runs those commands for you, every few seconds, and only speaks up when something is actually wrong.

## What it shows

Click the dot in the menu bar. The dot is green, yellow, or red, with a count of open issues.

- Load, memory and memory pressure, swap, disk, uptime, power source, and thermal state. Anything past a threshold changes color.
- Every app rolled up with all of its helpers. Cursor is Cursor plus its renderers and extension hosts. CPU is shown as a share of the whole machine, so 25% means a quarter of all your cores, not a quarter of one.
- Issues, each with the one action that fixes it.
- A few sentences of advice, and a note when the same problem keeps coming back.

## What it detects

- A process stuck at high CPU for minutes. It will not recover on its own, so the fix is to stop it.
- A process that is working hard on purpose, like a compiler or a video encoder. Same numbers, gentler wording, no alarm.
- An app that has taken over: a large share of CPU for a sustained period, or a large share of RAM, across all of its processes. The fix asks the app to quit normally so it can save its state.
- Helper processes whose parent session has exited but that are still running. Claude Code's pre-warmed helpers are the built-in example; the rule is a small table and easy to extend.
- Memory pressure, from the same kernel signal Activity Monitor uses.
- Swap filling up. Only a restart empties it, and Vitals says so.
- Low disk. macOS gets slow under about 15% free.
- Long uptime. Leaked processes and swap accumulate until you reboot.
- Thermal state, with the name of the app most responsible.

When a new issue appears you get a notification that names the culprit and offers Clear. Notifications for the same issue are rate limited to one per half hour.

## How it works

Vitals is native Swift. It idles at 0% CPU and about 70 MB of memory. There is no web view, no Electron, and no dependency outside the macOS SDK.

Sampling runs on a private serial queue every 5 seconds, every 2 seconds while the panel is open, and every 15 seconds on battery. A sample reads load averages, `host_statistics64` for memory, `kern.memorystatus_vm_pressure_level` for memory pressure, `vm.swapusage`, the root volume's available capacity, `kern.boottime` for uptime, `ProcessInfo` for thermal state and Low Power Mode, and IOKit for the battery. Processes come from libproc: `proc_listallpids` for the list, `proc_pidinfo` for start time, parent, owner, CPU time and resident size, and `proc_pidpath` for the path. Command lines are read once per process with `sysctl(KERN_PROCARGS2)`, kept in memory for rule matching, and never written anywhere.

Per-process CPU is the difference in CPU time between two samples divided by wall time, so it is an instantaneous reading rather than the lifetime average `ps` prints. Two things about that were wrong in early builds and are worth knowing if you write this kind of code: `proc_listallpids` returns a count of pids, not a byte count, and `proc_taskinfo` reports CPU time in Mach ticks, which on Apple silicon are 125/3 nanoseconds each, not nanoseconds. Both mistakes fail quietly. There are integration tests for both now.

Rules turn a sample into issues. They are pure functions of the sample plus a little state for "how long has this been true", and they reset that state after the machine wakes from sleep so time asleep does not count as time stuck. History keeps thirty days of incidents and five-minute snapshots in one JSON file under `~/Library/Application Support/Vitals`. An incident is identified by what it is, not by which pids it involves, so a leak that grows from six processes to nine is one incident, not two.

Remedies are the only code that changes anything. Stopping a process sends SIGTERM, waits two seconds, then SIGKILL. Quitting an app asks it to terminate normally and only falls back to a kill if it ignores the request for eight seconds. Both only ever touch processes owned by the current user. Freeing disk deletes a fixed list of caches that rebuild themselves and runs `pnpm store prune` and `brew cleanup` if those tools are installed. Restart sends the standard Apple event to loginwindow, so you get the usual confirmation dialog. Everything destructive is logged under the `com.dhruv.vitals` subsystem.

The app installs itself as a user LaunchAgent with KeepAlive on crash. Quit exits cleanly and stays quit until the next login.

## Install

Requires macOS 14 or later. Apple silicon and Intel are both supported.

```sh
curl -fsSL https://raw.githubusercontent.com/dhruvsekhawat/vitals/main/install.sh | sh
```

That downloads the latest release, checks its SHA-256 against the published checksum, puts `Vitals.app` in `~/Applications`, and launches it. Vitals registers itself to start at login the first time it runs. macOS will ask once whether it may send notifications. Say yes, or the alerts are silent.

If you would rather not pipe a script into your shell: download `Vitals-<version>.zip` from the [releases page](https://github.com/dhruvsekhawat/vitals/releases/latest), unzip it, move `Vitals.app` to `~/Applications`, then right-click it and choose Open the first time. The right-click is needed because release builds are signed ad hoc, not notarized. The install script removes that quarantine flag for you because you explicitly chose to install; a notarized build would need an Apple Developer ID and would make this a plain double-click.

To remove it:

```sh
curl -fsSL https://raw.githubusercontent.com/dhruvsekhawat/vitals/main/install.sh | sh -s -- --uninstall
```

### Build from source

Needs Xcode 15 or later.

```sh
git clone https://github.com/dhruvsekhawat/vitals.git
cd vitals
./build.sh
```

That builds a release binary, assembles `Vitals.app`, signs it, installs it to `~/Applications`, registers the LaunchAgent, and launches it. `./build.sh --test` runs the test suite first; `./build.sh --no-install` stops after signing; `UNIVERSAL=1 ./build.sh` builds for both architectures, which is what the release workflow does.

## Check it from a shell

```sh
~/Applications/Vitals.app/Contents/MacOS/Vitals --snapshot panel.png
```

Renders the panel to a PNG and prints the per-app rollup to stderr, then exits. This is how the UI is verified in this project. It works over SSH and needs no screen recording permission.

Logs:

```sh
log stream --predicate 'subsystem == "com.dhruv.vitals"' --level info
```

## Configure

Thresholds live in user defaults. Restart Vitals after changing one.

```sh
defaults write com.dhruv.vitals threshold.hotCPU 90
```

| Key | Default | Meaning |
| --- | --- | --- |
| `threshold.hotCPU` | 85 | percent of one core that counts as hot for a process |
| `threshold.hotFor` | 180 | seconds a process must stay hot to be reported |
| `threshold.appHogCPUShareWarn` | 35 | percent of the whole machine an app may hold before a warning |
| `threshold.appHogCPUShareBad` | 60 | percent of the whole machine that is marked bad |
| `threshold.appHogFor` | 120 | seconds an app must hold that share to be reported |
| `threshold.appHogMemShare` | 30 | percent of physical RAM an app may hold before it is reported |
| `threshold.swapWarn` | 25 | swap in use as a percent of physical RAM that triggers a warning |
| `threshold.swapBad` | 50 | swap in use as a percent of physical RAM that is marked bad |
| `threshold.diskWarnFreePct` | 15 | free disk percent below which a warning is raised |
| `threshold.diskBadFreePct` | 8 | free disk percent below which the disk is marked bad |
| `threshold.uptimeWarnDays` | 14 | days without a restart that trigger a warning |
| `threshold.uptimeBadDays` | 30 | days without a restart that are marked bad |
| `threshold.lifetimeHotCPU` | 75 | lifetime average CPU that flags a long-running process at once |
| `threshold.lifetimeMinAge` | 1800 | seconds a process must have run for the lifetime rule to apply |
| `threshold.bootGrace` | 600 | seconds after boot during which system indexers are left alone |
| `threshold.coolSamples` | 3 | consecutive quiet samples before a "stuck" or "hog" clock resets |

Swap is measured against RAM on purpose. macOS grows its swap files on demand, so "percent of swap used" sits near 100% whenever any swap exists and tells you nothing. Four gigabytes swapped on a 16 GB machine is worth a warning; eight is a machine that is paging constantly.

## Signing a build for other people

With no environment variables, `build.sh` signs ad hoc, which is fine on your own machine. For a build you can hand to someone else:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh --no-install
```

That signs with the hardened runtime and a trusted timestamp. Set `NOTARY_PROFILE` to a keychain profile created with `xcrun notarytool store-credentials` to notarize and staple in the same run. The app is not sandboxed. It enumerates and signals other processes, deletes caches, and writes a LaunchAgent, none of which the sandbox allows. `Vitals.entitlements` has the details.

## Privacy

Everything stays on the machine. Command lines are read into memory for rule matching and are never persisted or logged. The only file Vitals writes outside its own bundle is `~/Library/Application Support/Vitals/state.json`, which holds incidents and snapshots, and the LaunchAgent plist. Nothing is sent anywhere.

## Uninstall

The install script with `--uninstall` (see above), or by hand:

```sh
launchctl bootout gui/$(id -u)/com.dhruv.vitals
rm ~/Library/LaunchAgents/com.dhruv.vitals.plist
rm -rf ~/Applications/Vitals.app
rm -rf ~/Library/Application\ Support/Vitals
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: keep it native, keep it small, and every rule gets a test.

## License

MIT. See [LICENSE](LICENSE).
