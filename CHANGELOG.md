# Changelog

User-facing changes per release, newest first. Versioning rules: `docs/RELEASING.md`.

## Unreleased

### Added
- Meetings are transcribed while you talk, so the note is ready seconds after you stop, even after an hour-long call (on a Mac that keeps up; a slower one finishes the rest after you stop).
- If Cado quits unexpectedly during a meeting (a crash, Force Quit, power loss), the next launch finishes the note from what was recorded and says it was recovered.
- Settings › Notes › Keep meeting audio: off by default, a meeting's audio is deleted once its note is saved; on, it's kept as WAV files in Cado's Meeting Audio folder.

### Changed
- A meeting's audio is written to disk as it's recorded (in a folder only your account can read) instead of being held in memory.
- If the disk fills up during a meeting, a notification says so; recording carries on and the note is still written.

## 0.3.0 - 2026-11-17

### Added
- Setup: an optional Notifications step, and "Almost there" now has a button for each step still to do.

### Changed
- Messages in the menu, Settings, setup and notifications say what to do inside Cado; no more terminal commands or "see log".
- Engine and download errors are in plain words, without file paths.
- Settings: the model download list opens by itself while a download runs or fails, or when the chosen model is missing.
- Hotkey clashes are explained in plain words.
- One name per thing: "speech model", "the mascot", "Send anonymous usage count"; consistent button and notification titles.

### Fixed
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
