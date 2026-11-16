# Releasing Cado

`make release VERSION=x.y.z` builds a Developer ID-signed, Hardened Runtime,
notarized, stapled `dist/Cado-x.y.z.dmg` (Cado.app + an Applications shortcut
for drag-to-install). Maintainer-only; users never need this.

## One-time setup (you do this by hand)

1. **Join the Apple Developer Program** (paid, $99/yr): <https://developer.apple.com/programs/>. Note your **Team ID** (Membership details).
2. **Create the Developer ID Application certificate.** Xcode > Settings > Accounts > your team > Manage Certificates > `+` > **Developer ID Application**. (Or developer.apple.com > Certificates > `+` > Developer ID Application, upload a CSR from Keychain Access, download and double-click the `.cer`.) Only the Account Holder can create it.
3. Find the identity name:
   ```sh
   security find-identity -v -p codesigning
   # "Developer ID Application: Your Name (TEAMID)"
   ```
4. **Store notarization credentials** in the keychain, once. Either:
   - App-specific password: create one at <https://account.apple.com> > Sign-In and Security > App-Specific Passwords, then
     ```sh
     xcrun notarytool store-credentials cado-notary --apple-id you@example.com --team-id TEAMID
     ```
     (prompts for the password), or
   - App Store Connect API key (`.p8`):
     ```sh
     xcrun notarytool store-credentials cado-notary --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
     ```
5. **Export the two variables** (shell profile; never commit them):
   ```sh
   export CADO_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
   export CADO_NOTARY_PROFILE=cado-notary
   ```
6. **Update signing key** (Sparkle EdDSA, #24). Already generated on the
   maintainer's Mac: the private key is in the **login keychain** (item
   `https://sparkle-project.org`, account `cado`); its public half is
   `SUPublicEDKey` in `Resources/Info.plist`. It never goes in the repo.
   - **Back it up now** (losing it means shipped apps can never verify another
     update; whoever has it can push updates to every user):
     ```sh
     swift package resolve   # fetches Sparkle's tools into .build/artifacts
     .build/artifacts/sparkle/Sparkle/bin/generate_keys --account cado -x cado-sparkle-key.txt
     # store the file in a password manager, then delete it
     ```
   - On another Mac, import it: `generate_keys --account cado -f cado-sparkle-key.txt`.
   - Check it matches the app: `generate_keys --account cado -p` must print
     the `SUPublicEDKey` value (`make release` checks this first and stops if not).
   - Starting over without a key (only before the first release, or every
     installed copy loses updates): `generate_keys --account cado`, paste the
     printed key into `SUPublicEDKey`. While `SUPublicEDKey` is
     `SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER` the app never starts the updater and
     `make release` refuses to run.
   - The first `make release` asks the keychain to let Sparkle's `sign_update`
     read the key: enter your login password and choose **Always Allow**.

## Release

```sh
make release VERSION=0.2.0
```

Stages: preflight (fails early naming any missing variable, identity or notary
profile; then checks the keychain's Sparkle key matches `SUPublicEDKey`) >
build + assemble (Sparkle.framework embedded in `Contents/Frameworks`) > sign
app (Sparkle's `Autoupdate`, `Updater.app`, then the framework, then the app;
inside-out, never `--deep`, all Hardened Runtime + secure timestamp;
`scripts/sign_sparkle.sh`; the app with `Resources/Cado.entitlements`) >
build DMG > sign DMG > `notarytool submit --wait` > `stapler staple` > verify
(`codesign --verify --strict`, `stapler validate`, `spctl -a -t open --context
context:primary-signature`, mounted app + Applications link check) > appcast.
A successful run ends with:

```
✓ Release 0.2.0 (build 157)
  DMG:    .../dist/Cado-0.2.0.dmg
  sha256: <64 hex chars>

To publish (creates tag v0.2.0 at HEAD; ...):
  gh release create v0.2.0 '.../dist/Cado-0.2.0.dmg' '.../dist/appcast.xml' --repo ropats16/cado \
    --target <HEAD sha> --title 'Cado 0.2.0' --generate-notes
```

### Appcast (Sparkle feed)

After the DMG is notarized, stapled and verified, `stage_appcast` writes
`dist/appcast.xml`: the currently published feed
(`SUFeedURL` = `https://github.com/ropats16/cado/releases/latest/download/appcast.xml`,
fetched read-only; a 404 starts a new feed) with this release's item added on
top (`scripts/make_appcast.py`; an existing item for the same version/build is
replaced). The item's `sparkle:version` is the stamped `CFBundleVersion`,
`sparkle:shortVersionString` the version, the enclosure
`https://github.com/ropats16/cado/releases/download/v<version>/Cado-<version>.dmg`
with its length and EdDSA signature (`sign_update --account cado` on the final,
stapled DMG). The signature is then checked against the `SUPublicEDKey` inside
the built app (`scripts/verify_update_signature.swift`, no keychain).
Offline, or to build on a different feed: `CADO_APPCAST_BASE=<file>` (an empty
file starts a new feed).

### Publish (by hand, never automatic)

The script only prints the `gh release create` command. Run it yourself after
checking the DMG: it creates tag `v<version>`, the release, and uploads
`Cado-<version>.dmg` + `appcast.xml`. Once it's the latest (non-draft,
non-prerelease) release, `releases/latest/download/appcast.xml` serves the new
feed and every installed copy sees the update within a day. A draft or
prerelease isn't "latest", so it's invisible to users until published.

