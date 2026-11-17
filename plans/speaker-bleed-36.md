# Speaker bleed into "Me" (#36): what was tried, what ships

On laptop speakers the mic hears the call too, so what Others say was
transcribed twice: once from the app's audio, once (quieter, a little late)
as Me. Two ways to remove it were evaluated:

- **(a) Apple voice processing (echo cancellation) on the mic.**
- **(b) Text dedup:** drop Me pieces that repeat what Others said at the
  same moment.

**Decision: (b) ships, always on. (a) does not ship.** The app's mic path
doesn't change, for meetings or dictation. `Cado --echo-test` lets the owner
measure (a) on a real Mac (see [manual-checks/meeting-36.md](manual-checks/meeting-36.md)).
If it turns out to work there, it can come later as a meetings-only option
that's off by default, with the dedup kept as the fallback.

## (b) Text dedup: `SpeakerBleedFilter`

`Sources/Cado/Meeting/SpeakerBleedFilter.swift`, pure, applied in
`MeetingTranscript.turns`. Every note goes through it: a live meeting, one
written while quitting, and one rebuilt from the spool journal after a crash
(`RecoveryPlan` → `MeetingSession.complete` → `turns`).

- Only Me pieces are touched: Others is the app's own audio and never hears
  the mic.
- A Me piece is compared with the Others words around it in time (±2 s
  around its start…end): words normalized as the bench does
  (`TranscriptNormalizer`), and longer words one letter apart still match
  ("number"/"numbers"), since bleed is quiet and misheard.
- The comparison is a local alignment (Smith-Waterman: match +2,
  mismatch/gap −1), so the shared words must run together, as a repeat
  does. A few common words scattered over a long Others turn don't count.
- At least 3 aligned words, with fewer than 3 of the piece's own words
  outside the run: the piece is dropped. A run of 5 or more inside a piece
  with 3 or more other words is cut out and the rest stays (Me talking right
  after, or over, Others in one segment).
- Pieces of 1–2 words ("Yeah.", "Mm-hmm.") are dropped only if Others said
  exactly that, starting within 0.75 s. A backchannel over someone else's
  sentence stays.
- End times: pieces and journal segments now keep each segment's end time
  (`SpoolSegment.end`, optional). Journals written before this have none;
  those ends are estimated from length (2.5 words/s).

Known limits:
- Me repeating 3+ of Others' words within ~2 s (an echo question: "next
  quarter?") is dropped as bleed.
- Bleed the engine garbles past recognition still gets through: tiny.en's
  "May call my thousand, because he was in the night" for "Mainhall liked
  Alexander because he was an engineer". So do 1–2 word bits that aren't an
  exact repeat ("No land inside." for "no land in sight").
- Bleed of a 1–2 word Others line that starts more than 0.75 s off its twin
  stays.
- A Me sentence spoken over Others can lose words to the engine (the
  engine's doing, not the filter's: it happens without the filter too).

### Tests

- `SpeakerBleedFilterTests` (17): exact and misheard repeats, a repeat split
  across Others pieces, the same words later (kept), Me speaking over Others
  with other words (kept), backchannels (kept), short exact repeats
  (dropped) vs at another moment (kept), Me words around a long repeat
  (kept), no end times (old journals), journal round-trip with end times,
  `RecoveryPlan` pieces get their ends.
- `MeetingBleedReplayTests` (3): the speaker-bleed fixture through real
  captures, chunking, spool and notes library. Others' tones are mixed into
  Me at −12 dB, 40 ms late. The fake engine hears each tone as its sentence,
  timed, two at once when they overlap, and mishears quiet ones. Checked:
  - with bleed: no Others line under Me, every Me line kept (incl. "Yeah."
    over Others and a sentence spoken over Others);
  - headphones: the same note;
  - a crash mid-meeting, recovered: the same note.

  Without the filter the replay fails: "Me: The quarterly numbers look
  pretty good Yeah." and so on.

## Measured: real speech, real engines (short runs)

Fixtures: `python3 scripts/make_bleed_fixtures.py` (from the bench's short
clips; deterministic). Two ~58 s meetings, f1 and f2 (the sides swapped),
each with four turns per side and one Me turn starting 1.5 s before Others
finishes. Me is clean (headphones) or has Others mixed in at −12 dB
(`bleed-0.25`) or −6 dB (`bleed-0.5`). The mix is 40 ms late, with room
reflections at 75/120 ms, low-passed at ~3 kHz, over a −55 dBFS noise floor.
Run: `scripts/bleed_bench.sh` → `Cado --meeting-test … --me-reference …`,
scored with the bench's `WordErrorRate`. "Without filter" is the same commit
built with the filter call taken out of `MeetingTranscript.turns`. Apple
M3 Max, release build, 2026-11-17; each meeting ~1 s to transcribe.

Me WER (insertions are bleed that reached the note under Me):

