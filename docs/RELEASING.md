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

## Versioning

Semantic versioning, `MAJOR.MINOR.PATCH`:

- **PATCH** (0.2.x): fixes only; nothing a user has to relearn.
- **MINOR** (0.x.0): new or changed features, UI or wording; note files written by older versions must still open.
- **MAJOR** (x.0.0): breaking changes (a note or config format older data can't be read from, a raised macOS minimum). 1.0.0 = first release called stable.

The version exists only as the `VERSION` given to `make release` and the
`v<version>` tag; the build number is the git commit count. The next release is
**0.4.1**, containing signed-feed enforcement only. Published 0.4.0 includes
both the prepared 0.3.0 milestone and subsequent features; the 0.3.0 notes
remain as historical context. Before each release add a section to
`CHANGELOG.md` (newest first, user-facing wording); it is the release's notes.

## Release

```sh
make release VERSION=0.4.1
```

Stages: preflight (fails early naming any missing variable, identity or notary
profile; refuses a dirty tree; then checks the keychain's Sparkle key matches
`SUPublicEDKey` and that the build number is new to the published appcast) >
build + assemble (Sparkle.framework embedded in `Contents/Frameworks`) > sign
app (Sparkle's `Autoupdate`, `Updater.app`, then the framework, then the app;
inside-out, never `--deep`, all Hardened Runtime + secure timestamp;
`scripts/sign_sparkle.sh`; the app with `Resources/Cado.entitlements`) >
build DMG > sign DMG > `notarytool submit --wait` > `stapler staple` > verify
(`codesign --verify --strict`, `stapler validate`, `spctl -a -t open --context
context:primary-signature`, mounted app + Applications link check) > appcast.
A successful run ends with:

```
✓ Release 0.4.1 (build <commit count>)
  DMG:    .../dist/Cado-0.4.1.dmg
  sha256: <64 hex chars>

To publish (creates tag v0.4.1 at HEAD; ...):
  gh release create v0.4.1 '.../dist/Cado-0.4.1.dmg' '.../dist/appcast.xml' --repo ropats16/cado \
    --target <HEAD sha> --title 'Cado 0.4.1' --generate-notes --draft
  gh release edit v0.4.1 --repo ropats16/cado --draft=false
```

### Appcast (Sparkle feed)

After the DMG is notarized, stapled and verified, `stage_appcast` writes
`dist/appcast.xml`: the currently published feed
(`SUFeedURL` = `https://github.com/ropats16/cado/releases/latest/download/appcast.xml`,
fetched read-only; a 404 starts a new feed) with this release's item added on
top (`scripts/make_appcast.py`; an existing item for the same version is
replaced). The item's `sparkle:version` is the stamped `CFBundleVersion`,
`sparkle:shortVersionString` the version, the enclosure
`https://github.com/ropats16/cado/releases/download/v<version>/Cado-<version>.dmg`
with its length and EdDSA signature (`sign_update --account cado` on the final,
stapled DMG); the finished feed is signed too (next section). The signature is then checked against the `SUPublicEDKey` inside
the built app (`scripts/verify_update_signature.swift`, no keychain).
Offline, or to build on a different feed: `CADO_APPCAST_BASE=<file>` (an empty
file starts a new feed).

Sparkle offers an update by build number, so the feed must never hold one
build under two versions, and a new build must be newer than every item
already there. Preflight fetches the feed and runs `make_appcast.py --check`,
which refuses (before the long build) a build the feed already has under
another version (e.g. a second release from the same HEAD: the older item would
be dropped and Sparkle would never offer the newer one), or one not greater
than its newest build. Re-running the same version and build (e.g. after a
failed upload) just replaces its item. Fix: commit (the commit count moves on),
or set `CADO_BUILD` to a greater integer. Its tests run offline:
`python3 -m unittest discover -s scripts/tests`.

### Signed feed (#46)

The last step of `stage_appcast` signs the whole feed: `sign_update --account cado
dist/appcast.xml` embeds a trailing `<!-- sparkle-signatures: edSignature ... -->`
comment (a keychain step, like the DMG signature; same **Always Allow** prompt).
It is then checked against the `SUPublicEDKey` inside the built app
(`verify_update_signature.swift --feed`, no keychain). Nothing may edit the file
afterwards. A base feed that is already signed is fine: `make_appcast.py` drops
the old comments and the new feed is signed afresh. Tests (throwaway key, no
keychain): `python3 -m unittest discover -s scripts/tests`.

**Rollout order matters.** The bootstrap release
[0.4.0](https://github.com/ropats16/cado/releases/tag/v0.4.0) was published on
2026-11-17 without enforcement. Its public latest feed was downloaded and
verified with `verify_update_signature.swift --feed` and the checked-in public
key. SHA-256: `0a8d4ae49334faeaff5644a84e3b82d44b2376c52004a5560f34c252084b27a1`.
The earlier 0.2.0 feed was unsigned. With the signed bootstrap now live,
`Resources/Info.plist` enables both `SURequireSignedFeed` and
`SUVerifyUpdateBeforeExtraction` for 0.4.1.

For every release, verify the published feed after downloading it:
`swift scripts/verify_update_signature.swift --feed "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)" appcast.xml`.
Keep publishing signed feeds: installed copies of 0.4.1 and later will reject
unsigned or edited feeds.

**`SUVerifyUpdateBeforeExtraction` is required alongside signed feeds**, not
optional: the pinned Sparkle 2.10.1 rejects its updater configuration if
`SURequireSignedFeed` is on without it (`SPUUpdater.m`). It verifies the archive
before mounting/extracting it. Sparkle still supports rotating EdDSA keys through
an Apple Developer ID-signed disk image fallback; the earlier statement that
pre-extraction verification removes every code-signing fallback was incorrect.
See [Sparkle security settings](https://sparkle-project.org/documentation/customization/#security-settings).
Verify the N to N+1 upgrade, then test **from the N+1 app itself**: a valid
signed feed is accepted, unsigned or edited feeds are rejected, and a tampered
archive is rejected before extraction. N performs the N to N+1 installation
without either flag, so that upgrade alone cannot prove N+1's enforcement.

### Repo settings

Applied and checked through the GitHub API on 2026-11-17 for #49: immutable
releases, Dependabot alerts/security updates, and the active `Protect main`
ruleset (ID `27473892`). The ruleset blocks deletion/force pushes and requires
PRs, with zero required approvals, resolved review threads, and no bypass actors.
The commands below document setup for another repository; they are not build steps.
Run as the repo admin (`gh auth status`):

- **Immutable releases** (published assets and the tag can no longer be changed
  or swapped; protects the feed and DMG from a stolen token). UI: repo Settings >
  General > Releases > "Enable release immutability". CLI:
  `gh api -X PUT repos/ropats16/cado/immutable-releases`
  (check: `gh api repos/ropats16/cado/immutable-releases`). After it is on, a
  published release can't be re-uploaded: a bad release gets a new version, not
  an edit. Create releases as drafts and attach every asset BEFORE publishing
  (`gh release create ... --draft`, then `gh release edit v<ver> --draft=false`).
- **Branch protection on `main`:** UI: Settings > Rules > Rulesets > New branch
  ruleset, target `main`, enable "Restrict deletions", "Block force pushes",
  "Require a pull request before merging" (0 required approvals if you are the
  only maintainer). The configured ruleset has no bypass: merge changes through
  a PR. Release tags do not target `main` and are not restricted by this branch
  ruleset; immutable releases protect their tags after publication.
- **Dependabot alerts + security updates:** UI: Settings > Advanced Security (or
  Code security) > enable "Dependabot alerts" and "Dependabot security updates".
  CLI: `gh api -X PUT repos/ropats16/cado/vulnerability-alerts` and
  `gh api -X PUT repos/ropats16/cado/automated-security-fixes`.
  Version updates come from `.github/dependabot.yml` (weekly, grouped: Actions,
  Swift packages). There is no CI: build and test every Dependabot PR locally
  (`swift build`, `swift test`, `make embed`) before merging; see "Pinned
  dependencies". whisper.cpp is NOT on Dependabot (it would bump the submodule to
  untagged master): bump it by hand to a release tag, following the whisper.cpp
  notes in `plans/IMPLEMENTATION-NOTES.md`.

### Publish (by hand, never automatic)

The script only prints the `gh release create ... --draft` command (then
`gh release edit v<ver> --draft=false` to publish, once the assets are checked).
Run it yourself after checking the DMG: it creates tag `v<version>`, the release, and uploads
`Cado-<version>.dmg` + `appcast.xml`. Once it's the latest (non-draft,
non-prerelease) release, `releases/latest/download/appcast.xml` serves the new
feed and every installed copy sees the update within a day. A draft or
prerelease isn't "latest", so it's invisible to users until published.

Dev builds (`make package`, `make install`, `swift run`) never check for
updates: `package_app.sh` drops `SUFeedURL` unless it's stamping a release
version, and the app only starts Sparkle inside a `.app` with an https feed and a
valid key (`UpdaterAvailability`).

- `CFBundleShortVersionString` = `VERSION`. `CFBundleVersion` = git commit count on HEAD (monotonic along main; override with `CADO_BUILD=<int>`). Needs full git history, not a shallow clone.
- **Pinned dependencies:** `Package.resolved` is committed and the release resolves and builds with `--force-resolved-versions`, so a DMG holds exactly the reviewed revisions of FluidAudio, WhisperKit and Sparkle, never a newer upstream release within `Package.swift`'s ranges (#27). To update one: `swift package update <name>`, review the upstream diff, commit `Package.resolved`.
- **Clean tree:** the DMG is built from the working tree but `gh release create --target` tags HEAD, so a real release refuses uncommitted changes (tracked files, or untracked ones under `Sources`, `Resources`, `scripts`, `Package.swift`/`.resolved`, `Makefile`). A rehearsal lists them as a warning and goes on.
- **Rehearsal** (no Apple credentials needed, any signing identity or `-`; result is *not* distributable):
  `SKIP_NOTARIZE=1 CADO_SIGN_IDENTITY="-" make release VERSION=0.4.1`
  It runs the appcast stage too (signing with the keychain key) and prints, but
  never runs, the publish command. With `-` the app doesn't launch: under the
  Hardened Runtime, library validation rejects an ad-hoc Sparkle.framework
  ("different Team IDs"). For a runnable rehearsal use any Apple Development
  identity, e.g. `CADO_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)"`.
- If notarization is rejected the script prints Apple's log; fix and rerun.

## Entitlements

`com.apple.security.device.audio-input` (microphone under Hardened Runtime) and
`com.apple.security.personal-information.calendars` (Calendar access for "Name
meetings from my calendar", #38: under Hardened Runtime EventKit gets no
access and macOS shows no prompt without it; the matching
`NSCalendarsFullAccessUsageDescription` is in `Info.plist`).
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
builds. Also confirm Settings › General's update switch, off, stops the daily check
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

## Dev signing keychain (from-source builds, #46)

`scripts/create_signing_cert.sh` makes the `Cado Self-Signed` identity in
`~/Library/Keychains/cado-signing.keychain-db`. Its password is random per Mac
and stored in your login keychain (generic password, service
`cado-signing-keychain`), and the key can be used by `/usr/bin/codesign` only
(it was a fixed password and any app before). `make package` / `make install`
read the password with `security find-generic-password`, unlock the keychain,
sign, and lock it again on exit; it also auto-locks after 5 minutes idle.

If the login keychain is locked or denies access, setup stops without creating
anything, and `make package` warns and signs ad-hoc (Accessibility grants won't
survive that rebuild). Only "item not found" counts as "no stored password".

**Remaining risk (from-source dev builds only; not DMG/Homebrew users):** any
process running as you can still read the stored password through
`/usr/bin/security` (it is the item's trusted app) and, while the keychain is
unlocked, call `/usr/bin/codesign` with the identity. This narrows the old
"fixed public password + any app" hole; it doesn't close it against malware
already running as you. Passwords are also passed to `security` on its command
line (`-p`/`-w`; it has no stdin form), so they are briefly visible in `ps` to
the same user.

**If you already have the old keychain** (fixed password `cado-local`): nothing to
do by hand. The next `make package` / `make install` finds no stored password,
opens the keychain with the old one and changes it to a random one in place. Same
certificate, so Microphone and Accessibility grants persist. The first run may ask
for your login password once, for the new login-keychain item (choose Always Allow
for `security`). To also drop the old key's "any application" access list, start
clean instead (the certificate changes, so grants reset once):

```sh
security delete-keychain ~/Library/Keychains/cado-signing.keychain-db
security delete-generic-password -s cado-signing-keychain   # if present
tccutil reset Accessibility com.ropats16.Cado
make install   # recreates the identity, then grant again
```

Tests (fake `security`, no keychain): `python3 -m unittest discover -s scripts/tests`.

## Homebrew tap

The cask lives in `packaging/homebrew/Casks/cado.rb` (template, `sha256 :no_check`).
It is published from a separate tap repo, `ropats16/homebrew-tap`.

One-time (you do this by hand):

```sh
gh repo create ropats16/homebrew-tap --public --description "Homebrew tap"
gh repo clone ropats16/homebrew-tap ~/src/homebrew-tap
export CADO_TAP_DIR="$HOME/src/homebrew-tap"   # shell profile
```

Each release: `make release VERSION=x.y.z` runs a final stage that, when
`CADO_TAP_DIR` is set, runs `scripts/bump_homebrew_cask.sh x.y.z <sha256> $CADO_TAP_DIR`.
That rewrites `version` and `sha256` in the tap's `Casks/cado.rb` (copying the
template in on first use) and commits `cado x.y.z` in the tap. It never pushes.
Skipped in rehearsal (`SKIP_NOTARIZE=1`), so a rehearsal DMG's sha never reaches the tap.

Then publish the GitHub Release (tag `vX.Y.Z`, attach `dist/Cado-X.Y.Z.dmg`) and push the tap:

```sh
git -C "$CADO_TAP_DIR" push
```

Users install with:

```sh
brew install --cask ropats16/tap/cado
```

## Extending

`scripts/release.sh` is a list of stage functions. Sparkle's appcast (#24) is
`stage_appcast`, after `stage_verify`; Homebrew cask bump (#25) hooks in after
it, using `VERSION`, `BUILD`, `DMG` and `DMG_SHA256`.
