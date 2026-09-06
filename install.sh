#!/bin/sh
# Install Vitals from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/dhruvsekhawat/vitals/main/install.sh | sh
#
# What this does, in order: download the release zip and its checksum, verify the checksum,
# unpack Vitals.app into ~/Applications, clear the quarantine flag (you chose to install it;
# the app is ad-hoc signed, not notarized, so macOS would otherwise refuse to open it),
# and launch it. Vitals registers itself to start at login on first launch.
#
#   sh install.sh --uninstall    removes the app, the login item, and its saved state
set -eu

REPO="dhruvsekhawat/vitals"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Vitals.app"
LABEL="com.dhruv.vitals"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  pkill -x Vitals 2>/dev/null || true
  rm -f "$PLIST"
  rm -rf "$APP"
  rm -rf "$HOME/Library/Application Support/Vitals"
  say "Vitals removed."
  exit 0
fi

[ "$(uname -s)" = "Darwin" ] || die "Vitals is a macOS app."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "Vitals needs macOS 14 or later (you have $(sw_vers -productVersion))."
command -v curl >/dev/null || die "curl is required."

say "Finding the latest release of $REPO"
api=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest") || die "could not reach GitHub."
tag=$(printf '%s' "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
zip_url=$(printf '%s' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*Vitals-[^"]*\.zip\)".*/\1/p' | head -1)
sum_url=$(printf '%s' "$api" | sed -n 's/.*"browser_download_url": *"\([^"]*\.sha256\)".*/\1/p' | head -1)
[ -n "$tag" ] && [ -n "$zip_url" ] && [ -n "$sum_url" ] || die "no release with a Vitals zip was found."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
say "Downloading Vitals $tag"
curl -fsSL "$zip_url" -o "$tmp/Vitals.zip"
curl -fsSL "$sum_url" -o "$tmp/Vitals.zip.sha256"

say "Verifying checksum"
expected=$(cut -d' ' -f1 "$tmp/Vitals.zip.sha256")
actual=$(shasum -a 256 "$tmp/Vitals.zip" | cut -d' ' -f1)
[ "$expected" = "$actual" ] || die "checksum mismatch. Expected $expected, got $actual. Not installing."

say "Installing to $APP"
mkdir -p "$APP_DIR"
ditto -x -k "$tmp/Vitals.zip" "$tmp/unpacked"
[ -d "$tmp/unpacked/Vitals.app" ] || die "the zip did not contain Vitals.app."
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x Vitals 2>/dev/null || true
rm -rf "$APP"
ditto "$tmp/unpacked/Vitals.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP" 2>/dev/null || die "the downloaded app failed signature verification. Not launching."

open "$APP"
say ""
say "Vitals $tag is running. Look for the dot in your menu bar."
say "macOS will ask once whether Vitals may send notifications. Say yes, or the alerts are silent."
say "To remove it later: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall"
