# Meetings in mixed languages (Hindi + English) — #47

## What was wrong

`config.language` defaults to `"en"`, and English picks Turbo (Parakeet) or an
English-only whisper model. Meetings ran on the dictation model, so Hindi went
through an English model: Turbo and Apple Speech write it romanised
("Pichli Mahineki Tulname Bikri…"), `small.en` invents English ("I will give
you a quick overview of the design"). Switching dictation to Auto-detect
fixed meetings but also moved dictation off Turbo.

## What changed

- **Meeting language is its own setting** (`meetingLanguage`): `same`
  (default: dictation's language and model, nothing changes), `auto`, or a
  code. Settings › Meetings › Meeting Language.
- **Per-passage detection.** Meetings are already transcribed passage by
  passage (cut at 0.6 s pauses, max 25 s, #31). With `auto` each passage is
  its own whisper job, so each gets its own language detection.
- **A meeting model of its own** when the dictation model can't decode the
  meeting's language (`MeetingModel.choose`, pure): what Automatic (or the
  chosen engine) picks for that language, or, if that's English-only or can't
  detect, whisper's Automatic multilingual pick among downloaded models.
  `MeetingModelRouter` loads it on the meeting's first passage and lets it go
  2 min after the last one (fixed; "Keep model loaded" stays the dictation
  model's). Not downloaded or failed to load → the dictation model (logged;
  a passage whose meeting model failed is redone on it, not lost).
- **Recovery** uses the language the meeting started with: it's in the
  spool's `meeting.json` (`language`; absent in older spools = dictation
  model, as they were recorded).
- **Output:** what the engine writes. Hindi in Devanagari, no romanising,
  no translation.
- **Settings warnings:** Speech Model › Language warns when the model is
  English-only and the language isn't English; Meeting Language says which
  model meetings use, or that it's missing (with a Download row).

### Two models: why this design

| Option | Cost | Verdict |
| --- | --- | --- |
| Switch the one engine to a multilingual model during meetings | dictation reloads after every meeting, readiness/menus flip to "Loading", dictation during the tail runs on the wrong model | no |
| Second engine, kept loaded like the dictation one | ~0.7 GB more for good (small-q5_1), worst on 8 GB Macs | no |
| **Second engine, loaded only for meetings, unloaded 2 min after** | ~0.7 GB more only while a meeting is transcribed; ~1 s load once per meeting (absorbed: the first passage waits, the backlog catches up) | **chosen** |

Dictation is refused while a meeting records, so the two models are only
busy together during the tail/recovery; each engine has its own queue, so a
dictation then no longer waits behind a passage.

## Reproduction (box 1)

Fixture: `scripts/make_mixed_language_fixture.sh` (macOS `say`, offline: the
Hindi voice Lekha (hi_IN) was already installed; English voices Rishi / Aman,
en_IN). Two sides: Me 24 s (2 Hindi, 2 English, 1 Hinglish sentence), Others
16 s (2 Hindi, 2 English). Reference text is in the script.
`GAP_SECONDS=0.3` makes a variant with pauses too short to cut at.

Runs: Apple M3 Max, 48 GB, macOS 26.7.2, **debug build** (WER is what
matters here; latencies aren't comparable to release numbers), one pass,
`Cado --bench --manifest .bench/fixtures/mixed-hi-en/manifest.tsv --runs 1`.
Each sentence is a `short` clip (= an ideal per-pause passage); the whole
conversation is one `long` 39 s job (= a passage that mixes languages).

| Engine · model · language | Hindi WER | English WER | Hinglish sentence | One 39 s job | Hindi comes out as | Load | Peak RAM¹ |
| --- | --- | --- | --- | --- | --- | --- | --- |
| whisper.cpp small-q5_1 · auto | 60% | 0% | 50% | 78% (English turned into Devanagari, parts dropped) | Devanagari, misspelt | 1.6 s | 705 MiB |
| whisper.cpp small-q5_1 · hi | 60% | 105% (English garbled into Devanagari) | 50% | 78% | Devanagari | 11.5 s² | 656 MiB |
| whisper.cpp base-q5_1 · auto | 107% | 0% | 88% | 62% | **Urdu script** | 0.7 s | 401 MiB |
| whisper.cpp small.en-q5_1 · en (8–15 GB default) | 100% | 0% | 100% | 59% (Hindi → invented English) | invented English / romanised | 1.4 s | 622 MiB |
| WhisperKit large-v3-turbo (626 MB) · auto | **13%** | 0% | 38% | **19%** | Devanagari, near perfect | 64.7 s (first-load Core ML compile) | 312 MiB¹ |
| Turbo (Parakeet v3) · en (app default) | 100%³ | 0% | 100%³ | 55% (some Hindi dropped) | romanised, readable | 18.7 s | 82 MiB¹ |
| Apple Speech · en | 100%³ | 3% | 62% | 56% | romanised | 0.2 s | 18 MiB¹ |
| Apple Speech · hi | — | — | — | — | not supported ("doesn't support Hindi on this Mac") | — | — |

¹ `phys_footprint`; Core ML / Neural Engine and OS-managed models are mostly
outside it, so WhisperKit, Turbo and Apple Speech read low.
² One noisy run (the same file loaded in 1.6 s the run before); not a property of `hi`.
³ WER is against the Devanagari reference, so readable romanised Hindi still
scores 100%.

Through the real meeting path (`Cado --meeting-test --me me.wav --them
them.wav --engine parakeet [--meeting-language auto]`, Turbo as the
dictation model):

| Meeting language | Model(s) | WER (both sides) | Time for the meeting |
| --- | --- | --- | --- |
| Same as dictation (English) | Turbo | 58% (Hindi romanised) | — |
| Auto-detect | Turbo + meeting model whisper small-q5_1 | **30%** (English exact, Hindi in Devanagari) | 3.7 s for 24 s per side |
| Auto-detect, 0.3 s gaps (no pause to cut at) | same | 91% | — |
| Auto-detect, 0.3 s gaps, max passage 8 s instead of 25 s (experiment, not shipped) | same | 78% | — |
| Auto-detect, 1.2 s gaps, max passage 8 s (experiment) | same | 30% (no change) | — |

### Findings

1. Per-passage detection is what makes mixed meetings work: the same model on
   the same audio goes from 78% (one job) to ~34% (one job per sentence),
   with English exact.
2. Forcing `hi` breaks the English parts (105%). Auto is the right default
   for mixed meetings, not "Hindi".
3. Model size matters more than anything else for Hindi: base writes Urdu
   script, small is readable but misspelt, large-v3-turbo is near perfect and
   even handles a 39 s mixed passage (19%).
4. Shorter passages help only a little when people don't pause (91% → 78%)
   and cost context; not shipped. A passage that switches language
   mid-sentence gets one language: documented limit.

## Remaining limits / follow-ups

- **Mid-sentence switches** (Hinglish) come out in one language/script.
  Only a bigger model really helps (WhisperKit large-v3-turbo: 38% on the
  Hinglish sentence vs 50% small).
- **Model quality on smaller Macs:** whisper's Automatic multilingual pick is
  base (< 8 GB: Urdu script for Hindi), small (8–15 GB), medium (16 GB+). Not
  measured here (over the ~500 MB download limit for this ticket):
  medium-q5_0 (539 MB) and large-v3-turbo-q5_0 (574 MB) in whisper.cpp —
  owner step below. A follow-up could let Settings pick the meeting model
  (e.g. WhisperKit large-v3-turbo, which is already the best measured).
  Today it's reachable only by choosing Engine › WhisperKit (which also
  changes dictation).
- **Script for Hindi** isn't forced: Whisper sometimes writes Hindi in Urdu
  script (base). An initial prompt in Devanagari could steer it; not done.
- **Translation to English** (Whisper's `translate`) could be a later option
  for meetings; not built.
- The meeting model's first load waits on the first passage (~1–2 s for
  whisper small; a Core ML model's first-ever load compiles for about a
  minute).

## Owner steps

- Measure the larger whisper.cpp multilingual models on this fixture:
  `bash scripts/download_model.sh medium-q5_0` (and/or `large-v3-turbo-q5_0`),
  then `.build/release/Cado --bench --manifest .bench/fixtures/mixed-hi-en/manifest.tsv
  --runs 1 --engine whisper --model ~/Library/Application\ Support/Cado/models/ggml-medium-q5_0.bin --language auto`.
- A real Hindi + English call (human voices, accents, overlap): see
  `plans/manual-checks/meeting-language-47.md`.
