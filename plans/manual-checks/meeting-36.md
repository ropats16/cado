# Manual checks: speaker bleed on a MacBook (#36)

What the tests can't reach: a real room, real laptop speakers, the built-in
mic, a real call. Background and measured results:
[../speaker-bleed-36.md](../speaker-bleed-36.md).

Already verified without a human:
- `SpeakerBleedFilterTests`: the dedup rules (repeats dropped; backchannels,
  Me over Others and later repeats kept; old journals without end times).
- `MeetingBleedReplayTests`: a speaker-bleed fixture (Others mixed into Me at
  −12 dB, 40 ms late) through real captures, chunking, spool and notes:
  no Others lines under Me; the headphones note is the same; a crashed
  meeting recovers to the same note.
- `scripts/bleed_bench.sh` on real speech (whisper small.en/tiny.en,
  Parakeet): Me insertions from bleed down ~95%; headphones notes
  byte-identical with and without the filter.

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

Owner steps (permissions, not done by agents): Cado has Microphone and
System Audio Recording allowed (as for any meeting, #30).

## 1. Built-in mic + built-in speakers

1. [ ] Unplug headphones; Sound settings: output **MacBook Pro Speakers**,
       input **MacBook Pro Microphone**; volume ~60%.
2. [ ] Start a call with a second device (phone into a Meet/Zoom room), or
       play a talk with clear speech in the meeting app or a browser. Record
       Meeting for that app.
3. [ ] Over ~5 minutes: let the other side talk for a while; answer now and
       then; say "yeah" / "mm-hmm" while they talk; once, talk over them with
       a sentence of your own; once, repeat 3+ words they just said ("next
       quarter?").
4. [ ] Stop. In the note:
   - [ ] Others' sentences are **not** repeated under Me (a garbled
         fragment of a few words may slip through: note how many).
   - [ ] Your own sentences, the "yeah"s and the sentence over them are all
         under Me.
   - [ ] The echo question may be missing (known limit): note whether it is.
5. [ ] Same again at full volume. Louder bleed: is it still removed?

## 2. Headphones unchanged

1. [ ] With wired headphones or AirPods, record the same kind of call.
2. [ ] The note's Me lines are what you said, nothing missing compared with
       before this change (Cado 0.3.0); Others unchanged.

## 3. Optional: does Apple's voice processing help? (`--echo-test`)

Answers the open question in the plan: does macOS echo cancellation remove
audio *another app* plays? Needs the Microphone permission for Terminal
(macOS asks on first run: owner step). It plays sound out loud; stay quiet
while it runs.

```sh
make build
.build/release/Cado --echo-test --wav .bench/fixtures/short/jfk.wav --out /tmp/cado-echo
```

1. [ ] It prints a level for **Plain** and for **Voice processing**, then
       "Voice processing heard N dB less of the speakers." Write down N:
   - ≥ 15–20 dB: worth a follow-up (a meetings-only option, off by default).
   - < 6 dB: it doesn't cancel other apps' audio; the text dedup stays the
     whole fix.
2. [ ] While it ran, did the playback get quieter (ducking) or did AirPods
       (if connected) switch to call quality?
3. [ ] Optional: see what the note makes of each recording:
       `.build/release/Cado --meeting-test --me /tmp/cado-echo/mic-plain.wav --them .bench/fixtures/short/jfk.wav`.
       Expected: no Me lines (all bleed was removed).

Record the results (Mac model, macOS version, N, ducking yes/no) in
`plans/speaker-bleed-36.md`.
