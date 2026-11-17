# Manual checks: meeting recovery edge cases (#48)

What #31 left, each needing two rare faults at once. The setup (build,
folders to watch) is in [meeting-31.md](meeting-31.md); this list adds the
give-up and the #48 behaviours.

Already verified without a human:
- `MeetingSessionTests` (fakes, "#48" extensions): a note saved but not
  journaled is adopted by its id (no second note, audio still kept under the
  usual rule); an `.unsaved` mark goes into the journal once it works, so a
  give-up that dies writing its note is set aside next launch; an attempt the
  journal can't take is marked `.tried` once, another waits ("Couldn't finish
  a meeting yet"), and with room it goes on; a give-up the journal can't take
  waits; a clean quit clears `.tried`; a quit `.appQuit` couldn't journal is
  still "Cado was quit…"; Record Meeting during a recovery holds it at a chunk
  boundary (the passage in the engine is journaled first), the new note comes
  first, then the recovered one with every passage once; quitting while held
  pauses it; a recording without its details keeps its audio, or stays named
  `.unidentified` and is left alone.
- `MeetingSessionTests` (review fixes): an attempt marked `.tried` whose
  later writes reach the journal (the rename reopened its files) journals its
  start before its results, so it isn't counted as stalled; while its start
  can't be journaled nothing else of it is. A full disk waits one launch
  (`.waited`), then the recording is set aside (moved, told once why and
  where); a journal Cado can't write (permissions, read-only) or a wait that
  can't be marked is set aside at once; with room after a wait it goes on and
  the mark goes. Record Meeting stopped at once during a recovery's first
  passage journals the pause before the new attempt (not a stall); a hold
  during an asynchronous read-back goes on where it was, every passage once;
  the hold's pause is recorded without waiting for the disk. A spool audio
  file cut short is kept as far as it can be read, said once, and the spool
  is done. A part of a note listed ahead of the whole note with the same id
  doesn't stop the whole one being adopted; an adopted note is handed on for
  its summary once journaled (`MeetingSummariesTests` too).
- `MeetingSpoolTests`: `writeReadable` keeps what a short source has (checked
  and flushed for that length, no file if nothing); a pause recorded for a
  live meeting is in the journal at once and flushed in the background, even
  during a 5 s round. `MeetingSpoolMarksTests`: `.tried.waited` names,
  `.set-aside` folders left alone; only a full disk (ENOSPC/EDQUOT, also
  wrapped in Cocoa 640, the error a write to a full volume really throws:
  checked once on a 2 MB disk image) counts as waiting for room.
- `MeetingReplayTests` (real on-disk spool and notes folder): the note saved
  but not journaled is not written twice; a folder with a damaged
  meeting.json becomes `Me.wav` in Meeting Audio, said once; one a newer Cado
  made is left alone.
- `MeetingSpoolMarksTests`, `NoteMeetingIDTests`: names with several marks,
  the `id` front-matter line, the bounded lookup (only notes changed since the
  meeting began are opened).
- `NotesLibraryTests` ("Durable create"): a note write that fails partway
  (injected `ENOSPC`) or whose flush fails leaves neither a note nor a
  temporary; the text is flushed while still a hidden `.cado-note-….tmp` and
  only then renamed, never over an existing file; old temporaries are swept,
  none is ever listed. `NoteMeetingIDTests`: the id lookup skips a note whose
  bytes aren't local (faked) and is safe alongside listing and saving.
- `MeetingSpoolWAVTests`: a short or failing source throws and leaves no WAV;
  a whole copy has every sample. `MeetingSpoolFlushTests` (fake queue and
  flush): the 5 s flush is queued, never run on the appending thread, one at a
  time, on its own descriptors, which stay valid through a rename, a move and
  a discard and are closed after; a milestone is flushed before `record`
  returns; a new spool's meeting.json (complete), folder and root are flushed
  once in the background.
- Power-cut bound (`FolderSpoolHandle.syncIfDue`): measured on this Mac
  (M-series SSD) with a short script, 30 rounds each: one `F_FULLFSYNC` per
  5 s round ~5 ms (p90 ~8 ms), against ~15 ms for one per file and ~0.2 ms for
  plain `fsync`. Not measured: battery over a real hour (extrapolated: one
  ~5 ms drive flush every 5 s). It now runs on a utility queue, not the main
  thread.

## Give-up (from #31; not in meeting-31.md)

