# Speaker bleed into "Me" (#36): what was tried, what ships

On laptop speakers the mic hears the call too, so what Others say was
transcribed twice: once from the app's audio, once (quieter, a little late)
as Me. Two ways to remove it were evaluated:

- **(a) Apple voice processing (echo cancellation) on the mic.**
- **(b) Text dedup:** drop Me pieces that repeat what Others said at the
  same moment.

**Decision: (b) ships, on in every meeting that shows bleed. (a) does not ship.** The app's mic path
doesn't change, for meetings or dictation. `Cado --echo-test` lets the owner
measure (a) on a real Mac (see [manual-checks/meeting-36.md](manual-checks/meeting-36.md)).
If it turns out to work there, it can come later as a meetings-only option
that's off by default, with the dedup kept as the fallback.

## (b) Text dedup: `SpeakerBleedFilter`

`Sources/Cado/Meeting/SpeakerBleedFilter.swift`, pure and deterministic,
applied in `MeetingTranscript.turns`. Every note goes through it the same
way: a live meeting, one written while quitting, and one rebuilt from the
spool journal after a crash (`RecoveryPlan` → `MeetingSession.complete` →
`turns`). (A note written while quitting only has the pieces so far, so it
judges the meeting on those.)

- Only Me pieces are touched: Others is the app's own audio and never hears
  the mic.
- Words are normalized as the bench does (`TranscriptNormalizer`); longer
  words one letter apart still match ("number"/"numbers"), since bleed is
  quiet and misheard. A local alignment (Smith-Waterman: match +2,
  mismatch/gap −1) finds the run of shared words.
- **Timing, Others first.** Each word's time is estimated by spreading a
  piece's words evenly over its start…end (end estimated at 2.5 words/s for
  old journals without one). A Me word only matches an Others word said
  0–2 s before it (`slack`), with 1 s of give the other way for the
  estimate's error (`wordSkew`). So only the Others words around the Me
  piece count, however long the Others piece (Parakeet's fallback gives one
  segment per chunk of up to 25 s). Where the run starts, Me may be at most
  0.3 s ahead of Others (`skew`): bleed is never early. A reply, Others
  repeating Me, and Me's own voice coming back from the far end 0.4 s or
  more later are all rejected here.
- **A repeat**, run of 3+ matched words: it covers ≥ 90% of the Me piece
  (`repeatShare`), or it has 5+ matched words (`minSpanWords`) and covers
  ≥ 80% of the Others sentence(s) it matched (`sentenceShare`, sentences
  split at . ? ! and piece ends), or it has 5+ matched words and starts
  within 0.75 s of Others' (`together`: nobody repeats five words in step
  with the speaker, speakers do). Only the run is cut; every other word of
  the piece stays, tidied at the cut ("March—great," → "great,"; no dangling
  comma). Anything else is kept whole: "I think we should wait." after "So
  I think we should ship it on Friday." covers 80% of the Me piece and 44%
  of Others' sentence.
- **Short pieces** (1–2 words: "Yeah.", "Bye."): a repeat only if an Others
  piece starts with exactly those words 0–0.75 s before (to 0.3 s after) the
  Me piece starts, or ends with them as the Me piece ends (piece edges are
  where word times are real: "Great." / "Got it." split off by the engine).
  A backchannel over the middle of Others' sentence stays.
- **Only in a meeting that bleeds.** Nothing is removed unless at least 2 Me
  pieces are repeats with 5+ matched words (`evidencePieces`). Bench: every
  bleed run has 3–7 such pieces, every headphones run 0. With headphones the
  filter doesn't act at all, so two people saying "Thank you very much." or
  "Bye." together both stay.
- Cost: once per note. A 2-hour meeting of 25 s pieces (the slowest case)
  takes ~0.7 s in a debug build (`testATwoHourMeetingIsFilteredQuickly`);
  ordinary pieces less.

Known limits:
- On speakers, Me saying Others' words with them or straight after (both
  saying "Thank you very much.", an echo question repeating 3+ of their
  words in step, a whole short sentence of theirs repeated within ~2 s) is
  left out of Me. In c1, "Thank you very much." said together was dropped
  in 4 of 6 bleed runs.
- Me's own voice coming back from the far end (their echo cancelling
  failing) within 0.3 s counts as bleed: removed from Me, kept under
  Others. From 0.4 s on it stays under Me (tests at 0.4–1 s).
- Bleed the engine garbles past recognition still gets through: tiny.en's
  "May call my thousand, because he was in the night" for "Mainhall liked
  Alexander because he was an engineer"; 1–2 word bits that aren't an
  exact repeat ("No land inside." for "no land in sight"); and words left
  around a cut ("May call … a man he knew").
- Partial repeats under the thresholds stay: "somebody will say that." for
  "somebody will say so." (3 of 4 words).
