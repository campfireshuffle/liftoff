# Releasing

Releases are built, signed, notarized and published by the **Release** workflow
(`.github/workflows/release.yml`).

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist` and merge to `main`.
2. Run the workflow with that version:

   ```sh
   gh workflow run release.yml -f version=X.Y.Z
   ```

3. The workflow pushes a `liftoff-X.Y.Z` branch to `campfireshuffle/homebrew-tap` with the new cask
   version and checksum. Open and merge its pull request.

## Secrets

The workflow reads these from the repository's `release` environment:

| Secret | What it is |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | Developer ID Application certificate and key, base64-encoded `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `APPLE_API_PRIVATE_KEY_P8` | App Store Connect API key for notarization, base64-encoded `.p8` |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | That key's issuer ID |
| `HOMEBREW_TAP_DEPLOY_KEY_B64` | Base64 private SSH key, registered as a write deploy key on the tap |

`scripts/set-release-secrets.sh` copies them from Bitwarden without printing them
(`--only NAME` sets just one).

## Local builds

`scripts/package.sh` builds `dist/Liftoff.app`. Set `SIGN_IDENTITY` to a Developer ID Application
certificate to sign it; otherwise it's signed ad hoc (or with a local "Liftoff Dev" identity, if
present, so macOS keeps permissions across rebuilds).

`swift scripts/make-icon.swift` redraws the app icon, menu bar icon and social preview into `assets/`.