Dev builds (`make package`, `make install`, `swift run`) never check for
updates: `package_app.sh` drops `SUFeedURL` unless it's stamping a release
version, and the app only starts Sparkle inside a `.app` with an https feed and a
valid key (`UpdaterAvailability`).

- `CFBundleShortVersionString` = `VERSION`. `CFBundleVersion` = git commit count on HEAD (monotonic along main; override with `CADO_BUILD=<int>`). Needs full git history, not a shallow clone.
- **Rehearsal** (no Apple credentials needed, any signing identity or `-`; result is *not* distributable):
  `SKIP_NOTARIZE=1 CADO_SIGN_IDENTITY="-" make release VERSION=0.2.0`
  It runs the appcast stage too (signing with the keychain key) and prints, but
  never runs, the publish command. With `-` the app doesn't launch: under the
  Hardened Runtime, library validation rejects an ad-hoc Sparkle.framework
  ("different Team IDs"). For a runnable rehearsal use any Apple Development
  identity, e.g. `CADO_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"`.
- If notarization is rejected the script prints Apple's log; fix and rerun.

## Entitlements

Only `com.apple.security.device.audio-input` (microphone under Hardened Runtime).
Not sandboxed; paste and Accessibility are TCC permissions, not entitlements.
Sparkle.framework is the only non-system library; it's re-signed with the same
Developer ID, so library validation passes without
`disable-library-validation`. Sparkle needs no entitlements in a non-sandboxed
app, and its XPC services (Installer/Downloader, only for sandboxed apps) are
removed by `package_app.sh`, as Sparkle's sandboxing guide allows. Add nothing
else unless a notarized build demonstrably breaks without it.

## Manual acceptance check

Automation cannot prove this one: copy the DMG to a **fresh Mac (or user account)
that has never run Cado**, download it via a browser (so it is quarantined),
open it, drag Cado to Applications and launch. There must be no Gatekeeper
warning beyond the standard "downloaded from the Internet" confirmation.

**Update N → N+1 (first two Developer ID releases).** Also manual: install
release N from its DMG, grant Microphone and Accessibility, dictate once. Publish
N+1. In N choose **Check for Updates…** (or wait for the daily check: the menu
item becomes **Update Available (x.y.z)…** and a notification appears), install,
let it relaunch. Then confirm: Finder's Get Info on Cado.app shows N+1; Microphone and
Accessibility are still granted (System Settings › Privacy & Security, and the
menu rows) and dictation pastes without a new prompt. They should survive: the
Developer ID designated requirement (team ID + bundle ID) is the same for both
builds. Also confirm Settings › Updates' switch, off, stops the daily check
(`defaults read com.ropats16.Cado SUEnableAutomaticChecks` = 0).

What was verified locally without Developer ID (rehearsal builds signed with an
Apple Development identity, feed served from `http://127.0.0.1` via a
`SUFeedURL` user-default override): 0.2.0 found 0.2.1 in the feed, downloaded
it, and installed it on quit (Sparkle checked the EdDSA signature and the code
signature); with a wrong `sparkle:edSignature` it downloaded but refused to
install. Not covered by that: Gatekeeper/notarization on the updated app, and
TCC grants surviving (needs the real Developer ID).

## Heads-up: permissions reset once

Dev builds are signed with the local `Cado Self-Signed` cert. Developer ID changes
the code's designated requirement, so macOS treats the release as a different
app: Microphone and Accessibility grants reset once for anyone moving from a dev
install, and persist across later releases signed with the same Developer ID.

## Extending

`scripts/release.sh` is a list of stage functions. Sparkle's appcast (#24) is
`stage_appcast`, after `stage_verify`; Homebrew cask bump (#25) hooks in after
it, using `VERSION`, `BUILD`, `DMG` and `DMG_SHA256`.
