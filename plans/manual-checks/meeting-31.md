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

## A long call: the note within seconds

1. [ ] Settings › Notes › **Keep meeting audio** off. Record a real call of
       45–60 minutes (or play a long talk in the meeting app and talk now
       and then).
2. [ ] During it, `Meetings In Progress/<id>/` grows (~230 MB an hour per
       side) and Cado's memory in Activity Monitor stays flat (not growing
       by hundreds of MB).
3. [ ] **Stop Recording**: the menu shows "Finishing Meeting…" then at most a
       moment of "Transcribing Meeting… n of m" with n close to m; the
       "Meeting note saved" notice comes within seconds. Note how many
       seconds, the Mac and the model (not guaranteed on slow Macs: there
       the backlog finishes after stop).
4. [ ] The note has the whole call, in order, nothing repeated.
5. [ ] `Meetings In Progress` is empty again; nothing in `Meeting Audio`.
6. [ ] Dictate right after: it works (waits for at most one passage).

## Keep meeting audio

- [ ] Turn **Keep meeting audio** on, record a short call, stop: the note is
      saved, `Meeting Audio/Meeting with <app> — <date time>/` has `Me.wav`
      and `Others.wav` (both play, ~2 MB a minute each), `Meetings In
      Progress` is empty.
- [ ] Turn it off again, record: nothing new in `Meeting Audio`.

## Force quit mid-meeting

1. [ ] Start a meeting, talk for 2–3 minutes in turns with the other side.
2. [ ] Activity Monitor › Cado › Force Quit (or `kill -9 $(pgrep -x Cado)`).
       The meeting's folder stays in `Meetings In Progress`.
3. [ ] Relaunch Cado. Once the model is loaded the menu shows "Transcribing
       Meeting… n of m" (and the Library an in-progress row), then a
       "Meeting note recovered" notification; clicking it opens the note.
4. [ ] The note starts with "Cado quit unexpectedly during this meeting.
       This note was recovered from what had been recorded.", has everything
       said up to the force quit exactly once, and its duration is about
       how long it recorded. `Meetings In Progress` is empty.
5. [ ] Again, but force quit a few seconds after **Stop Recording** on a long
       meeting (while it's still transcribing): the recovered note has the
       whole meeting.
6. [ ] Force quit mid-meeting, relaunch and click **Record Meeting** right
       away. Before the model is loaded: the new meeting records normally,
       and the recovery runs after you stop it (two notes, the new one
       first). Once recovery has started: Record Meeting is unavailable
       ("Transcribing Meeting…") until the recovered note is saved.
7. [ ] Force quit in a silent meeting (nobody talks): relaunch: no note, no
       notification, the folder is gone.

## Quit normally mid-meeting

- [ ] Quit Cado from the menu while recording: as in 0.3 (a note saying it
      wasn't fully transcribed, audio in `Meeting Audio`), and nothing left in
      `Meetings In Progress`; relaunch: no recovered note.

## Low disk

- [ ] On a nearly full disk (or a small disk image as the home folder's
      volume — don't fill the real disk): record until it's full. A "Meeting
      audio isn't being saved to disk" notification appears once; recording
      goes on; the note on stop has the whole meeting. Free the space after.
- [ ] Make `Meetings In Progress` impossible to create (e.g. a file with that
      name in its place): a meeting still records and writes its note (the
      log says it's held in memory).

## Limits to know

- The 2-hour cap stays; tail-only work after stop is guaranteed by design and
  tests, the seconds it takes depend on the Mac and model.
- After a crash only what reached the disk is recovered: the last ~0.5 s
  (one delivery) and, on power loss, up to ~5 s may be missing.
- With the disk full mid-meeting, that meeting isn't crash-safe.
