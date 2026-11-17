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
- [ ] Merge the first Dependabot PRs: a whisper.cpp submodule PR needs the checklist in
      plans/IMPLEMENTATION-NOTES.md ("Bumping whisper.cpp"), not a blind merge.

## Dev signing keychain (F-05)
- [ ] On the Mac with the OLD keychain: `make package`. Expect "Moved the signing keychain to a
      random password" once; a login-keychain prompt may appear for the new item (choose Always
      Allow for `security`). Dictation still works and Accessibility/Microphone grants persist.
      `security find-generic-password -s cado-signing-keychain` exists afterwards.
- [ ] On a Mac/user with no keychain: `make install` creates it; `security dump-keychain` shows
      the key without "any application" access.

## whisper.cpp 1.9.5 (F-08)
- [ ] x86_64 (Rosetta or an Intel Mac): `arch -x86_64 swift build -c release` builds (not run by the agent).
- [ ] Dictate a few times with the app built from this branch (Metal path, default model).
