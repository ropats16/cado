# Changelog

User-facing changes per release, newest first. Versioning rules: `docs/RELEASING.md`.

## Unreleased

### Changed
- Auto-detect and languages other than English are transcribed with a larger Whisper model, `large-v3-turbo-q5_0` (574 MB), on Apple Silicon Macs with 16 GB or more: on our Hindi/English test it got 13% of Hindi words wrong, against 42% for `medium` and 60% for `small`. Cado never downloads it by itself; until you download it in Settings › Speech Model, the largest multilingual model you already have is used. Other Macs keep their current pick. English is unchanged.
- An English-only Whisper model is no longer used for Auto-detect or another language when a multilingual model is installed.
- Meeting summaries now lead with a short overview followed by Decisions, Action items, Discussion, and Open questions (omitting empty sections). Existing summaries are unchanged until you choose Regenerate Summary in the Library.

### Added
- Spoken hesitation sounds ("um", "uh", …) are removed by default from dictated text and meeting transcripts on every speech engine, with punctuation, spacing and sentence-start capitalization tidied up and hesitation-only passages dropped. Real words in every language Cado transcribes (such as German and Portuguese "um") and meaningful expressions ("uh-huh", "mm-hmm", "like", "you know") stay untouched.
- Settings › Speech Model › **Remove hesitation sounds** (and `removeHesitations` in `config.json`, on by default): turn it off to keep dictated text and meeting transcripts verbatim.
- Meeting summaries always strip hesitation sounds before summarizing, including when summarizing or regenerating summaries for notes recorded before this change, without rewriting the saved transcript.

## 0.6.0 - 2026-11-18

### Changed
- Settings, the Library, and model setup now follow the approved mockup more closely: compact underline tabs, green note selection, refined summary and transcript layout, and outlined model cards. Existing search, note actions, provider controls, and setup choices remain available.
- Mascot settings now have their own Mascot & Notes tab. Additional meeting options are under More meeting settings.
- Meeting summaries use English and focus on concise takeaways, explicit decisions, and action items. For supported input languages, on-device summaries check for useful content before generation and filter trivial or incoherent items afterward.

### Fixed
- The summary switch shows your saved choice and stays editable while Apple Intelligence prepares its model. Returning to Settings refreshes availability; generation still waits until the model is ready.

Existing summaries are unchanged until you choose Regenerate Summary in the Library. Summary quality still depends on the transcript: use Meeting Language › Auto-detect with a multilingual speech model for Hindi/English transcription. Apple Intelligence's summary model does not currently support Hindi; English output does not remove that input-language limitation. Custom summary formats and transcript chat are tracked separately in issue #58.

## 0.5.0 - 2026-11-17

Prepared and installed locally, not published on GitHub. Its changes are included in 0.6.0.

### Changed
- A brighter, cleaner Cado: stronger native typography, white surfaces, richer greens, and refined Settings, Library, and setup screens in light and dark mode.
- Meeting notes open in a summary-first Library with a Summary / Transcript switch, a compact sidebar, and clearer meeting details. Notes without an available summary still open directly to their transcript; ordinary Markdown notes keep their normal reading view.
- The listening avocado has two soft outer sound rings, without the red ring around its center.
- The website follows the approved design, with a larger animated mascot, raised green buttons, three step cards, and clearer permission guidance. Its app preview shows the released Library interface.

Meeting summaries introduced in 0.4.0 remain available through on-device Apple Intelligence on supported Macs, or opt-in OpenRouter. Existing notes, settings, and downloaded speech models are preserved.

## 0.4.0 - 2026-11-17

