# Fennixx CMUX release channel

The fork now follows upstream cmux 0.64.23 plus Mac-to-Mac machine sessions. Old fork-only workspace/group/GitLab/notification changes were intentionally discarded. The previous main remains at `archive/main-before-machine-pairing-20260914`.

## Installation and trust

This first packaged release requires **Apple Silicon and macOS 26 or later**: the bundled tmux and libevent were built for macOS 26. The Release deployment target and appcast enforce that requirement. Earlier macOS support needs rebuilding those dependencies for an earlier deployment target; do not merely lower the appcast minimum.

Version 0.65.0 starts a new Ed25519 update key because the old private key could not be located. Install it manually once on each Apple Silicon Mac. Replace **Fennixx CMUX**, not the unrelated official **cmux**. macOS may require System Settings → Privacy & Security → Open Anyway for this explicitly trusted download: this personal build is ad-hoc code signed and is **not Apple-notarized**. Do not disable Gatekeeper globally.

Subsequent releases use Sparkle's Check for Updates. The app retains `com.fennixx.cmux` and reads `https://github.com/Fennixx/cmux/releases/latest/download/appcast.xml`. Never mark an assetless or preview release as latest. The new key cannot update older installed apps automatically.

## Signing key custody

- macOS login Keychain service: `https://sparkle-project.org`
- Account: `com.fennixx.cmux.releases-2026`
- Encrypted recovery copy: repository Actions secret `FENNIXX_SPARKLE_PRIVATE_KEY`
- Public key: `ArwLK36PA1CbGMywuKoc+UidFdRSrtzmfWQwab+nv/8=`

Private material must never be committed, logged, passed as a command-line argument, or put into a release asset. Sparkle's `generate_keys -p` prints only the public key. To recover on a new release Mac, use a trusted, reviewed workflow to consume the encrypted secret without logging it and import into that Mac's Keychain. GitHub does not let users read back secret values from its settings UI.

## Releasing

Upstream's Apple signing/notarization/iOS release workflow is explicitly gated to the upstream repository; it must not publish into this fork with upstream identifiers or update URLs.

1. Bump the version using `scripts/bump-version.sh`, update the changelog and commit. Preserve the Release target's Fennixx app identity, update URL and public key.
2. Run the focused machine-session tests, `python3 tests/test_fennixx_release.py`, project checks and a tagged Debug build. Build the Release configuration into its own DerivedData directory, arm64, with ad-hoc signing and empty Apple-only entitlements. Do not overwrite a running installed bundle.
3. Run `CMUX_SPARKLE_APPCAST_URL=https://github.com/Fennixx/cmux/releases/latest/download/appcast.xml scripts/release-pretag-guard.sh`.
4. Package the actual Release app with `python3 scripts/fennixx-package-release.py --app <built-app> --out <new-output-directory> --tag vX.Y.Z --sparkle-bin <Sparkle-bin-directory>`. It checks app identity, feed, key, build/version and arm64 binaries; verifies the code signature; packages a DMG; signs and verifies the DMG using the Keychain; generates the arm64-only appcast and checksum. Output must not exist beforehand.
5. Verify an installed copy and its Check for Updates behavior, then publish `cmux-macos.dmg`, `appcast.xml`, and `SHA256SUMS.txt` together to a new GitHub release. Publish a draft only after all assets have uploaded, then mark it latest. Never overwrite an existing signed archive.

Physical two-Mac Tailscale pairing was not verified during the initial release preparation. Local native session create/detach/reattach/End and isolated loopback pairing tests passed; do not claim those prove the Orion network path.
