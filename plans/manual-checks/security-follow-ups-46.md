# Manual checks: security follow-ups (#46)

Operational checks and remaining owner acceptance steps. Status updated on
2026-11-17 while implementing #49; unchecked items have not been verified.

## Verified for #49
- [x] Downloaded the public latest v0.2.0 `appcast.xml` and ran the public-key
      `--feed` verifier: it is unsigned and correctly rejected. Signed-feed
      enforcement remains blocked until the next signed feed is published.
- [x] Enabled immutable releases, Dependabot alerts/security updates, and the
      active `Protect main` ruleset (27473892): PRs required, zero approvals,
      review threads resolved, deletions/force pushes blocked, no bypass.
- [x] `make package` migrated the old signing keychain to a random password,
      retained `Cado Self-Signed`, and produced a bundle passing strict code
      signature verification. No app was installed and no TCC grants reset.
- [ ] Confirm Microphone/Accessibility grants and a short dictation after the
      migration. Computer-use access was unavailable; owner confirmation is pending.
- [ ] Publish the prepared 0.4.0 release with its signed feed, download that
      published feed and verify it. Then enable both `SURequireSignedFeed` and
      `SUVerifyUpdateBeforeExtraction` for 0.4.1 and check the update path.
- [ ] From the 0.4.1 app itself, accept a valid signed feed, reject unsigned and
      tampered feeds, and reject a tampered archive before extraction. The
      0.4.0 to 0.4.1 upgrade alone does not test the new flags.


## Before/after a release
- [ ] Rehearsal of the signed feed (touches the login keychain: Always Allow for `sign_update` once):
      `SKIP_NOTARIZE=1 CADO_SIGN_IDENTITY="Apple Development: ..." make release VERSION=x.y.z`,
      then `dist/appcast.xml` ends with a `sparkle-signatures` comment and the stage prints
      "EdDSA signature verifies".
- [ ] After the first signed feed is published: download it, run the `--feed` check in
      docs/RELEASING.md "Signed feed", then ship both `SURequireSignedFeed` and
      `SUVerifyUpdateBeforeExtraction` in the NEXT release. Check N to N+1 updates.
- [x] GitHub settings (docs/RELEASING.md "Repo settings"): immutable releases, branch
      protection / ruleset on `main`, Dependabot alerts + security updates.
- [ ] Merge the first Dependabot PRs (Actions, Swift packages) only after building and testing
      locally (no CI). whisper.cpp is not on Dependabot: bump by hand to a release tag with the
      checklist in plans/IMPLEMENTATION-NOTES.md ("Bumping whisper.cpp").

## Dev signing keychain (F-05)
- [ ] On the Mac with the OLD keychain: `make package`. Expect "Moved the signing keychain to a
      random password" once; a login-keychain prompt may appear for the new item (choose Always
      Allow for `security`). Dictation still works and Accessibility/Microphone grants persist.
      `security find-generic-password -s cado-signing-keychain` exists afterwards.
- [ ] On a Mac/user with no keychain: `make install` creates it; `security dump-keychain` shows
      the key without "any application" access.
- [ ] After `make package`: `security show-keychain-info ~/Library/Keychains/cado-signing.keychain-db`
      shows `timeout=300`; the keychain is locked once the build ends (check with `security
      show-keychain-info` failing/prompting, or `security unlock-keychain` needed again).
- [ ] With the login keychain locked: `make package` warns and signs ad-hoc (no hang, no GUI
      prompt for an unknown password).

## whisper.cpp 1.9.5 (F-08)
- [x] x86_64 through Rosetta: `arch -x86_64 swift build -c release` completed
      successfully on 2026-11-17 (189 seconds, warnings only). This is a build
      check, not an Intel runtime/audio test.
- [ ] Dictate a few times with the app built from this branch (Metal path, default model).