### Added
- "Record this meeting?": when a meeting app (Zoom, Teams, Slack, Webex, Discord, FaceTime, or a browser for Meet and other web calls) starts using the microphone, Cado asks, with Record and Not Now. It asks in a notification, in the menu (the menu bar shows "Record?") and with the mascot, so it works with notifications off too. Cado never records by itself. Needs macOS 14.4 or later; turn it off in Settings › Meetings.
- "Stop recording?": when the recorded app stops using the microphone, Cado asks whether to stop. It never stops by itself.
- Meeting hotkey: ⌃⌥M starts and stops a meeting recording. Change it in Settings › Meetings.
- The mascot and meetings: click it while a meeting records to stop; click it when it asks to record. Its right-click menu starts with Record Meeting or Stop Recording.
- Right-click the mascot for Hide Mascot and Settings…; VoiceOver reads it as a button and can press it.
- A one-time reminder before your first meeting recording that getting everyone's consent to be recorded is up to you.
- Settings › Meetings › Max meeting length: 30 minutes to 4 hours (default 2 hours, as before) or Off. A meeting that reaches it stops with a notification, and its note is saved as usual.
- Name meetings from your calendar (optional, off by default): Settings › Meetings › Name meetings from my calendar. A meeting that starts around a calendar event is named after it, and the note lists the other people's names (never their email addresses). Turning it on is what asks macOS for Calendar access; if you say no, Settings says how to allow it later. Without a match, it's named after the app and time as before. Cado only reads your calendar on your Mac, but the event's title and the invitees' names are saved in the note, so they go wherever your notes folder syncs.
- Onboarding has an optional Calendar step for the same switch.
- Meeting summaries on macOS 26 with Apple Intelligence: after a meeting note is saved, Apple Intelligence adds a Summary (key points, decisions, action items) above the transcript, written on your Mac. Long meetings are summarized in parts and combined. The note is saved first and is complete without a summary.
- Optional OpenRouter summaries: Settings › Meetings › Written by can be set to OpenRouter, so a cloud model writes the summary (for Macs without Apple Intelligence, or if you want a bigger model). Once you confirm and save an API key (kept in your Keychain), the text of every new meeting, never audio, is sent automatically to OpenRouter and the model's company after the meeting is saved, while Summarize meetings is on. Cado warns you and asks you to confirm first, and sends nothing until then. Cado asks OpenRouter to use only providers that don't keep or train on it, so some models may be unavailable; their terms still apply. Switching back to Apple Intelligence or choosing Remove Key stops it, including a summary in progress. Pick a model from a short list or choose Other… and type a model name; Refresh fetches the full list. The note says which model wrote the summary. Apple Intelligence stays the default.
- Library: a meeting's summary shows in a card above the transcript, with Regenerate Summary (or Summarize for a note without one). A new summary replaces the old one; the rest of the note is kept.
- Settings › Meetings › Summarize meetings: on by default; where summaries can't run, it says why.
- Summaries: very short meetings (under about 40 words) aren't summarized automatically (Summarize still works); a note you edit while it's being summarized is left as you edited it; while Apple Intelligence is still getting ready, the Library still offers Summarize and says why.
- Settings › Meetings › Meeting Language: meetings can have their own language. "Same as dictation" (the default) keeps everything as it was. "Auto-detect" works out the language of each passage on its own, for meetings that mix languages such as Hindi and English: each comes out in its own script (Hindi in Devanagari with the small model or larger), not translated. A very short reply is written in the language that side last spoke, and a sentence that switches language midway comes out in one. A multilingual dictation model (or Turbo, for its languages) also runs the meeting, in the meeting's language, without being loaded twice. When the dictation model can't do that (Turbo for Hindi, or an English-only model), meetings use a multilingual model of their own, loaded only while a meeting is transcribed, so dictation keeps its model. If that model isn't downloaded, or doesn't load, the card says so (and offers the download), meetings use the dictation model meanwhile, and the note says so; a model that didn't load is tried again at the next meeting.
- Settings › Speech Model warns when the model only understands English but the language set isn't English, and says what to choose instead.
- Record Meeting (from the menu, the meeting hotkey or the mascot) works while Cado is finishing a meeting from an earlier run: that recovery waits while you record and goes on after. While you record, the menu shows only the new meeting; the recovery's progress shows again once the new note is saved.
- A meeting note's front matter has an `id` line, so if Cado stops right after saving a note, the next launch finds it and doesn't write a second one. It can still write a second one if the notes folder was changed in Settings in between, the note was moved into a subfolder, the Mac's clock was set back, or the note had gone to the Meeting Audio folder. Notes without it open as before. A note found this way keeps the meeting's audio in the Meeting Audio folder and gets its summary as usual. Part of a note left by a save that failed is never used or deleted: the whole note is written beside it (or, if a whole one is there too, that one is used).
- A recording in Meetings In Progress whose details can't be read is no longer left there silently: its audio is kept as WAV files in the Meeting Audio folder, with the rest of the recording (the transcript so far included) next to them, and Cado tells you where, once.

