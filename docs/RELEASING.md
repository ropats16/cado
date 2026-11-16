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

## Release

```sh
make release VERSION=0.2.0
```

Stages: preflight (fails early naming any missing variable, identity or notary
profile) > build + assemble > sign app (Hardened Runtime, secure timestamp,
`Resources/Cado.entitlements`) > build DMG > sign DMG > `notarytool submit
--wait` > `stapler staple` > verify (`codesign --verify --strict`, `stapler
validate`, `spctl -a -t open --context context:primary-signature`, mounted
app + Applications link check). A successful run ends with:

```
✓ Release 0.2.0 (build 157)
  DMG:    .../dist/Cado-0.2.0.dmg
  sha256: <64 hex chars>
```

- `CFBundleShortVersionString` = `VERSION`. `CFBundleVersion` = git commit count on HEAD (monotonic along main; override with `CADO_BUILD=<int>`). Needs full git history, not a shallow clone.
- **Rehearsal** (no Apple credentials needed, any signing identity or `-`; result is *not* distributable):
  `SKIP_NOTARIZE=1 CADO_SIGN_IDENTITY="-" make release VERSION=0.2.0`
- If notarization is rejected the script prints Apple's log; fix and rerun.

## Entitlements

Only `com.apple.security.device.audio-input` (microphone under Hardened Runtime).
Not sandboxed; paste and Accessibility are TCC permissions, not entitlements; all
linked libraries are system ones. Add nothing else unless a notarized build
demonstrably breaks without it.

## Manual acceptance check

Automation cannot prove this one: copy the DMG to a **fresh Mac (or user account)
that has never run Cado**, download it via a browser (so it is quarantined),
open it, drag Cado to Applications and launch. There must be no Gatekeeper
warning beyond the standard "downloaded from the Internet" confirmation.

## Heads-up: permissions reset once

Dev builds are signed with the local `Cado Self-Signed` cert. Developer ID changes
the code's designated requirement, so macOS treats the release as a different
app: Microphone and Accessibility grants reset once for anyone moving from a dev
install, and persist across later releases signed with the same Developer ID.

## Extending

`scripts/release.sh` is a list of stage functions. Sparkle appcast (#24) and
Homebrew cask bump (#25) hook in after `stage_verify`, using `VERSION`, `BUILD`,
`DMG` and `DMG_SHA256`.
