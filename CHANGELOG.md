# Changelog

User-facing changes per release, newest first. Versioning rules: `docs/RELEASING.md`.

## Unreleased

### Changed
- The Library and the menu's Open Last Meeting Note stay quick with a large notes folder: notes that haven't changed aren't read again, and the list is prepared in the background.
- Updated the speech engine (whisper.cpp 1.9.5), which includes a fix for a crash on a damaged model file.
- A hand-made WhisperKit model folder with a damaged tokenizer file (in any place WhisperKit looks) is refused instead of making Cado download a replacement.

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
