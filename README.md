<p align="center">
  <img src="assets/Liftoff-1024.png" width="160" alt="Liftoff icon">
</p>

<h1 align="center">Liftoff</h1>

<p align="center">Give your Mac's windows thrusters.</p>

Hold a key, grab any window and fling it. It flies with real momentum, tumbles, and fires
compressed-gas thrusters to hop over the windows in its way, then hovers and sets down
wherever there's room, in a cloud of smoke.

## Install

Liftoff needs macOS 14 or later on Apple silicon.

```sh
brew install --cask campfireshuffle/tap/liftoff
```

Or download the latest `liftoff-<version>-macos-arm64.zip` from
[Releases](https://github.com/campfireshuffle/liftoff/releases), unzip it, and move
**Liftoff.app** to your Applications folder.

## First launch

Liftoff lives in the menu bar (the rocket). On first launch a welcome window walks you through
two permissions. Drag the Liftoff icon from that window into each list in System Settings, or use
the buttons to open them:

- **Accessibility**, to grab windows and move them.
- **Screen Recording**, to snapshot the window you throw so it can fly while the real window waits.
  Nothing is saved or sent anywhere. macOS applies this one after a relaunch, and the welcome
  window has a button for that.

## Use

Hold the grab key, drag anywhere inside a window, and let go mid-swipe to throw it. Flick from a
corner to spin it.

The default grab key is **Hyper** (⌃⌥⇧⌘). If you map Caps Lock to Hyper with Raycast or Karabiner,
it becomes a one-finger throw. You can switch to ⌃⌥, ⌥⌘ or ⌃⌘ in Settings. Some window managers
use ⌃⌥-drag themselves, so Hyper avoids clashes.

In flight, a window:

- arcs on gravity, and can sail up off the top of the screen and fall back,
- fires its thrusters at the last moment to stop in time, braking before the screen's sides,
- climbs over other windows rather than passing through them,
- hovers just above its landing spot, then sets down on the floor (above the Dock) or on another
  window's roof.

Prefer things put back? Set **Land** to *Back where it started* in Settings. **Land All Windows Now**
in the menu puts every flying window down immediately.

## Settings

Open Settings from the menu bar rocket (or reopen the app) to change the grab key, where windows
land, the thruster sound, and opening at login, and to check permissions.

## Uninstall

```sh
brew uninstall --zap --cask liftoff
```

Then remove Liftoff from the Accessibility and Screen Recording lists in System Settings.

## Build from source

```sh
./scripts/package.sh
open dist/Liftoff.app
```

`package.sh` builds a release binary and assembles `dist/Liftoff.app`. Set `SIGN_IDENTITY` to a
Developer ID Application certificate to sign it; otherwise it's signed ad hoc.

`scripts/make-icon.swift` redraws the app and menu bar icons into `assets/`.

## Releasing

Releases are built, signed, notarized and published by the **Release** workflow
(`.github/workflows/release.yml`). Bump `CFBundleShortVersionString` and `CFBundleVersion` in
`Info.plist`, merge to `main`, then run the workflow with that version. It needs these secrets
in the repository's `release` environment:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate and key, base64-encoded `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `APPLE_API_PRIVATE_KEY_P8` | App Store Connect API key for notarization, base64-encoded `.p8` |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | That key's issuer ID |
| `HOMEBREW_TAP_DEPLOY_KEY_B64` | Base64 private deploy key with write access to the Homebrew tap |

The workflow pushes a branch to the tap with the new cask version; merge its pull request to ship.

## Demo kit

`scripts/demo.sh` stages and records the launch video (it drives Liftoff through debug hooks that
are off unless `defaults write run.lil.liftoff debugHooks -bool true`), and `scripts/cut-demo.sh`
edits a take to a soundtrack. `scripts/make-wallpaper.py` renders the night-track wallpaper.
