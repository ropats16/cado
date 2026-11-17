# VoiceType — Implementation Notes (durable build/integration decisions)

Context-saving doc so the whisper.cpp/Metal integration doesn't have to be
re-derived. Reflects the working state of Phase 1.

## Identity & layout
- App **VoiceType**, bundle id **com.local.VoiceType**, menu-bar agent (`LSUIElement`).
- SwiftPM-only (`swift-tools-version: 5.9`, Swift 5 language mode — avoids Swift 6
  strict-concurrency churn). macOS 14+, Apple-Silicon.
- whisper.cpp vendored as submodule at **`Sources/CWhisper/whisper.cpp`**, pinned to
  tag **v1.9.5**, commit `d1be6fde11ac6e0407606b4e42fe72d34add8037` (was v1.9.1-75 `0ae02cd`; bumped in #46 for CVE-2026-110810). The submodule lives *inside* the
  CWhisper target dir because SwiftPM only compiles sources under a target's path.
- whisper.cpp is bumped BY HAND to release tags (checklist in the whisper.cpp
  sections below / docs/RELEASING.md "Pinned dependencies"); no Dependabot
  gitsubmodule entry (it would track untagged master). The repo has no CI, so
  every Dependabot PR (Actions, Swift packages) must be built and tested locally
  before merging.
- Models + config live in `~/Library/Application Support/VoiceType/`.

## whisper.cpp + Metal via SwiftPM (the hard part — DONE & verified)
Verified working: `tiny.en` transcribes `jfk.wav` in ~0.4s on **Metal GPU**
(`use gpu = 1`, "using embedded metal library", Apple M3 Max, backends = 3).

Key facts (current whisper.cpp has **no Package.swift**, so we vendor sources):
- **Two `.target` setup** in `Package.swift`: a C/C++/ObjC `CWhisper` target compiling
  the exact ggml source list (core + `ggml-cpu` incl. `arch/arm/*` + `llamafile/sgemm`
  + `ggml-metal` + `ggml-blas`), and the Swift `VoiceType` executable.
- **Metal shaders are EMBEDDED, not precompiled.** Xcode 26 removed the default Metal
  toolchain (`xcrun metal` → "missing Metal Toolchain"). So we use
  `GGML_METAL_EMBED_LIBRARY`: `scripts/embed_metal_shader.sh` merges, per kernel
  source (v1.9.5 split the shader into `ggml-metal/kernels/*.metal`, one MTLLibrary each;
  the list is read from upstream's `ggml-metal/CMakeLists.txt`), the headers it
  includes + `ggml-common.h` + `ggml-metal-impl.h`, writes them to `Sources/CWhisper/metal-embed/`
  and emits `ggml-metal-embed.s` (`.incbin` of each under `ggml_metallib_<kind>_{start,end}`).
  At runtime ggml JIT-compiles them via `newLibraryWithSource` (the OS
  runtime compiler works **without** the toolchain — verified). Nothing to bundle in the
  `.app`. The generated files are gitignored and must be regenerated before `swift build`
  (run the script in setup / `make build`).
- **`.metal` files must be excluded** (`ggml-metal/kernels`, `metal-embed/`) from the target or SwiftPM auto-compiles them as
  Metal resources (needs the missing toolchain). Also exclude `examples/` (asset catalogs
  trigger `defaultLocalization`) and unused ggml backends. See `Package.swift` `exclude:`.
- **Defines:** `GGML_USE_CPU`, `GGML_USE_METAL`, `GGML_METAL_EMBED_LIBRARY`, `GGML_USE_BLAS`,
  `GGML_USE_ACCELERATE` (+ Accelerate LAPACK macros). Do **NOT** define
  `GGML_METAL_USE_BF16`/tensor — device gates them off (pre-M5), keeps host/shader in sync.
  Version macros normally injected by cmake: `WHISPER_VERSION` is a define in
  `Package.swift`; `GGML_VERSION`/`GGML_COMMIT` live in the stand-in header
  `Sources/CWhisper/ggml-config/ggml-version.h` (cmake generates `ggml-version.h`
  from a template). Update both with every bump.
- **ARC off for ObjC:** ggml's `ggml-metal-*.m` use manual retain/release →
  `cSettings.unsafeFlags(["-fno-objc-arc", "-Qunused-arguments", "-Wno-shorten-64-to-32"])`.
- **Importer include paths:** SwiftPM does NOT propagate the C target's `headerSearchPath`
  to the Swift importer, and `whisper.h` includes `ggml.h`/`ggml-cpu.h`. Fixed by adding
  `-Xcc -ISources/CWhisper/whisper.cpp/include` and `.../ggml/include` to the **VoiceType
  target's `swiftSettings`**. Module map shim: `Sources/CWhisper/include/{module.modulemap,
  whisper-shim.h}` (`#include "whisper.h"`), `import CWhisper`.
- C API: `whisper_context_default_params()` → `use_gpu=true, flash_attn=true` →
  `whisper_init_from_file_with_params` → `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`
  (`language="en"`, `no_timestamps=true`, all `print_*=false`) → `whisper_full` →
  `whisper_full_n_segments`/`_get_segment_text`. Context is **not** thread-safe — only the
  single serial queue in `TranscriptionEngine` calls it.

### Bumping whisper.cpp (checklist, from the v1.9.5 bump)
1. `git -C Sources/CWhisper/whisper.cpp fetch --tags && git checkout <tag>`.
2. Diff the CMake source lists (`ggml/src/CMakeLists.txt`, `ggml-cpu/CMakeLists.txt`,
   `ggml-metal/CMakeLists.txt`, `ggml-blas`) against `Package.swift`: v1.9.5 added
   `ggml-cpu/tiled/*.cpp`, `ggml-metal-fusion.cpp`, `ggml-metal-tuning.cpp`, and moved the
   shader to `kernels/`. New backend dirs get an `exclude`.
3. Update `WHISPER_VERSION` (Package.swift), `ggml-config/ggml-version.h`, the pin above.
4. `make embed && swift build` (link errors name missing sources). v1.9.5's
   `whisper.cpp` references ANEForge (`src/aneforge`, env-var-driven `dlopen`); it is
   deliberately not built, `Sources/CWhisper/stubs/whisper-aneforge-stub.cpp` stubs it.
5. `Cado --selftest` with tiny.en, small.en-q5_1 and medium.en on `samples/jfk.wav`, then
   `swift test`. Not covered by the bump: the x86_64 (Rosetta) CPU build.

## Model download
- Host is **`huggingface.co/ggerganov/whisper.cpp`** (GitHub moved to ggml-org; the HF
  model repo did **not**). `scripts/download_model.sh <model>` → Application Support.
- medium.en ~1.5 GiB (default), tiny.en 75 MiB (used for the smoke test).

## Diagnostics
- `VoiceType --selftest --model <ggml.bin> --wav <16kHz.wav>` loads the model and
  transcribes a WAV (no UI/permissions). Used to verify the engine.
- `VoiceType --bench --model <file> [--engine <id>]` benchmarks an engine over
  `.bench/fixtures` (from `scripts/fetch_bench_fixtures.sh`): latency, RTF, peak
  RAM, load time, WER → table + JSON. See `plans/benchmark.md`.

## Code signing & TCC persistence (grants survive rebuilds)
- **Problem:** ad-hoc signing (`codesign -s -`) gives a new CDHash every build,
  and TCC pins Accessibility to the CDHash → each `make install` silently revoked
  the grant.
- **Fix:** `scripts/create_signing_cert.sh` creates a one-time **self-signed
  code-signing certificate** ("VoiceType Self-Signed") in a dedicated local
  keychain (`~/Library/Keychains/voicetype-signing.keychain-db`, password
  `voicetype-local` — not a secret). `package_app.sh` signs with it (falls back to
  ad-hoc if absent). The designated requirement becomes
  `identifier "com.local.VoiceType" and certificate leaf = H"<cert hash>"` —
  **stable across rebuilds**, so the grant persists.
- **Gotchas learned:**
  - Use **`/usr/bin/openssl` (LibreSSL)**, not Homebrew OpenSSL 3 — OpenSSL 3
    writes a PKCS12 MAC `security import` can't verify ("MAC verification failed").
  - The cert is self-signed → untrusted (`CSSMERR_TP_NOT_TRUSTED`), so
    `security find-identity -v` (valid-only) does NOT list it. Use
    `security find-identity -p codesigning` (no `-v`). codesign still signs with it
    (trust only matters for Gatekeeper, not for signing or the TCC DR).
  - Switching identity (adhoc→cert) changes the DR, so reset once after the switch:
    `tccutil reset Accessibility com.local.VoiceType`, relaunch, grant again. From
    then on it persists.
  - Undo entirely: `security delete-keychain ~/Library/Keychains/voicetype-signing.keychain-db`.

## Phase 1 status
Done & compiling (debug+release): config, permissions, audio capture, hotkey (hold =
Right ⌥ via flagsChanged + device bit), text delivery (paste + read-driven clipboard
restore, `Delivery/`), indicator (NSPanel pinned bottom-left; no caret tracking; since replaced by the mascot overlay, #19), menu-bar shell, dictation wiring,
whisper bridge (verified). **Remaining:** `.app` packaging (`scripts/package_app.sh`,
`setup.sh`, Makefile wiring) and interactive verification (mic/Accessibility grants +
real dictation in 5 apps) — the latter requires the human.
