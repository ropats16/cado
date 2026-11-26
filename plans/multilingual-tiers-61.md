# Multilingual Whisper model tiers — #61

## What changed

- **Tier by chip and RAM** (`MultilingualTier`): Full = Apple Silicon 16 GB or
  more; Basic = Apple Silicon 8–15 GB or Intel 16 GB or more; Limited = the rest.
- **whisper.cpp's Automatic pick for Auto-detect and non-English**
  (`ModelCatalog.recommended`): Full → `large-v3-turbo-q5_0` (benchmark below),
  Basic → `small-q5_1`, Limited → as before. English picks are unchanged.
- **Not downloaded yet:** the largest installed multilingual model no bigger
  than the pick, or than the pre-#61 pick if that was bigger (so a 32 GB Mac
  with `medium-q8_0` keeps it rather than dropping to `small`).
- **English-only models don't serve other languages:** a hand-set `modelPath`
  or named `.en` model gives way to the Automatic pick for Auto-detect and
  non-English once any multilingual catalog model is installed. With none
  installed it stays, as before.
- Meetings inherit the pick through `MeetingModel.choose`. Known edge: dictation
  on Auto-detect with a hand-set `.en` model and Meeting Language = English
  loads that `.en` model for meetings next to dictation's multilingual one.
- Settings copy per tier, inline multilingual model download, and the #55
  picker/recovery fix are implemented in part 2 (see
  `plans/manual-checks/language-routing-settings-61.md`).

## Benchmark

Machine: Apple M3 Max (`Mac15,9`, 12P + 4E), 48 GB RAM, macOS 26.7.2 (25G332),
**release build** (`swift build -c release`), thermal nominal.

Fixture: `scripts/make_mixed_language_fixture.sh` (macOS `say`, voices Lekha
`hi_IN`, Rishi / Aman `en_IN`), 9 single-sentence `short` clips (4 Hindi,
4 English, 1 Hinglish) and 1 `long` 39 s clip combining both sides.

Commands:

```sh
swift build -c release
bash scripts/make_mixed_language_fixture.sh
for id in small-q5_1 medium-q5_0 large-v3-turbo-q5_0; do
  CADO_APP_SUPPORT="$PWD/.bench" make model MODEL="$id"
  .build/release/Cado --bench --engine whisper \
    --model ".bench/models/ggml-$id.bin" --language auto \
    --manifest .bench/fixtures/mixed-hi-en/manifest.tsv --runs 1
done
```

### Results

Columns match the table in `plans/meeting-languages-47.md`. Hindi WER is across
the 4 Hindi clips (45 words); English WER is across the 4 English clips
(38 words); Hinglish is `s-05-me-mix` (8 words); One 39 s job is `conversation`
(91 words). Peak RAM is `phys_footprint` (`peak`, with `loaded` in parentheses).

| Model · language | File | Hindi WER | English WER | Hinglish sentence | One 39 s job | Hindi comes out as | Load | Peak RAM (loaded) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `small-q5_1` · auto (control) | 190 MB | 60% (27/45) | 0% (0/38) | 50% (4/8) | 78% (71/91, 3.1 s) | Devanagari, misspelt | 3.0 s | 860 MiB (705 MiB) |
| `medium-q5_0` · auto | 539 MB | 42% (19/45) | 0% (0/38) | 63% (5/8) | 65% (59/91, 9.0 s) | Devanagari, readable but misspelt | 1.1 s | 1299 MiB (1239 MiB) |
| **`large-v3-turbo-q5_0` · auto** | 574 MB | **13%** (6/45) | **0%** (0/38) | **38%** (3/8) | **9%** (8/91, 1.4 s) | **Devanagari, near perfect** | 1.7 s | **1179 MiB** (1134 MiB) |

`small-q5_1` is the control and matches the #47 table exactly on accuracy
(Hindi 60%, English 0%, Hinglish 50%, 39 s job 78%; loaded footprint 705 MiB).

## Decision

Rule: between `large-v3-turbo-q5_0` and `medium-q5_0`, pick the lower Hindi WER;
if within 5 percentage points, pick the lower peak RAM.

**Full-tier pick: `large-v3-turbo-q5_0`.**

- 29 percentage points lower Hindi WER than `medium-q5_0` (13% vs 42%), and on
  par with WhisperKit `large-v3-turbo` in #47 (13%) without the ~1 min Core ML
  compile on first load.
- Lower peak RAM than `medium-q5_0` (1179 MiB vs 1299 MiB) and 6x faster on the
  39 s clip (1.4 s vs 9.0 s) because turbo uses a 4-layer decoder instead of 24.
- Keeps both Devanagari and Latin scripts intact inside the 39 s mixed clip
  (9% WER vs 65% for `medium-q5_0`).

### Tier mapping

| Tier | Hardware | Non-English / Auto-detect pick |
| --- | --- | --- |
| Full | Apple Silicon, ≥ 16 GB | `large-v3-turbo-q5_0` (574 MB) |
| Basic | Apple Silicon 8–15 GB; Intel ≥ 16 GB | `small-q5_1` (190 MB) |
| Limited | Apple Silicon < 8 GB; Intel < 16 GB | unchanged (`base-q5_1` / `tiny-q5_1`) |

English picks are unchanged on every Mac.

## Not measured / extrapolated

- **8 GB Apple Silicon Macs:** not tested on hardware. `large-v3-turbo-q5_0`
  peaked at 1179 MiB here (plus macOS + dictation/meeting headroom), so 8–15 GB
  Macs stay on Basic (`small-q5_1`, 860 MiB peak).
- **16 GB Apple Silicon Macs:** measured on 48 GB M3 Max, not a 16 GB M1/M2;
  1.2 GB peak is assumed comfortable on 16 GB.
- **Intel Macs (CPU-only):** not tested; latency and memory behaviour on x86_64
  are extrapolated from #15 / existing tiers.
- **Real human speech:** fixture uses macOS `say` voices (clean, synthetic,
  no accents, crosstalk, or background noise).
- **Languages other than Hindi and English:** only Hindi + English were measured.
- **Long sessions:** short 1-run pass only (no 60-minute or thermal-soak runs).
