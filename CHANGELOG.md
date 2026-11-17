# Changelog

User-facing changes per release, newest first. Versioning rules: `docs/RELEASING.md`.

## Unreleased

### Changed
- Settings has tabs along the top: General, Dictation, Speech Model and Meetings, with the hotkeys first under Dictation. Notes folder and Keep meeting audio moved to Meetings; the mascot, sounds and Keep recent dictations to Dictation.
- Settings remembers where you left its window, and long folder paths and model names no longer cut off.
- The hotkey button that said "Record" now says "Change…", so it can't be mistaken for Record Meeting.
- The menu no longer lists permissions that are already granted. Open Config File and Open Models Folder are under Advanced.
- "About Cado" replaces "Acknowledgements…": it shows the version, and the credits are in the same window.
- The Library and the menu's Open Last Meeting Note stay quick with a large notes folder: notes that haven't changed aren't read again, and the list is prepared in the background.
- Updated the speech engine (whisper.cpp 1.9.5), which includes a fix for a crash on a damaged model file.
- A hand-made WhisperKit model folder with a damaged tokenizer file (in any place WhisperKit looks) is refused instead of making Cado download a replacement.

### Added
- Right-click the mascot for Hide Mascot and Settings…; VoiceOver reads it as a button and can press it.
- Meeting summaries on macOS 26 with Apple Intelligence: after a meeting note is saved, Apple Intelligence adds a Summary (key points, decisions, action items) above the transcript, written on your Mac. Long meetings are summarized in parts and combined. The note is saved first and is complete without a summary.
- Library: a meeting's summary shows in a card above the transcript, with Regenerate Summary (or Summarize for a note without one). A new summary replaces the old one; the rest of the note is kept.
- Settings › Meetings › Summarize meetings: on by default; where summaries can't run, it says why.
- Summaries: very short meetings (under about 40 words) aren't summarized automatically (Summarize still works); a note you edit while it's being summarized is left as you edited it; while Apple Intelligence is still getting ready, the Library still offers Summarize and says why.
- Record Meeting works while Cado is finishing a meeting from an earlier run: that recovery waits while you record and goes on after. While you record, the menu shows only the new meeting; the recovery's progress shows again once the new note is saved.
- A meeting note's front matter has an `id` line, so if Cado stops right after saving a note, the next launch finds it and doesn't write a second one. It can still write a second one if the notes folder was changed in Settings in between, the note was moved into a subfolder, the Mac's clock was set back, or the note had gone to the Meeting Audio folder. Notes without it open as before. A note found this way keeps the meeting's audio in the Meeting Audio folder and gets its summary as usual. Part of a note left by a save that failed is never used or deleted: the whole note is written beside it (or, if a whole one is there too, that one is used).
- A recording in Meetings In Progress whose details can't be read is no longer left there silently: its audio is kept as WAV files in the Meeting Audio folder, with the rest of the recording (the transcript so far included) next to them, and Cado tells you where, once.

### Fixed
- On a nearly full disk, a recovered meeting's note no longer says Cado quit unexpectedly when it was quit, and a meeting Cado can't finish isn't retried on every launch: it waits one launch for free space and says so. If the disk is still full then, or Cado can't write to its Meetings In Progress folder at all, the untouched recording is moved to the Meeting Audio folder and Cado tells you why and where, once.
- Starting and at once stopping a meeting while Cado finishes an earlier one no longer counts against that recovery, and pausing it no longer waits for the disk before your recording starts.
- After a power cut, at most about 5 seconds of a meeting's audio can be lost (the recording is now flushed to the disk itself every 5 seconds, in the background, so a slow disk doesn't hold up the menu or the recording). A new meeting's details are flushed too, so its recording can't come back without them.
- A note is saved whole or not at all: a save that fails partway (a full disk) leaves no half-written note, and the meeting is finished later as when the note can't be saved.
- Kept meeting audio is complete when Cado says it's kept: a copy that doesn't reach the disk whole is reported as not kept, and the recording stays until it can be copied. Only a recording whose own file was cut short is kept as far as it can be read, with a notice saying how much at the end is missing, instead of being retried on every launch.
- Looking for a meeting's note never waits for a note in iCloud Drive (or another cloud folder) to download.

## 0.3.0 - 2026-11-17

### Added
- Meetings are transcribed while you talk, so the note is ready shortly after you stop, even after an hour-long call (on a Mac that keeps up; a slower one finishes the rest after you stop).
- A meeting interrupted by a crash, Force Quit or quitting Cado is finished the next time Cado starts, and its note says so. Up to about a second of audio just before a crash can be lost.
- A meeting whose note can't be saved (the notes folder is unavailable or the disk is full) is kept and finished the next time Cado starts. Cado tells you once.
- The menu shows "Recovering Meeting…" with progress while Cado finishes a meeting from an earlier run; Record Meeting waits until it's done.
- Settings › Notes › Keep meeting audio: off by default, a meeting's audio is deleted once its note is saved; on, it's kept as WAV files in Cado's Meeting Audio folder. Audio is also kept when part of a meeting couldn't be transcribed.
- Setup: an optional Notifications step, and "Almost there" now has a button for each step still to do.

### Changed
- A meeting no longer sits in memory: its audio and transcript so far are written to a private folder as it's recorded, and deleted once the note is safely saved.
- Quitting Cado during a meeting no longer writes a partial note: the complete note is finished the next time Cado starts.
- A full disk no longer stops a meeting recording: Cado says so and keeps recording, but audio held in memory is lost if Cado quits unexpectedly before the note is saved.
- Messages in the menu, Settings, setup and notifications say what to do inside Cado; no more terminal commands or "see log".
- Engine and download errors are in plain words, without file paths.
- Settings: the model download list opens by itself while a download runs or fails, or when the chosen model is missing.
- Hotkey clashes are explained in plain words.
- One name per thing: "speech model", "the mascot", "Send anonymous usage count"; consistent button and notification titles.

### Fixed
- Two copies of Cado on one Mac never touch each other's meetings.
- Green text (Recommended badge, links) is readable in light mode.
- Outlines respect Increase Contrast.

## 0.2.0 - 2026-11-17

### Added
- Library: notes grouped by date (Today, Yesterday, This week, then by month); rows show time, duration and the recorded app.
- Library: a reading view for meeting notes with a clear header and distinct speaker turns; Copy Transcript.
- A meeting being recorded or transcribed shows in the Library as an in-progress row.
- Clicking the "Meeting note saved" notification opens that note; new menu item Open Last Meeting Note.
- Library empty state explains how to record a meeting.
- Website: https://ropats16.github.io/cado/

### Changed
- Meeting notes label the other side of the call "Others" instead of "Them". Older notes still open and show "Others"; files are not rewritten.

### Security
- Links in notes open only web and mail addresses.
- Model downloads stop at the expected size.
- Release builds use pinned dependency versions.
- README network table corrected to match what the app contacts.

## 0.1.0 - 2026-11-17

First public release: hotkey dictation, meeting notes, on-device transcription, Developer ID-signed DMG, Homebrew cask, auto-update.
