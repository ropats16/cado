# Manual checks: language routing & tier guidance (#55, #61)

What the tests can't reach: live SwiftUI picker menus on screen, live download
progress and hot-swap on real models, and visual layout in light and dark mode.
Design and benchmarks: `plans/multilingual-tiers-61.md`.

Already verified without a human:
- `SettingsEngineTests`: English → Auto-detect → English → Turbo directly, even
  with an English-only Whisper fallback (`modelPath` = `ggml-medium.en.bin` and
  no multilingual model installed); `unavailableEngines` section and language
  fallback recovery note; hardware-unavailable engines (Intel) omit the
  language-recovery hint; Automatic engine round-trip.
- `SettingsModelTests`: Language stays editable on English-only Whisper models
  and switches Automatic directly to a multilingual model.
- `SettingsLanguageGuidanceTests`: exact copy and inline Download row for the
  owner's M3 Max 48 GB setup, 16 GB+ Full tier, 8 GB Apple Silicon Basic tier,
  Intel 8 GB Limited and 16 GB Basic tiers, WhisperKit, Turbo EU languages,
  explicit `.en` fallback with no multilingual models, and live reload after
  downloading the offered model.
- `SettingsModelDownloadTests`: `.en` whisper models stay downloadable under
  Auto-detect even when a multilingual model is installed.
- `UserFacingCopyTests`: all guidance and fallback strings are plain words with
  no developer commands, paths, emoji, or "click" in non-clickable text.

## Setup

Use a throwaway support folder (`CADO_APP_SUPPORT`) or test carefully — never
overwrite real notes or config.

```sh
make package
pkill -x Cado
open dist/Cado.app
```

## Checks

1. **English on Turbo unchanged.** On an Apple Silicon Mac with Turbo installed
   and Language = English: Settings › Speech Model shows Engine = Turbo (or
   Automatic (Turbo)), Language = English (enabled), and **no** guidance line or
   download row under Language. Dictate an English sentence: behaves identically
   to before.
2. **#55 round-trip without Apple Speech.** With Engine = Turbo (English/EU)
   and Language = English, change Language to **Auto-detect**:
   - Engine switches to Whisper (whisper.cpp) and shows:
     `Using Whisper (whisper.cpp) because Turbo (English/EU) doesn't support auto-detect. Change Language to switch back.`
   - Open the **Engine** menu: **Turbo (English/EU)** is visible (disabled)
     under `Unavailable for Auto-detect — change Language to use`.
   - The **Language** picker stays enabled and shows **Auto-detect** (never
     greyed out or reset to English, even if you temporarily move multilingual
     `ggml-*.bin` files out of the models folder so only `.en` models remain).
   - Change Language back to **English**: Engine returns immediately to **Turbo
     (English/EU)**, the fallback note disappears, and no intermediate engine
     (like Apple Speech) is needed.
3. **Owner's Mac (48 GB M3 Max, Full tier, leftover `modelPath` = `ggml-medium.en.bin`,
   `small-q5_1` installed, `large-v3-turbo-q5_0` not yet installed):**
   - Switch Language to **Auto-detect**.
   - Under Language, check the line reads:
     `Whisper medium.en only understands English, so Auto-detect uses Whisper small-q5_1 instead. Download Whisper large-v3-turbo-q5_0 below for better accuracy in other languages.`
   - Directly below it, `large-v3-turbo-q5_0 (574 MB)` has a **Download** button.
   - Click **Download**: progress shows inline, Cancel works if tested, and once
     finished the engine hot-swaps to `large-v3-turbo-q5_0`, the Download row
     disappears, and the line updates to:
     `Whisper medium.en only understands English, so Auto-detect uses Whisper large-v3-turbo-q5_0 instead.`
   - Dictate Hindi + English: both come out cleanly in their own scripts.
4. **8 GB Apple Silicon Mac (Basic tier, if available):**
   - Switch Language to **Auto-detect** with only `small.en-q5_1` + Turbo
     installed: Language shows a problem line naming `Whisper small-q5_1` as not
     downloaded, noting `Accuracy for other languages is limited on this Mac —
     more language support is coming soon.`, and offering `small-q5_1 (190 MB)`
     with a **Download** button.
   - After downloading `small-q5_1`: the line turns normal tone and reads
     `Auto-detect uses Whisper small-q5_1. Accuracy for other languages is
     limited on this Mac — more language support is coming soon.`
   - Switch Language to **German** with Turbo installed: Engine stays Turbo and
     Language reads `German uses Turbo.` (no limited-accuracy note).
5. **Intel Mac (Limited / Basic tier, if available):**
   - On English with Whisper Automatic (`base.en-q5_1` / `small.en-q5_1`), the
     Language picker is **enabled** (previously greyed out).
   - Switch Language to **Auto-detect**: the Engine menu does **not** list Turbo
     under "Unavailable for Auto-detect — change Language to use" (Turbo needs
     Apple Silicon). Under Language, Settings names `base-q5_1` (8 GB) or
     `small-q5_1` (16 GB+), notes limited accuracy and that more language
     support is coming soon, and offers the inline Download row if missing.
6. **Light and dark mode.** Check the Speech Model tab in both appearances: the
   Engine disabled section, Language status line (normal and problem tones), and
   inline `ModelDownloadRow` align cleanly without clipping or wrapping awkwardly.
