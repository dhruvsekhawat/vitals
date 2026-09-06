#!/bin/zsh
# Build Vitals, assemble the .app bundle, sign, install to ~/Applications, launch.
#
# Usage: ./build.sh [--no-install] [--test]
#   --no-install   build and sign only; do not install or launch
#   --test         run `swift test` first; abort on failure
#
# Environment:
#   CODESIGN_IDENTITY  "Developer ID Application: ..." identity. Unset: ad-hoc signing.
#   NOTARY_PROFILE     notarytool keychain profile. Only used when CODESIGN_IDENTITY is set.
#   UNIVERSAL=1        build for both Apple silicon and Intel (used for releases).
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=1
RUN_TESTS=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --test)       RUN_TESTS=1 ;;
    -h|--help)    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

APP=build/Vitals.app
ENTITLEMENTS=Vitals.entitlements
ICON=Assets/AppIcon.icns
INSTALL_PATH="$HOME/Applications/Vitals.app"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.dhruv.vitals.plist"
LABEL="gui/$(id -u)/com.dhruv.vitals"

mkdir -p build

# 1. Tests (optional)
if (( RUN_TESTS )); then
  echo "==> swift test"
  swift test
fi

# 2. Compile
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
  BINARY=.build/apple/Products/Release/Vitals
else
  ARCH_FLAGS=()
  BINARY=.build/release/Vitals
fi
echo "==> swift build -c release ${ARCH_FLAGS[*]:-}"
if ! swift build -c release "${ARCH_FLAGS[@]}" > build/swift-build.log 2>&1; then
  cat build/swift-build.log >&2
  echo "build failed" >&2
  exit 1
fi
grep -E "error|warning: unre|Compiling|Build complete" build/swift-build.log || true
[[ -x "$BINARY" ]] || { echo "build failed: $BINARY missing" >&2; exit 1; }

# 3. Assemble bundle
echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Vitals"
cp Info.plist "$APP/Contents/Info.plist"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 4. Sign
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  SIGN_MODE="Developer ID ($CODESIGN_IDENTITY)"
  echo "==> codesign with $CODESIGN_IDENTITY"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$CODESIGN_IDENTITY" "$APP"
else
  # Ad-hoc signature. Deliberately no --options runtime and no --timestamp:
  # hardened runtime with an ad-hoc identity fails to launch on some machines
  # (library validation with no team identifier, and no notarization ticket),
  # and ad-hoc signatures cannot carry a trusted timestamp anyway.
  SIGN_MODE="ad-hoc"
  echo "==> codesign ad-hoc"
  codesign --force --sign - "$APP"
fi
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
  echo "codesign verification failed for $APP" >&2
  exit 1
fi

# 5. Notarize (optional, release builds only)
if [[ -n "${CODESIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
  ZIP=build/Vitals.zip
  echo "==> notarize via profile $NOTARY_PROFILE"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  SIGN_MODE="$SIGN_MODE, notarized"
fi

# 6. Install and relaunch
if (( INSTALL )); then
  echo "==> install to $INSTALL_PATH"
  pkill -x Vitals 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALL_PATH"
  cp -R "$APP" "$INSTALL_PATH"
  if [[ -f "$LAUNCH_AGENT" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT" 2>/dev/null || true
    launchctl kickstart -k "$LABEL"
  else
    open "$INSTALL_PATH"
  fi
  LOCATION="$INSTALL_PATH"
else
  LOCATION="$APP (not installed)"
fi

SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
echo "Vitals $SHORT ($BUILD), signing: $SIGN_MODE, at: $LOCATION"
