# Changelog

User-facing changes per release, newest first. Versioning rules: `docs/RELEASING.md`.

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
