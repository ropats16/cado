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

## A note saved just before Cado stopped

Hard to hit by hand (microseconds). If you have a debugger: break right after
the note file is written in `MeetingSession.complete`, kill Cado there.

- [ ] Relaunch: no second note; a "Meeting note saved" notice for the existing
      note; `Meetings In Progress` is empty afterwards.
- [ ] Open a meeting note in a text editor: its front matter has
      `id: "<long id>"` after `duration`. Open it in Obsidian: nothing odd.
      Older notes without the line still list and open in the Library.

## A full disk (use a small disk image as the home folder's volume)

- [ ] Fill the disk, quit Cado from the menu mid-meeting: the meeting's
      folder in `Meetings In Progress` is named `<id>.quit`. Free space,
      relaunch: the note says "Cado was quit during this meeting…", not
      "quit unexpectedly"; the folder is gone.
- [ ] Leave a meeting for recovery, fill the disk, relaunch twice: the first
      launch tries once (folder named `<id>.tried` while it runs); if it
      can't finish, the next launch shows "Couldn't finish a meeting yet" and
      doesn't transcribe. Free space, relaunch: the note appears.
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
