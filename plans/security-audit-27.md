# Security audit before first public release (#27)

Date: 2026-11-17. Branch `issue-27`, base `2bfe3aa`. Auditor: Claude (agent), following the
`/cso` methodology in comprehensive mode (2/10 confidence bar), adapted to a native macOS app.

## Scope

- **App:** `Sources/Cado/**` (audio capture, process tap, clipboard paste + Accessibility, hotkey
  event tap, notes folder + bookmark, front-matter/Markdown parsing, note file naming, model
  downloads + pin verification, launch ping, Sparkle updater, config/support files, logging),
  `Resources/Info.plist`, `Resources/Cado.entitlements`.
- **Shipped artifact:** the published `Cado-0.1.0.dmg` and `appcast.xml` from the v0.1.0 GitHub
  release, downloaded and inspected read-only.
- **Release pipeline:** `scripts/release.sh`, `package_app.sh`, `sign_sparkle.sh`,
  `make_appcast.py`, `verify_update_signature.swift`, `bump_homebrew_cask.sh`, `download_*.sh`,
  `lib/folder_model.sh`, `fetch_bench_fixtures.sh`, `setup.sh`, `create_signing_cert.sh`,
  `Makefile`, `packaging/homebrew/`, `docs/RELEASING.md`, the published tap cask.
- **Dependencies:** `Package.swift`, `Package.resolved`, whisper.cpp submodule pin, FluidAudio,
  argmax-oss-swift (WhisperKit), Sparkle, swift-argument-parser.
- **Secrets:** working tree + full git history (197 commits, all refs).
- **Out of scope:** `~/.claude/skills` (cso Phase 8: not part of the product); the maintainer's
  machine, keychain and Apple/GitHub account settings beyond what `gh api` exposes read-only.
  No `.env` file was read (none is tracked).

## Method

- Read the code paths above end to end; grepped the app and dependency sources for URLs,
  `URLSession`, `NSWorkspace.open`, logging, file writes, event taps, AX reads.
- Shipped DMG: `codesign -dvvv --entitlements -`, `codesign --verify --deep --strict`,
  `spctl -a -t exec`, `stapler validate`, nested Sparkle code signatures, `otool -L`,
  `nm`/`strings` on the binary, `plutil -p Info.plist`; verified the appcast's
  `sparkle:edSignature` over the DMG against the shipped `SUPublicEDKey` with
  `scripts/verify_update_signature.swift` (passes). Compared the tap's cask sha256 with the DMG
  (match: `8b5cb77f…9772`).
- Redirect chains of every download host probed with `curl -sI` (headers only).
- Advisories: GitHub security advisories for all five dependency repos (`gh api`), web search
  for whisper.cpp CVEs, Sparkle `CHANGELOG` in the resolved artifact.
- Secrets: `git log --all -p` grepped for key/token/password patterns, PEM headers, long
  base64 blobs, and key-like filenames in all objects.
- Fixes test-first where there is a seam; full `swift test` and `python3 -m unittest` at the end.

## Summary

| Severity | Count | Fixed | Open / accepted |
| --- | --- | --- | --- |
| Critical | 0 | – | – |
| High | 0 | – | – |
| Medium | 2 | 1 (F-01) | 1 needs owner decision (F-02) |
| Low | 6 | 3 (F-03, F-04, F-06) | 2 open (F-05, F-07), 1 accepted (F-08) |
| Info | 9 | 1 (F-17) | 8 accepted / noted |

No high or critical findings. No secrets in the tree or history.

## Findings

Status: **fixed** (commit on `issue-27`), **open** (recommended fix given), **accepted** (reason
given), **needs owner decision**.