Needs a meeting that keeps killing Cado during recovery. Simulate it:
start a meeting, talk 1–2 minutes, force quit; relaunch and force quit again
while the menu shows "Recovering a meeting…" and before its note appears.
Do that twice.

1. [ ] Third launch: no third try. A "Meeting note recovered" note with only
       what was transcribed before, the line "Cado couldn't finish
       transcribing this meeting, so this note has only what was transcribed
       before.", and the audio named in the note is in `Meeting Audio`.
2. [ ] Again, but force quit the third launch the moment recovery starts (it
       writes the give-up note quickly, so this may take tries): the next
       launch says "Couldn't finish a meeting… Its recording is kept,
       unchanged, in <Meeting Audio folder>", the folder there holds the raw
       recording (`me.f32`, `them.f32`, `events.jsonl`, `meeting.json`), and
       later launches say nothing more about it.
3. [ ] After each case the notes folder has at most one note for the meeting.

## Record Meeting during a recovery

1. [ ] Leave a meeting for recovery (force quit mid-meeting, 3+ minutes so
       recovery takes a while). Relaunch; while the menu shows "Recovering a
       meeting with … n of m. It waits while you record.", choose **Record
       Meeting**: it starts at once, no "Meeting not started" notice.
2. [ ] While recording, dictation is refused as usual; the menu bar shows the
       recording; the Library's in-progress row shows the new meeting.
3. [ ] Stop: the new meeting's note comes first ("Meeting note saved"), then
       the menu shows "Recovering a meeting…" again where it left off, then
       "Meeting note recovered". Both notes are whole, nothing repeated.
4. [ ] Again, but quit Cado from the menu while the new meeting records:
       relaunch; both meetings are finished (the new one says Cado was quit),
       one note each.
5. [ ] Again with the meeting hotkey (⌃⌥M) and with the mascot's Record
       Meeting, on a call: each starts recording the same way (no "Meeting not
       started" notice). Before the first meeting recording ever, the consent
       reminder shows first; Cancel leaves the recovery going.
6. [ ] With Settings › Meetings › Name meetings from my calendar on, during an
       event: the held recovery's note keeps its own name (app and time, or
       its own event), the new note is named after the event.

## A note saved just before Cado stopped

Hard to hit by hand (microseconds). If you have a debugger: break right after
the note file is written in `MeetingSession.complete`, kill Cado there.

- [ ] Relaunch: no second note; a "Meeting note saved" notice for the existing
      note; `Meetings In Progress` is empty afterwards.
- [ ] Same with a meeting named from the calendar: no second note, and the
      notice names the event.
- [ ] Open a meeting note in a text editor: its front matter has
      `id: "<long id>"` after `duration` (before `event`/`attendees` when named
      from the calendar). Open it in Obsidian: nothing odd.
      Older notes without the line still list and open in the Library.

## A full disk (use a small disk image as the home folder's volume)

- [ ] Fill the disk, quit Cado from the menu mid-meeting: the meeting's
      folder in `Meetings In Progress` is named `<id>.quit`. Free space,
      relaunch: the note says "Cado was quit during this meeting…", not
      "quit unexpectedly"; the folder is gone.
- [ ] Leave a meeting for recovery, fill the disk, relaunch twice: the first
      launch tries once (folder named `<id>.tried` while it runs); if it
      can't finish, the next launch shows "Couldn't finish a meeting yet",
      doesn't transcribe, and the folder is `<id>.tried.waited`. Free space,
      relaunch: the note appears, the folder is gone.
- [ ] Same, but leave the disk full for a third launch: "Couldn't finish a
      meeting — Your Mac's disk is still full, so Cado couldn't finish …
      and has stopped trying. Its recording is kept, unchanged, in …/Meeting
      Audio/…"; the raw recording is there; later launches say nothing.
- [ ] A recovery whose folder Cado can't write to: quit Cado, on a leftover's
      folder in Meetings In Progress use Finder › Get Info › Sharing &
      Permissions to give yourself Read only on `events.jsonl` (or lock it),
      rename the folder to `<id>.tried`, relaunch: "Cado can't write to its
      Meetings In Progress folder, so it couldn't finish … and has stopped
      trying", told once, the recording moved to Meeting Audio.
- [ ] A meeting whose note couldn't be saved (`<id>.unsaved`): free space,
      relaunch: the folder name goes back to plain `<id>` while it recovers,
      then the note appears saying it couldn't be saved when the meeting
      ended.

