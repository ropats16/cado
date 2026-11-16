# Manual checks: meeting tracer (#30, session half)

What the tests and the CLI can't reach: the real menu, the menu-bar
indicator, the system-audio prompt, a real call. Capture-only checks (which
apps are listed, tap rebuilds, output switches) are in
[system-audio-30.md](system-audio-30.md).

Already verified without a human:
- `MeetingReplayTests` replays two WAVs (Me, Them) through real captures,
  the session and a real `NotesLibrary`, and asserts the whole note file.
- `dist/Cado.app/Contents/MacOS/Cado --meeting-test --me me.wav --them them.wav`
  runs the same over the real engine (whisper small.en-q5_1 and Parakeet
  both produced the right four Me/Them turns from two `say`-generated WAVs).

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

Headphones for the first call (see "Speaker bleed" for without).

## Menu before a meeting

- [ ] Zoom only running (nothing else from the meeting-app list, incl. no
      Chrome/Safari/Edge/Brave/Arc/Firefox/Slack/Teams): the menu shows
      **Record Meeting (Zoom)**; one click starts.
- [ ] Zoom and Chrome running: **Record Meeting ▸** opens a submenu with
      Zoom and Google Chrome only (not Music etc.).
- [ ] No meeting app, Music playing: the submenu's first (grey) line is
      "No meeting app found — record another app:", then Music.
- [ ] Nothing at all: **Record Meeting** greyed out, "No meeting app is
      running" under it.
- [ ] (If a macOS < 14.2 Mac is around) greyed out with "Recording meetings
      needs macOS 14.2 or later."

## A real call (Zoom or Meet in a browser)

Join a call with a second device (phone) as the other participant.

1. [ ] Click **Record Meeting (Zoom)** (or pick the browser). First time:
       macOS asks to let Cado record system audio, with the usage string
       ("…during a meeting you start…"). **Allow.** (Do not reset this
       permission from a script: owner only.)
2. [ ] Indicator, for the whole meeting:
   - menu-bar avocado has a record dot and the elapsed time ("0:42")
     ticking every second, also with the menu closed;
   - menu: **Stop Recording — 0:42** (ticks while the menu is open) and
     "Recording Zoom and your microphone";
   - the mascot stays on screen (resting pose) until you stop, also with
     "Always show Cado" off;
   - macOS's own mic and system-audio recording indicators are on.
3. [ ] Talk in turns with the phone for ~2 minutes.
4. [ ] Press the dictation hotkey (hold and toggle) and click the mascot:
       nothing records; a "Meeting recording" notice says dictation is off
       until you stop (at most one per 5 s).
5. [ ] **Stop Recording**: the menu shows "Finishing Meeting…", then
       "Transcribing Meeting… n of m"; the mascot shows thinking; the
       menu-bar dot and time go away; the mic/system-audio indicators go off
       within a second.
6. [ ] A "Meeting note saved" notification names the note.
7. [ ] **Library…**: the note is listed (kind meeting, today, duration), and
       opening it shows "Recorded from Zoom (Them) and your microphone (Me)."
       then **Me:** / **Them:** paragraphs in the order things were said.
8. [ ] The file in the notes folder has `title: "Meeting with Zoom — <date
       time>"`, `date:` = start, `kind: "meeting"`, `duration:` in seconds.
9. [ ] Dictation works again right after stopping (also while the meeting is
       still transcribing: it waits for at most one chunk).

## Failure paths

- [ ] **Permission off:** turn Cado off in System Settings › Privacy &
      Security › Screen & System Audio Recording (owner, by hand), relaunch,
      record a call: the note has Me only and a quoted line "No sound was
      captured from Zoom, so Them may be missing. If others were talking,
      allow Cado…"; the saved notice says "no sound came from Zoom".
- [ ] **Nothing said:** start and stop at once in silence: no note; a
      "Nothing recorded" notice.
- [ ] **Quit mid-meeting:** Quit Cado while recording: it quits within a
      couple of seconds; a note says "Cado quit before this meeting was fully
      transcribed." and where the audio is kept
      (`~/Library/Application Support/Cado/Meeting Audio/<title>/Me.wav`,
      `Them.wav`); both WAVs play.
- [ ] **No model:** move the model away, record a short meeting: a note is
      still written, with "n of n passages couldn't be transcribed: …" and
      the kept-audio path.
- [ ] **Them dies:** hard to force by hand (needs the tap to fail 4 times
      in 2 s); covered by tests. If seen: the menu says "Zoom's audio
      stopped — recording your microphone only" and the note says when.

## Speaker bleed (#36, not solved here)

- [ ] Same call on laptop speakers, no headphones: expect the other side's
      words under **Me** as well as **Them** (the mic hears the speakers).
      Note how bad it is for #36; nothing in #30 makes it worse (Them is
      only the app's audio, the mic is unprocessed as before).

## Limits to know

- One meeting holds both streams in memory (~230 MB an hour each) and stops
  itself at 2 hours with a notice; the note is still written. Long meetings
  and crash safety: #31.
- Transcription runs after stop, one chunk at a time on the shared engine;
  a 1-hour meeting takes a few minutes on Apple silicon (not measured).
- Turn timing: each stream is placed by when it started; tap rebuilds
  (a browser spawning a helper, output switch) drop < 1 s and shift that
  side's later turns slightly earlier.