| ID | Sev | Conf | Location | Description | Exploit scenario | Status |
| --- | --- | --- | --- | --- | --- | --- |
| F-01 | Medium | 8/10 | `.gitignore:5` (before fix), `scripts/release.sh:202`, `scripts/package_app.sh:39` | `Package.resolved` was gitignored and the release ran a plain `swift package resolve` / `swift build`, so each release resolved FluidAudio/WhisperKit/Sparkle afresh to the newest version inside `.upToNextMinor` ranges. No lockfile, so a new upstream patch release (or a retagged version) ships inside a Developer ID-signed, notarized DMG with no review, and builds weren't reproducible. | A compromised maintainer account on FluidAudio publishes 0.17.8 with a payload; the next `make release` picks it up silently and Cado's own signature vouches for it. | **Fixed** `c89e9da`: `Package.resolved` committed; release preflight requires it and runs `swift package --force-resolved-versions resolve`; `package_app.sh` builds with `--force-resolved-versions` when stamping a release (dev builds unchanged). A tampered pin was checked to fail resolution. RELEASING.md documents the update procedure. |
| F-02 | Medium | 6/10 | `Resources/Info.plist:41-50`, `scripts/release.sh` `stage_appcast`, GitHub repo settings | The appcast is unsigned (Sparkle 2.9+ supports signed feeds; `SURequireSignedFeed` not set), `SUVerifyUpdateBeforeExtraction` is off, and GitHub immutable releases are off (`gh api …/immutable-releases` → `enabled:false`). Code integrity is still protected (EdDSA over the DMG + Developer ID; Sparkle refuses bundle downgrades), but whoever can edit the release assets controls the feed text. | Someone with a stolen `gh` token replaces `appcast.xml`: withholds a security fix from every user (freeze), or shows a spoofed "Cado x.y is available" notification/menu title (`SparkleUpdater.swift:70`). They still can't install code without the EdDSA key and the Developer ID. | **Needs owner decision.** Recommended: (1) enable GitHub immutable releases; (2) in `stage_appcast`, sign the feed with `sign_update --account cado dist/appcast.xml` (embeds the signature) and verify it; (3) only after a signed feed is live, add `SURequireSignedFeed` = YES to Info.plist (order matters: a client requiring signatures rejects an unsigned feed); (4) optionally `SUVerifyUpdateBeforeExtraction` = YES (trade-off: EdDSA key loss can then no longer be recovered via the Apple code-signing fallback). Each needs the keychain key or a repo setting, so not done here. |
| F-03 | Low | 7/10 | `Sources/Cado/Library/LibraryView.swift:195` (before fix) | The library renders note links via `AttributedString(markdown:)` in SwiftUI `Text`, which opens any URL scheme through the default `openURL` (`file:`, app URL schemes, `x-apple.systempreferences:` …). Notes come from a user folder that may be a synced/shared Obsidian vault or edited by other tools, and link text hides the target. | A note in a shared vault contains `[meeting recording](file:///Users/x/Downloads/evil.app)`; one click launches it (Gatekeeper still applies) or opens a local file/app handler. | **Fixed** `1042cce`: `NoteLinkPolicy` (http/https/mailto only) applied via `OpenURLAction` on `MarkdownBodyView`; other schemes are discarded. Tests: `NoteLinkPolicyTests`. Note: `obsidian://` links are now ignored too. Regressed in the #42 restyle (the detail pane stopped using `MarkdownBodyView`) and re-fixed: `LibraryDetailView.linkAction` → `LibraryViewModel.openLink`, set with `noteLinks(_:)` on the detail pane's root; `MarkdownBodyView` removed. Test: `testTheDetailPaneOpensOnlyWebAndMailLinks`. |
| F-04 | Low | 6/10 | `Sources/Cado/Transcription/URLSessionDownloadTransport.swift:152` (before fix) | The model download transport wrote whatever body the server sent; size and SHA-256 were checked only after the stream ended. | A compromised CDN or a misbehaving proxy streams endlessly for `weight.bin`; the disk fills while the UI sits at 100 %. (Integrity is unaffected: the hash check rejects the file.) | **Fixed** `d5a9613`: `DownloadTransport.fetch(…upTo:)`; the downloader passes the pinned size and the transport stops with `ModelDownloadError.oversized` before writing past it. Tests: `testABodyPastTheLimitStopsAtTheLimit`, `testABodyOfExactlyTheLimitIsKept`, `testEachFileIsFetchedUpToItsPinnedSize`. |
| F-05 | Low | 7/10 | `scripts/create_signing_cert.sh:19,65` | The from-source dev signing identity "Cado Self-Signed" lives in a keychain with a fixed public password (`cado-local`), and its key is imported with `-A` (any app may use it without a prompt). TCC grants (Microphone, Accessibility) for a `make install` build are tied to that certificate. Does not affect DMG/Homebrew users (Developer ID). | Malware already running as the developer signs its own binary with that identity and identifier `com.ropats16.Cado`, inheriting the Accessibility grant (synthetic keystrokes into any app) and Mic access without a prompt. | **Open.** Recommended: generate a random keychain password per machine and keep it in the login keychain (`security add-generic-password`), read it in `package_app.sh`; import the p12 with `-T /usr/bin/codesign` only (drop `-A`). Not done: touches the keychain and the dev workflow; can't be tested here. |
| F-06 | Low | 9/10 | `README.md` "Network activity" (lines 510-515 before fix) | README mismatches: release assets are served from `release-assets.githubusercontent.com` (README said `objects.githubusercontent.com`); `nom.telemetrydeck.com` is never contacted by 0.1.0 (`CadoTelemetryAppID` is empty in the shipped Info.plist); HF CDN hosts not named; WhisperKit's tokenizer fallback (F-07) undocumented. | Users/firewall rules built from the README don't match real traffic. | **Fixed** `e10c686` (README only). See the allowlist table below. |
| F-07 | Low | 4/10 | `.build/checkouts/argmax-oss-swift/Sources/WhisperKit/Utilities/ModelUtilities.swift:57-80`; `Sources/Cado/Transcription/WhisperKitAdapter.swift:40` | WhisperKit falls back to downloading a tokenizer from `huggingface.co` if the local `tokenizer.json` exists but fails to load. Cado only checks that the file exists. Catalog folders are SHA-256-verified before load, so this can't happen for them; a hand-made model folder could trigger it. | A user points `modelPath` at a WhisperKit folder with a corrupt tokenizer; the app makes an unannounced request to huggingface.co. | **Open** (documented in README). Recommended: pass a pre-loaded tokenizer or fail the load when the local tokenizer can't be parsed (needs an upstream hook or a local parse check). |
| F-08 | Low | 5/10 | `Sources/CWhisper/whisper.cpp` @ `0ae02cd` (v1.9.1-75) | CVE-2026-110810: out-of-bounds read in `whisper_model_load` / `whisper_vad_init_with_params` on a crafted `ttype` (fixed upstream in v1.9.5, commit `60c0be6a`, not an ancestor of our pin). | Only a crafted ggml file reaches it: catalog models are SHA-256-pinned and verified before load, VAD is off in the app (bench only), so the user must point `modelPath` at a malicious file themselves. Impact: crash / in-process OOB read. | **Accepted for 0.1.x** (reachable only through a user-chosen, unverified model file). Recommended follow-up: bump the submodule to ≥ v1.9.5 in its own issue (698 commits, likely `Package.swift` source-list changes, needs a model regression run). |
| F-09 | Info | 7/10 | `Resources/Info.plist:24-26`, `Sources/Cado/Onboarding/OnboardingView.swift:80`, `Settings/SettingsView.swift:67` | The "Help count Cado's users" switch is shown although the build has no TelemetryDeck app ID, so it does nothing. Errs toward sending less than stated. | – | **Open (product).** Hide the switch when `LaunchPing.isConfigured` is false, or set the app ID before the next release. |
| F-10 | Info | 3/10 | `Sources/Cado/Transcription/ModelVerifier.swift:103` | The checksum cache (`model-checksums.json`, user-writable) is trusted when a file's size/mtime/ctime/inode match. | Requires code already running as the user, who could equally replace the app. | **Accepted** (outside the threat model). |
| F-11 | Info | 3/10 | `Sources/Cado/Transcription/Engines/EngineDescriptor.swift:98` | Models chosen by path (not from the catalog) are loaded without hash verification into whisper.cpp / Core ML. | User-chosen file; see F-08. | **Accepted** (user's explicit choice). |
| F-12 | Info | 3/10 | `Sources/Cado/Notes/NotesLibrary.swift:260` | A `*.md` symlink in the notes folder is followed: its target is read and shown in the library. Writes are safe (rename uses an atomic write that replaces the link, delete trashes the link). | Shows a local file to the same user; nothing is sent anywhere. | **Accepted** (Obsidian users symlink notes). Revisit if transcripts/notes are ever sent off-device (#35). |
| F-13 | Info | 4/10 | GitHub repo `ropats16/cado` | Branch protection off; Dependabot security updates off. Secret scanning + push protection are on (verified). | – | **Open (owner).** Turn on Dependabot alerts (Swift packages are covered by the GitHub Advisory DB). |
| F-14 | Info | 2/10 | `scripts/lib/folder_model.sh:92`, `download_model.sh:78`, `download_vad_model.sh:35` | `curl -L` follows redirects without `--proto =https --proto-redir =https`. | No integrity impact: every file is size + SHA-256 pinned. | **Accepted.** |
| F-15 | Info | 2/10 | `Sources/Cado/Meeting/MeetingAdapters.swift:56` | Meeting audio kept after a failed transcription/quit stays in `~/Library/Application Support/Cado/Meeting Audio` indefinitely. Documented in README "Privacy". | – | **Accepted**; consider an age-based cleanup like `removeStalePartFolders`. |
| F-16 | Info | 2/10 | `Sources/Cado/Meeting/MeetingSession.swift:386`, `Support/Log.swift:10` | Log lines are `privacy: .public`; they include file paths (note filename = app name + date) but never transcript or dictated text (all `Log.*` call sites checked; whisper.cpp only forwards warnings/errors; WhisperKit `logLevel: .none`). | – | **Accepted.** |
| F-17 | Info | 9/10 | `Package.swift:39` | `WHISPER_VERSION` define said 1.8.0; the submodule is v1.9.1 (`whisper_version()` misreports, hindering advisory matching). | – | **Fixed** `0f44353`. |

### Not findings (checked)

- **Entitlements / runtime (shipped 0.1.0):** only `com.apple.security.device.audio-input`; Hardened
  Runtime flag set on the app, `Autoupdate` and `Updater.app`; no `get-task-allow`, no
  `disable-library-validation`, no JIT; secure timestamp present; Developer ID Team `45N454493C`;
  notarized and stapled; `codesign --verify --deep --strict` passes; only non-system dylib is the
  embedded Sparkle 2.10.1. No URL schemes, no XPC services shipped.
- **ATS:** no `NSAppTransportSecurity` exceptions, so URLSession (downloads, ping) is https-only,
  including redirects. Updater refuses a non-https `SUFeedURL` or a non-32-byte key (`AppUpdater.swift:40-44`).
- **Sparkle advisories:** GHSA-3x7w-j75x-ppq5, GHSA-4v99-qgq9-6pxp (≤2.9.5), CVE-2026-115568
  (≤2.9.4), CVE-2026-47121/47122 (≤2.9.1) are fixed in the shipped 2.10.1. GHSA-gcjm-h3jh-p2vc
  (published today, all versions, `.pkg` downgrade) does not apply: Cado ships an app bundle in a
  DMG, whose installer has the downgrade check. No advisories on FluidAudio, argmax-oss-swift,
  swift-argument-parser, ggml-org/ggml (GitHub DB).
- **FluidAudio's prebuilt NemoTextProcessing (Rust) xcframework:** fetched by SwiftPM but not
  linked: no Nemo/Rust symbols in the shipped binary (`nm`).
- **Model download integrity:** every catalog file is size + SHA-256 pinned (folder models also
  commit-pinned); verified before use; pinned and manifest paths reject `..`, `.` and absolute
  paths (`ModelFolderVerifier.swift:70`); range-resume refuses misaligned 206s.
- **Clipboard:** paste writes are marked `org.nspasteboard.TransientType`; concealed/transient
  clipboard contents (password managers) are never restored; snapshot is memory-only.
- **Accessibility / hotkeys:** event tap is `.listenOnly` and keeps only edge state; the AX probe
  reads role + settable only, never field contents.
- **Notes:** filenames come from `NotesLibrary.sanitise` (no `/`, `\`, `:`, control chars, leading
  dots); ids with `/` or a leading `.` are refused; front matter is a hand-rolled line parser (no
  YAML deserialisation); non-UTF-8 files are never rewritten.
- **Recent dictations:** off by default, 0600 file, cleared when switched off.
- **Speech:** Apple engine is `SpeechTranscriber` (on-device only). Mic stays open 30 s after a
  dictation (documented: `keepMicWarm` row in README).
- **Launch ping:** fields exactly as README states; ephemeral session, 5 s timeout; inert in 0.1.0.
- **Release pipeline:** strict mode everywhere; version/build/sha validated by regex before use
  in `sed`/paths; Sparkle signed inside-out without `--deep`; unexpected nested code fails the
  release; EdDSA signature verified against the key inside the built app; rehearsal never reaches
  the tap; notarization log fetched on failure. `make_appcast.py` parses the fetched feed with
  ElementTree (no external entity resolution). Homebrew tap cask pins the DMG sha256 (template's
  `:no_check` is replaced by `bump_homebrew_cask.sh`, which verifies the rewrite).
- **Secrets archaeology:** no private keys, tokens, passwords, `.env`/`.pem`/`.p12`/`.key` files
  in any commit. `SUPublicEDKey` is a public key. The notarytool example in `docs/RELEASING.md`
  uses placeholders. `create_signing_cert.sh`'s fixed passwords are covered by F-05.

## Network allowlist verification

Every host the shipped app (0.1.0 binary + current source) can contact, from static analysis of
`Sources/Cado` and the dependency code paths the app calls, plus live redirect probes.

| Host | Purpose | When contacted | README said (before #27) | Verdict |
| --- | --- | --- | --- | --- |
| `github.com` | Sparkle feed `…/releases/latest/download/appcast.xml` (302 → `…/download/v0.1.0/appcast.xml`) and DMG URL | Release builds: daily check (on by default, off in Settings › Updates) + manual check | Listed | Match |
| `release-assets.githubusercontent.com` | Actual feed and DMG bytes (302 target) | Same as above | `objects.githubusercontent.com` | **Mismatch → README fixed** |
| `huggingface.co` | Model files (`FolderModelDownloader.baseURL`); small files served directly via `/api/resolve-cache/…` | Only on **Download** in Settings › Model / onboarding | Listed | Match |
| `*.hf.co` (observed `us.aws.cdn.hf.co`) | Hugging Face CDN (302 target for large files) | Same | "Hugging Face's CDN" (unnamed) | **README made specific** |
| `huggingface.co` (WhisperKit fallback) | Tokenizer download if a local `tokenizer.json` fails to load (F-07) | Only for a non-catalog WhisperKit folder with a bad tokenizer | Said libraries never download | **Mismatch → README documents the exception** |
| `nom.telemetrydeck.com` | Opt-in launch ping | Never in 0.1.0 (empty `CadoTelemetryAppID`); would be once per launch if opted in and an app ID were set | Listed as sent when opted in | **Mismatch → README fixed** |
| Apple (OS-managed) | Apple Speech language model via `AssetInventory` | Only on **Download** for an Apple Speech model | Listed | Match (process is macOS's, not Cado's) |
| — | Acknowledgements/README links | Opened in the browser on click; the app makes no request | Not listed | OK (not app traffic) |

No other URL, socket or host appears in the app's runtime paths; FluidAudio's and WhisperKit's
own downloaders are never called (`AsrModels.loadLocal`, `WhisperKitConfig(download: false)`).

## Could not verify

- No live traffic capture (Little Snitch / pcap) of a running app; the allowlist is static
  analysis + redirect probes. Sparkle's exact User-Agent and runtime behaviour on a bad
  signature were not exercised.
- The release path itself (`make release`) was not run (no credentials, instructed not to). The
  pinning change was checked with `swift package --force-resolved-versions resolve`, a deliberately
  tampered pin (fails), `swift build --force-resolved-versions --show-bin-path`, and `bash -n`.
- That 0.1.0 was built from exactly the now-committed pins: Sparkle 2.10.1 is confirmed in the
  DMG; FluidAudio 0.17.7 and argmax-oss-swift 1.1.1 are the only/newest tags in their ranges, so
  almost certainly what shipped, but not provable from the binary.
- GitHub account security (2FA, token scopes), the maintainer's keychain and Apple ID.
- whisper.cpp/ggml code was not audited beyond the published CVEs; Core ML model parsing is
  Apple's.
- What the OS does when `AssetInventory` downloads Apple Speech models.

## Verification

- `swift test`: 1095 XCTest tests, 5 skipped (live/render harnesses), 0 failures; swift-testing: 0 tests.
- `python3 -m unittest discover -s scripts/tests`: 6 tests OK.