## A slow disk

- [ ] Set the Meetings In Progress folder's disk to a slow one (an old USB
      stick or a disk image on a network share, linked in place of
      `~/Library/Application Support/Cado/Meetings In Progress` while Cado is
      quit), or keep the disk busy (copy a large folder in Finder). Record a
      2-minute meeting: the menu opens at once and the overlay doesn't stutter
      every 5 seconds; the note is whole.

## A note save that fails partway

- [ ] Notes folder on a nearly full small disk image (a few hundred KB free).
      Record a long meeting (or paste a long body) so the note doesn't fit:
      "Meeting note couldn't be saved"; the notes folder holds no new or
      half-written `.md` file (in Finder, with hidden
      files shown, ⇧⌘., shows no `.cado-note-…` file either). Free space and
      relaunch: the note appears once, whole.

## Notes in iCloud Drive

- [ ] Notes folder in iCloud Drive with "Optimise Mac Storage" on; remove
      the download of some older notes (Finder › Remove Download). Leave a
      meeting for recovery and relaunch: recovery goes ahead without those
      notes downloading again (their cloud icon stays); one note for the
      meeting.

## A recording cut short

- [ ] Leave a meeting for recovery with Keep meeting audio on; quit Cado;
      cut the leftover folder's `them.f32` to half its size (Terminal:
      `truncate -s <half the size, a multiple of 4> them.f32`). Relaunch: the note appears; "Part of a meeting's audio is
      missing — The end of the recording of … couldn't be read, so about …
      at the end of its audio is missing from …"; `Others.wav` plays and is
      that much shorter; the folder is gone from Meetings In Progress, and the
      next launch says nothing.

## Adopted note: summary and duplicates

- [ ] With summaries on, use the debugger break from "A note saved just
      before Cado stopped": after relaunch the adopted note gets its Summary
      section like any saved note.
- [ ] Put a copy of a meeting note with its last lines deleted (same `id`
      line) in the notes folder next to it, then make the same meeting adopt
      (debugger break as above): no third note; both files stay.

## Kept audio

- [ ] Keep meeting audio on: after a meeting, `Me.wav` and `Others.wav` in
      Meeting Audio play to the end and are as long as the meeting.

## A recording without its details

- [ ] Quit Cado. In `Meetings In Progress`, pick a leftover meeting's folder
      (or make one by force quitting mid-meeting) and replace its
      `meeting.json` with a few junk characters. Relaunch: "Couldn't finish a
      meeting — Cado found a meeting recording without its details…  Its
      audio is kept in …/Meeting Audio/Meeting with an unknown app — <date>";
      `Me.wav`/`Others.wav` there play, and the rest of the recording's
      folder (`events.jsonl` with the transcript so far, `me.f32`…) is next to
      them. The folder is gone from `Meetings In Progress`; later launches say
      nothing.

## Limits to know

- A note that went to the Meeting Audio folder (the notes folder wouldn't
  take it) isn't looked for by id: if Cado stops right after writing that
  `Note.md` and before journaling it, the next launch writes the note again
  (into the notes folder if it works by then).
- A recording without its details gets no note: its transcript so far stays
  in its `events.jsonl`, kept next to the audio, but isn't turned into a note.
- The id lookup (no second note) looks only at the top level of the current
  notes folder, at notes changed since the meeting began: a second note can
  still be written if the notes folder was changed in Settings between the
  crash and the relaunch, the note was moved into a subfolder, the clock was
  set back, or the note went to the Meeting Audio folder (above). A note in
  iCloud Drive that isn't downloaded isn't opened, so it isn't found either.
- While a recovery is held for a new meeting, the menu and the Library show
  only the new meeting; the recovery shows again once that note is saved.
- A recovery paused for a new meeting writes its pause without waiting for
  the disk (so the recording starts at once): a power cut in the few
  milliseconds before it reaches the disk loses the pause, as it could before
  while the flush ran first. That attempt then counts as stalled only if it
  had got nowhere; two are needed for a give-up, which still writes the note
  and keeps the audio.
- If Cado can't write anywhere (not to the spool folder, its name, or the
  Meeting Audio folder: a read-only disk), a recording it has stopped trying
  can't be marked so, and it is told again on each launch.
- A recording whose audio can't be read at all (not just cut short) is still
  retried on each launch, quietly after the first notice.
