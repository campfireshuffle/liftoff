#!/usr/bin/env bash
# Builds dist/Liftoff.app. SIGN_IDENTITY defaults to the local "Liftoff Dev" identity if present
# (stable, so macOS keeps permissions across rebuilds), otherwise ad-hoc.
# SANDBOX=1 also turns on the App Sandbox (Liftoff.sandbox.entitlements), for App Store experiments
# (see docs/app-store.md). It keeps the same bundle ID, so quit the other build before running it.
set -euo pipefail

cd "$(dirname "$0")/.."
app="$(pwd)/dist/Liftoff.app"
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -q '"Liftoff Dev"'; then
    SIGN_IDENTITY="Liftoff Dev"
  else
    SIGN_IDENTITY="-"
  fi
fi

swift build -c release --arch arm64
bin="$(swift build -c release --arch arm64 --show-bin-path)/Liftoff"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp "$bin" "$app/Contents/MacOS/Liftoff"
cp assets/Liftoff.icns assets/MenuBarIcon.png assets/MenuBarIcon@2x.png "$app/Contents/Resources/"

sign=(--force --sign "$SIGN_IDENTITY")
if [[ "${SANDBOX:-}" == 1 ]]; then
  sign+=(--entitlements Liftoff.sandbox.entitlements)
fi
if [[ "$SIGN_IDENTITY" != "-" && "$SIGN_IDENTITY" != "Liftoff Dev" ]]; then
  sign+=(--options runtime --timestamp)
fi
codesign "${sign[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"

echo "$app"