- A meeting with fewer than two long Others sentences bleeding (a very
  short call) isn't filtered.
- A Me sentence spoken over Others can lose words to the engine (the
  engine's doing, not the filter's: it happens without the filter too).

### Tests

- `SpeakerBleedFilterTests` (29): repeats removed on speakers (exact,
  misheard, split across pieces, no end times, short twins, short bits at a
  piece's edge); kept: later repeats, Me over Others, backchannels, words
  around a repeat. Conversational, each failing before this fix: replies
  after Others ("Let's do Tuesday at three." / "Tuesday at three works.",
  "Can you send me the deck?" / "Send you the deck, sure."), Others repeating
  Me, Me's voice back from the far end 0.4–1 s later, replies reusing 3–6 of
  Others' words, a long Others piece whose first words were 20 s earlier,
  headphones "Thank you very much." / "Bye." / "Yeah." together, one repeat
  isn't enough evidence, a cut leaves no glued words. Plus the known limit
  on speakers, a 2-hour meeting, journal end times.
- `SpeakerBleedBenchTests` (6), on real engine output
  (`SpeakerBleedBenchPieces`: the pieces of all 27 bench runs below): with
  headphones nothing changes; every bleed run shows bleed; f1/f2 bleed down
  751 → ≤ 57 words; c1 bleed down 332 → ≤ 10; every c1 Me line kept on
  every engine and mic; what's cut from Me starts and ends on words Others
  said.
- `MeetingBleedReplayTests` (3): the speaker-bleed fixture through real
  captures, chunking, spool and notes library. Others' tones are mixed into
  Me at −12 dB, 40 ms late. The fake engine hears each tone as its sentence,
  timed, two at once when they overlap, and mishears quiet ones. Me's lines
  include "Yeah." over Others, a sentence over Others, a reply reusing six
  of Others' words, and "Bye everyone." with Others. Checked:
  - with bleed: no Others line under Me, every Me line kept but "Bye
    everyone." (the limit);
  - headphones: every Me line kept, "Bye everyone." too;
  - a crash mid-meeting, recovered: the same note as with bleed.

## Measured: real speech, real engines (short runs)

Fixtures: `python3 scripts/make_bleed_fixtures.py` (deterministic). Two
~58 s meetings from the bench's LibriSpeech clips, f1 and f2 (the sides
swapped), four turns per side, one Me turn starting 1.5 s before Others
finishes. These are unrelated read sentences, so they can't show what the
filter does to a real conversation; c1 does: a 37 s conversation spoken by
macOS `say` (Samantha as Me, Daniel as Others) with replies reusing Others'
words ("I think we should wait.", "Then the hiring plan for next quarter can
wait."), Others repeating Me ("Send you the deck, sure.", "Move the launch to
March, got it."), "Yeah." over Others, and both saying "Thank you very much."
0.2 s apart. Me is clean (headphones) or has Others mixed in at −12 dB
(`bleed-0.25`) or −6 dB (`bleed-0.5`), 40 ms late, with room reflections at
75/120 ms, low-passed at ~3 kHz, over a −55 dBFS noise floor. Run:
`scripts/bleed_bench.sh` → `Cado --meeting-test … --me-reference …`, scored
with the bench's `WordErrorRate`. Apple M3 Max, release build, 2026-11-17;
each meeting ~1 s to transcribe.

"Without filter": f1/f2 from the first round (the same commit built with the
filter call taken out of `MeetingTranscript.turns`; the fixtures are
byte-identical); c1 from the same runs' pieces scored without the filter
(`SpeakerBleedBenchPieces`). "Old filter": the first round's always-on
filter. "Now": this filter.

Me WER (insertions are bleed that reached the note under Me):

| engine | meeting | mic | without filter | old filter | now |
|---|---|---|---|---|---|
| whisper small.en-q5_1 | f1 | headphones | 10.2% (I 1) | 10.2% (I 1) | 10.2% (I 1) |
| | f1 | bleed −12 dB | 171.4% (I 80) | 14.3% (I 3) | 22.4% (I 7) |
| | f1 | bleed −6 dB | 169.4% (I 79) | 10.2% (I 1) | 12.2% (I 2) |
| | f2 | headphones | 0.0% | 0.0% | 0.0% |
| | f2 | bleed −12 dB | 62.8% (I 49) | 0.0% (I 0) | 2.6% (I 2) |
| | f2 | bleed −6 dB | 66.7% (I 52) | 6.4% (I 5) | 6.4% (I 5) |
| | c1 | headphones | 2.6% | | 2.6% |
| | c1 | bleed −12 dB | 155.3% (I 57) | | 23.7% (I 3, D 4) |
| | c1 | bleed −6 dB | 144.7% (I 54) | | 13.2% (I 0, D 5) |
| whisper tiny.en | f1 | headphones | 10.2% (I 2) | 10.2% (I 2) | 10.2% (I 2) |
| | f1 | bleed −12 dB | 175.5% (I 79) | 22.4% (I 4) | 38.8% (I 12) |
| | f1 | bleed −6 dB | 175.5% (I 79) | 24.5% (I 3) | 34.7% (I 8) |
| | f2 | headphones | 1.3% | 1.3% | 1.3% |
| | f2 | bleed −12 dB | 66.7% (I 51) | 17.9% (I 13) | 17.9% (I 13) |
| | f2 | bleed −6 dB | 65.4% (I 50) | 9.0% (I 6) | 9.0% (I 6) |
| | c1 | headphones | 2.6% | | 2.6% |
| | c1 | bleed −12 dB | 152.6% (I 57) | | 13.2% (I 4) |
| | c1 | bleed −6 dB | 150.0% (I 56) | | 10.5% (I 3) |
| parakeet (installed) | f1 | headphones | 0.0% | 0.0% | 0.0% |
| | f1 | bleed −12 dB | 153.1% (I 69) | 20.4% (I 2) | 16.3% (I 0) |
| | f1 | bleed −6 dB | 151.0% (I 71) | 10.2% (I 0) | 10.2% (I 0) |
| | f2 | headphones | 1.3% (I 1) | 1.3% (I 1) | 1.3% (I 1) |
| | f2 | bleed −12 dB | 64.1% (I 50) | 6.4% (I 5) | 6.4% (I 5) |
| | f2 | bleed −6 dB | 64.1% (I 50) | 6.4% (I 5) | 6.4% (I 5) |
| | c1 | headphones | 0.0% | | 0.0% |
| | c1 | bleed −12 dB | 144.7% (I 54) | | 13.2% (I 0, D 5) |
| | c1 | bleed −6 dB | 144.7% (I 54) | | 13.2% (I 0, D 5) |

- **Bleed removed:** f1/f2: 694 of 751 bleed words (92%; Me insertions in
  the 12 bleed runs, minus each meeting's headphones insertions); the old
  always-on filter removed 712 (95%). The difference is the price of not
  deleting real speech: partial repeats below the thresholds, and words
  left around a cut, are now kept. 0–13 left per meeting. c1: 322 of 332
  (97%), 0–4 left per meeting. Others WER is unchanged in every run (Others
  is never touched).
- **Headphones unaffected:** all 9 clean runs show no bleed (0 evidence
  pieces), so the filter doesn't act: the note is the same as without it.
- **Genuine Me speech:** every c1 Me line (replies reusing Others' words,
  lines Others repeated) stays on every engine and mic. c1's deletions (D 4–5)
  are "Thank you very much." said with Others (the known limit; dropped in 4
  of 6 bleed runs) and "Yeah." over Others, which small.en and Parakeet
  lost under the bleed before the filter (no such piece). In f1/f2 every
  stretch cut from Me starts and ends on words Others said
  (`testOnlyOthersWordsAreTakenFromMe`); matched-word drops of 2 in two runs
  are the WER alignment counting bleed words as Me words the engine lost
  in the overlap.
- **Thresholds from this data:** `skew` 0.3 s: removal was the same from
  0.3 to 0.5 s, so the smallest (most protection for replies and far-end
  echo) was taken. `wordSkew` 1 s: the even-spread estimate was off by up to
  ~0.5 s ("Americans" in Parakeet f1). `together` 0.75 s: the bench's long partial
  bleed runs started −0.1 to +0.5 s after Others'; replies in the tests
  1.4 s or more. `evidencePieces`
  2: bleed runs have 3–7, headphones 0.
- Dictation never goes through the filter (meeting notes only), so the
  dictation bench is unaffected by construction; it wasn't re-run.

Extrapolation: three ~1-minute meetings per setting. The filter is per
piece (plus one per-meeting yes/no), so longer meetings should behave the
same per minute, and the yes/no gets surer with length. Real rooms (speaker
distortion, louder bleed, more reverb, a Me voice farther from the mic) and
real conversation are the manual check.

## Acceptance (issue #36)

- [x] Meeting replay test with a speaker-bleed fixture produces no
  duplicated Others lines under Me (`MeetingBleedReplayTests`).
- [x] Approach chosen with measured results: (b) text dedup, measured
  above. **PENDING OWNER** for (a): the echo-cancellation measurement on a
  real Mac (`Cado --echo-test`, [manual check §3](manual-checks/meeting-36.md)).
- [x] No degradation of Me with headphones: 9 of 9 headphones runs
  untouched.
- [ ] **PENDING OWNER:** works on a MacBook's built-in mic + speakers
  ([manual check §1–2](manual-checks/meeting-36.md)).

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
- On speakers, saying the same words as Others at the same moment ("thank
  you") is left out of Me: acceptable?
