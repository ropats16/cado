# Manual checks: security follow-ups (#46)

Owner-only steps; none are done by the agent.

## Before/after a release
- [ ] Rehearsal of the signed feed (touches the login keychain: Always Allow for `sign_update` once):
      `SKIP_NOTARIZE=1 CADO_SIGN_IDENTITY="Apple Development: ..." make release VERSION=x.y.z`,
      then `dist/appcast.xml` ends with a `sparkle-signatures` comment and the stage prints
      "EdDSA signature verifies".
- [ ] After the first signed feed is published: download it, run the `--feed` check in
      docs/RELEASING.md "Signed feed", then ship `SURequireSignedFeed` (+ decide
      `SUVerifyUpdateBeforeExtraction`) in the NEXT release. Check N to N+1 updates.
- [ ] GitHub settings (docs/RELEASING.md "Repo settings"): immutable releases, branch
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
- [ ] x86_64 (Rosetta or an Intel Mac): `arch -x86_64 swift build -c release` builds (not run by the agent).
- [ ] Dictate a few times with the app built from this branch (Metal path, default model).