### Changed
- Release update feeds are signed as well as the app download. Requiring signed feeds in installed apps is staged for the following release, after the first signed feed is published and verified.
- A hand-edited language in the config file that isn't a language code ("hindi", "en-US") is reported in Settings instead of giving garbled text.
- With English dictation, Automatic takes the English-only file over the multilingual one of the same size. A larger multilingual model you download (say small, for meetings) is still used for dictation when it's bigger than your English-only ones.
- Settings has tabs along the top: General, Dictation, Speech Model and Meetings, with the hotkeys first under Dictation. Notes folder and Keep meeting audio moved to Meetings; the mascot, sounds and Keep recent dictations to Dictation.
- Settings remembers where you left its window, and long folder paths and model names no longer cut off.
- The hotkey button that said "Record" now says "Change…", so it can't be mistaken for Record Meeting.
- Settings shows letter keys in hotkeys by name ("⇧⌘R" instead of a key number), using your keyboard layout.
- Settings warns when two hotkeys overlap (for example Record meeting ⌃⇧M and Hold to talk ⌃⇧) or when a hand-edited meeting length is over a day or under a minute.
- The menu no longer lists permissions that are already granted. Open Config File and Open Models Folder are under Advanced.
- "About Cado" replaces "Acknowledgements…": it shows the version, and the credits are in the same window.
- The Library and the menu's Open Last Meeting Note stay quick with a large notes folder: notes that haven't changed aren't read again, and the list is prepared in the background.
- Updated the speech engine (whisper.cpp 1.9.5), which includes a fix for a crash on a damaged model file.
- A hand-made WhisperKit model folder with a damaged tokenizer file (in any place WhisperKit looks) is refused instead of making Cado download a replacement.

### Fixed
- Meetings on laptop speakers: what the other side says no longer shows up a second time under "Me" (a few garbled words can still slip through). Your replies stay, also ones that reuse their words, and "yeah"s over them. Saying the same words as them at the same moment, like both saying "thank you", is left out of "Me" on speakers. With headphones Cado normally leaves nothing out.
- On a nearly full disk, a recovered meeting's note no longer says Cado quit unexpectedly when it was quit, and a meeting Cado can't finish isn't retried on every launch: it waits one launch for free space and says so. If the disk is still full then, or Cado can't write to its Meetings In Progress folder at all, the untouched recording is moved to the Meeting Audio folder and Cado tells you why and where, once.
- Recovery also stops safely when folder renames fail while the journal remains writable: stale progress markers cannot cause repeated give-up crashes or misorder a failed note save. The raw recording is preserved, with its location explained once.
- Starting and at once stopping a meeting while Cado finishes an earlier one no longer counts against that recovery, and pausing it no longer waits for the disk before your recording starts.
- After a power cut, at most about 5 seconds of a meeting's audio can be lost (the recording is now flushed to the disk itself every 5 seconds, in the background, so a slow disk doesn't hold up the menu or the recording). A new meeting's details are flushed too, so its recording can't come back without them.
- A note is saved whole or not at all: a save that fails partway (a full disk) leaves no half-written note, and the meeting is finished later as when the note can't be saved.
- Kept meeting audio is complete when Cado says it's kept: a copy that doesn't reach the disk whole is reported as not kept, and the recording stays until it can be copied. Only a recording whose own file was cut short is kept as far as it can be read, with a notice saying how much at the end is missing, instead of being retried on every launch.
- Looking for a meeting's note never waits for a note in iCloud Drive (or another cloud folder) to download.

## 0.3.0 - 2026-11-17

Prepared milestone, not published on GitHub. Its changes are included in 0.4.0.

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
