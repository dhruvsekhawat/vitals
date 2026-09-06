# Contributing

Thanks for looking. Vitals is small on purpose. Changes that keep it small are the easiest to land.

## Ground rules

- Native only. SwiftUI, AppKit, libproc, IOKit. No Electron, no web views, no third-party dependencies.
- Idle cost matters more than features. A sample of 400 processes must stay under a few milliseconds and the app must sit at 0% CPU between samples.
- Every rule needs a test that constructs a `Sample` by hand and asserts the verdict. Every fix for a wrong number needs a test that would have caught it.
- Anything destructive (killing processes, deleting caches) goes through `Remedies`, only ever targets the current user's processes and the listed cache paths, and is logged with `os.Logger`.
- Plain language in the UI. Say what is happening and what to do about it. No jargon the user has to look up.

## Development

```sh
swift build
swift test
./build.sh            # build, sign, install to ~/Applications, relaunch under launchd
./build.sh --test     # run the tests first
./build.sh --no-install
```

To see the panel without opening the menu bar:

```sh
~/Applications/Vitals.app/Contents/MacOS/Vitals --snapshot panel.png
```

That renders the panel to a PNG and prints the per-app rollup to stderr. It is how the UI gets checked in this project, and it works over SSH.

Logs:

```sh
log stream --predicate 'subsystem == "com.dhruv.vitals"' --level info
```

## Layout

- `Sources/VitalsCore`: everything testable. `Sampler` reads the machine, `Rules` turns a sample into issues, `History` persists incidents and snapshots, `Advisor` writes the recommendations, `Remedies` does the destructive things.
- `Sources/Vitals`: the app. `Engine` runs the sampling loop on a private queue and hands finished state to the main actor. `PanelView` is the whole UI.
- `Tests/VitalsCoreTests`: unit tests for the core plus a few integration tests that sample the real machine.

## Releasing

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, add a section to `CHANGELOG.md`, merge, then tag:

```sh
git tag v1.1.0
git push origin v1.1.0
```

The release workflow tests, builds a universal binary, refuses to continue if the tag does not match `Info.plist`, and publishes the zip and its SHA-256 as a GitHub release with the changelog section as notes. `install.sh` always picks up the latest release.

### Signing and notarization

With five repository secrets set, the workflow signs with Developer ID, notarizes, staples, and checks the result with `spctl` before publishing. Without them it signs ad hoc.

| Secret | What it is |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | `base64 -i cert.p12` of a Developer ID Application certificate exported from Keychain Access with its private key |
| `APPLE_CERTIFICATE_PASSWORD` | the password you chose when exporting the .p12 |
| `APPLE_ID` | the Apple ID email of the developer account |
| `APPLE_TEAM_ID` | the 10-character team id shown at developer.apple.com |
| `APPLE_APP_PASSWORD` | an app-specific password from appleid.apple.com, not the account password |

The certificate must be a **Developer ID Application** certificate, which only the account holder can create, at developer.apple.com under Certificates or from Xcode's Accounts settings. An Apple Development certificate will not do; Gatekeeper does not trust it outside your own machine.

Local releases work the same way through `build.sh`:

```sh
xcrun notarytool store-credentials vitals-notary --apple-id you@example.com --team-id TEAMID
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=vitals-notary ./build.sh --no-install
```

## Pull requests

One change per pull request. Say what was wrong, how you know, and how the change fixes it. If a number was wrong, include what `ps` or Activity Monitor said next to what Vitals said.
