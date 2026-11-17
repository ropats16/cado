# Manual checks: chunked, crash-safe meetings (#31)

What the tests can't reach: a real call of real length, a real crash, a
real full disk, how fast this Mac's engine keeps up. The rest of the
meeting flow is in [meeting-30.md](meeting-30.md).

Already verified without a human:
- `MeetingSessionTests` (fakes): chunks go to the engine while recording,
  one at a time, in order; after a simulated 60-minute meeting where the
  engine keeps up, only the open tail (≤ 2 chunks per side) is left at stop,
  the same as after 1 minute; a slow engine's backlog finishes after stop;
  the journal never settles past an unfinished chunk; retention; recovery
  rules (oldest first, no speech, engine failing, tried twice, unreadable,
  a meeting started meanwhile, quitting during recovery); disk full.
- `MeetingReplayTests` (two WAVs, real captures, real `FolderMeetingSpool`
  in a temp folder): the note matches turn for turn; crashes before any
  chunk was complete, with a job in flight, after some results, and after
  stop all recover to a note with every sentence exactly once, the
  recovered line, and nothing left in progress.

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

The folders to watch (Finder › Go › Go to Folder…):
- `~/Library/Application Support/Cado/Meetings In Progress` (the meeting
  under way: one folder per meeting, `me.f32`, `them.f32`, `events.jsonl`)
- `~/Library/Application Support/Cado/Meeting Audio` (kept audio)

## A long call: the note shortly after stop

1. [ ] Settings › Notes › **Keep meeting audio** off. Record a real call of
       45–60 minutes (or play a long talk in the meeting app and talk now
       and then).
2. [ ] During it, `Meetings In Progress/<id>/` grows (~230 MB an hour per
       side) and Cado's memory in Activity Monitor stays flat (not growing
       by hundreds of MB).
3. [ ] **Stop Recording**: the menu shows "Finishing Meeting…" then at most a
       moment of "Transcribing Meeting… n of m" with n close to m; the
       "Meeting note saved" notice comes shortly after. Note how long it
       took, the Mac and the model (not guaranteed on slow Macs: there the
       backlog finishes after stop).
4. [ ] The note has the whole call, in order, nothing repeated.
5. [ ] `Meetings In Progress` is empty again; nothing in `Meeting Audio`.
6. [ ] Dictate right after: it works (waits for at most one passage).

## Keep meeting audio

- [ ] Turn **Keep meeting audio** on, record a short call, stop: the note is
      saved, `Meeting Audio/Meeting with <app> — <date time>/` has `Me.wav`
      and `Others.wav` (both play, ~2 MB a minute each), `Meetings In
      Progress` is empty.
- [ ] Turn it off again, record: nothing new in `Meeting Audio`, no WAVs
      after the note is saved.
- [ ] Record a call where nobody talks with the setting on: `Me.wav` and
      `Others.wav` are still kept (about the same size per hour).

## Force quit mid-meeting

1. [ ] Start a meeting, talk for 2–3 minutes in turns with the other side.
2. [ ] Activity Monitor › Cado › Force Quit (or `kill -9 $(pgrep -x Cado)`).
       The meeting's folder stays in `Meetings In Progress`.
3. [ ] Relaunch Cado. The menu shows "Recovering Meeting…" with progress
       (and the Library an in-progress row), then a "Meeting note
       recovered" notification; clicking it opens the note.
4. [ ] The note starts with "Cado quit unexpectedly during this meeting.
       This note was recovered from what had been recorded.", has everything
       said up to about a second before the force quit exactly once, and its duration is about
       how long it recorded. `Meetings In Progress` is empty.
5. [ ] Again, but force quit a few seconds after **Stop Recording** on a long
       meeting (while it's still transcribing): the recovered note has the
       whole meeting.
6. [ ] While the menu shows "Recovering Meeting…", click **Record Meeting**:
       it does not start, and a notice says why. When the recovered note is
       saved, Record Meeting works again.
7. [ ] Force quit in a silent meeting (nobody talks): relaunch: no note, no
       notification, the folder is gone.
8. [ ] After each case above (quit, force quit, recovery), the notes folder
       has exactly one note for that meeting, never a second one.

## Quit mid-meeting

- [ ] Quit Cado from the menu while recording, then relaunch: the menu shows
      "Recovering Meeting…", then the complete note appears with the line
      "Cado was quit during this meeting; the note was finished the next time
      Cado started." `Meetings In Progress` is empty afterwards.

## Low disk

- [ ] On a nearly full disk (or a small disk image as the home folder's
      volume — don't fill the real disk): record until it's full. A "Meeting
      audio isn't being saved to disk" notification appears once; recording
      goes on; the note on stop has the whole meeting. Free the space after.
- [ ] Make `Meetings In Progress` impossible to create (e.g. a file with that
      name in its place): a meeting still records and writes its note (the
      log says why its audio isn't kept on disk).

## Limits to know

- The 2-hour cap stays; tail-only work after stop is guaranteed by design and
  tests, the seconds it takes depend on the Mac and model.
- After a crash, up to about a second of audio right before it may be
  missing; after a power cut, a few more seconds.
- With the disk full mid-meeting, that meeting isn't crash-safe.