| engine | meeting | mic | without filter | with filter |
|---|---|---|---|---|
| whisper small.en-q5_1 | f1 | headphones | 10.2% (I 1) | 10.2% (I 1) |
| | f1 | bleed −12 dB | 171.4% (I 80) | 14.3% (I 3) |
| | f1 | bleed −6 dB | 169.4% (I 79) | 10.2% (I 1) |
| | f2 | headphones | 0.0% | 0.0% |
| | f2 | bleed −12 dB | 62.8% (I 49) | 0.0% (I 0) |
| | f2 | bleed −6 dB | 66.7% (I 52) | 6.4% (I 5) |
| whisper tiny.en | f1 | headphones | 10.2% (I 2) | 10.2% (I 2) |
| | f1 | bleed −12 dB | 175.5% (I 79) | 22.4% (I 4) |
| | f1 | bleed −6 dB | 175.5% (I 79) | 24.5% (I 3) |
| | f2 | headphones | 1.3% | 1.3% |
| | f2 | bleed −12 dB | 66.7% (I 51) | 17.9% (I 13) |
| | f2 | bleed −6 dB | 65.4% (I 50) | 9.0% (I 6) |
| parakeet (installed) | f1 | headphones | 0.0% | 0.0% |
| | f1 | bleed −12 dB | 153.1% (I 69) | 20.4% (I 2) |
| | f1 | bleed −6 dB | 151.0% (I 71) | 10.2% (I 0) |
| | f2 | headphones | 1.3% (I 1) | 1.3% (I 1) |
| | f2 | bleed −12 dB | 64.1% (I 50) | 6.4% (I 5) |
| | f2 | bleed −6 dB | 64.1% (I 50) | 6.4% (I 5) |

- **Bleed removed:** 712 of 751 bleed words gone (95%; Me insertions in
  the 12 bleed runs, minus each meeting's headphones insertions). 0–13 are
  left per meeting, all garbled fragments (see Known limits). Others WER is
  unchanged in every run.
- **Headphones unaffected:** in all 6 clean runs the note is byte-for-byte
  the same with and without the filter, so Me WER is too.
- **No genuine Me speech removed:** in three bleed runs, matched Me words
  ("hits") drop by 2 with the filter. A diff of those notes shows only
  bleed removed. Without the filter, the WER alignment counted some bleed
  words as matches for Me words the engine had lost in the overlap ("he
  began a confused complaint", missing either way).
- Dictation never goes through the filter (meeting notes only), so the
  dictation bench is unaffected by construction; it wasn't re-run.

Extrapolation: two 1-minute meetings per setting. The filter is per
piece, so longer meetings should behave the same per minute. Real rooms
(speaker distortion, louder bleed, more reverb, a Me voice farther from the
mic) are the manual check.

## (a) Apple voice processing: evaluated, not shipped

What it would take: set the mic unit to `kAudioUnitSubType_VoiceProcessingIO`
(or use `AVAudioInputNode.setVoiceProcessingEnabled(true)`) for meetings only.
Why not now:

1. **No way to give it the tap as reference.** The issue asked to cancel
   using the system-audio tap as reference. Apple's voice processing takes
   no outside reference signal. It cancels what plays through its own output
   (Cado plays nothing in a meeting); whether it also cancels other apps'
   audio on the default output isn't documented. Unknown until
   `--echo-test` runs on a real Mac.
2. **It changes the capture path, and the output.** `MicSource` uses an
   input-only AUHAL on purpose: `AVAudioEngine`'s input opens the default
   output too, which on AirPods meant a switch to call quality (a pop, worse
   sound) even with another mic selected. Voice processing runs input and
   output together, the same problem, mid-call.
3. **It ducks other audio** (the call itself!) unless set to the minimum
   (macOS 14's other-audio ducking setting), and it adds AGC and noise
   suppression that change how Me sounds to the engine. Measured effect on
   WER: unknown.
4. **The meeting app already runs its own voice processing on the same mic**.
   How two clients interact isn't documented.
5. **It can't be checked here:** it needs the mic permission and real
   speakers, a human's job (no permission grants by agents). It can't be
   proven safe by construction, so it isn't shipped, not even behind a
   setting.

Dictation shares `MicSource`, so a meetings-only switch would need a second
mic source; that's the follow-up if `--echo-test` shows ≥ 15–20 dB less
bleed with no ducking and no AirPods switch.

Other options seen, not taken: a reference-based echo canceller (WebRTC
AEC3/speexdsp) fed with the tap. It could work offline on the spool and
would really use the tap as reference, but it brings a dependency and
clock-drift/double-talk tuning. The dedup already removes ~95% of bleed
words.

## Unresolved

- Run `--echo-test` on the MacBook (owner): if voice processing cuts bleed
  by ≥ 15–20 dB with no ducking, revisit (a) as an option?
- The echo-question limit ("next quarter?" within 2 s): acceptable?
