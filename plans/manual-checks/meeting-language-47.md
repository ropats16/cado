# Manual checks: meeting language (#47)

What the tests can't reach: real voices and accents, a real call, Settings
on screen, memory on an 8 GB Mac. Results and design: `plans/meeting-languages-47.md`.

Already verified without a human:
- `MeetingLanguageTests`: the setting (old configs → "Same as dictation"),
  which model a meeting gets (dictation model when it fits, else a
  multilingual one; never an English-only one for another language).
- `MeetingLanguageSessionTests` / `MeetingSpoolLanguageTests`: the language
  goes into the spool at start, every passage and the tail's prewarm carry
  it, a recovery uses the spool's, an old spool without it uses the
  dictation model.
- `MeetingModelRouterTests`: the meeting model is made and loaded once, a new
  language switches it, missing/failed → dictation model (no passage lost).
- `SettingsMeetingLanguageTests`: the card's text and Download row, the
  English-only warning, plain words.
- `Cado --meeting-test` on the synthetic Hindi + English fixture
  (`scripts/make_mixed_language_fixture.sh`): Same as dictation 58% WER,
  Auto-detect 30%, English exact, Hindi in Devanagari.

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

A multilingual whisper model must be downloaded for Auto-detect meetings
(Settings › Meetings › Meeting Language offers it if not).

## Checks

1. **Default unchanged.** Fresh config (or 0.3.0's): Settings › Meetings ›
   Meeting Language shows "Same as dictation (English)" and "Meetings use the
   dictation model, Turbo, in English." Record a short English meeting: the
   log (`~/Library/Logs/Cado` / Console) has no "Meeting: loading" line.
   Dictation still runs on Turbo.
2. **Auto-detect.** Pick Auto-detect. The line names the meeting model
   (e.g. Whisper small-q5_1). Record a call where two people alternate Hindi
   and English sentences (pause between them). Expected: Hindi lines in
   Devanagari, English lines in English, not translated, not romanised. The
   log has "Meeting: loading … for meetings" once.
3. **Dictation during the tail.** Right after Stop on a long Auto-detect
   meeting, dictate a sentence: it comes out on Turbo, in English, without
   waiting for the meeting.
4. **Memory (8 GB Mac if available).** Activity Monitor › Memory for Cado:
   during an Auto-detect meeting it rises (roughly 0.7 GB with small; not measured precisely) and drops
   about 2 minutes after the note is saved.
5. **Missing model.** Remove every multilingual `ggml-*.bin` (not `.en`) from
   the models folder (menu › Advanced › Open Models Folder). Meeting Language on Auto-detect: the line is a
   warning naming the model and "Download it below", with a Download row.
   Download works and the warning turns into the normal line.
6. **English-only warning.** Settings › Speech Model: Engine Whisper, Model
   small.en-q5_1, then hand-edit `config.json` `"language": "hi"` (the picker
   is greyed out for `.en` models). Settings shows "Whisper small.en-q5_1
   only understands English, so Hindi comes out as English words. …".
7. **Recovery keeps the language.** Start an Auto-detect meeting, speak
   Hindi, Force Quit Cado (Activity Monitor) mid-meeting. Switch Meeting
   Language back to Same as dictation, relaunch. The recovered note still has
   the Hindi in Devanagari (the spool's `meeting.json` has `"language":"auto"`).
8. **Mid-sentence switch (known limit).** Say one sentence that switches
   language halfway without pausing ("हमें client को Friday तक report
   भेजनी है"). It comes out in one script; note how readable it is.
9. **Bad language in the config file.** Hand-edit `config.json`:
   `"meetingLanguage": "hindi"`, relaunch. The Meetings tab says the language
   isn't one Cado knows and to pick one; same for `"language": "en-US"` on the
   Speech Model tab. Pick a language in Settings: the warning goes.
10. **Meeting download and dictation's model.** Dictation on English with
    Whisper Automatic and base.en downloaded; download the meeting's
    multilingual small. Expected: dictation moves to small (bigger, more
    accurate; meetings reuse the loaded file). With small.en also downloaded,
    dictation stays on small.en.
11. **One loaded model.** Dictation on Whisper small-q5_1 in English, Meeting
    Language Hindi or Auto-detect. Record a short meeting. Expected: the card
    says meetings use the dictation model; Activity Monitor shows Cado's memory
    no higher during the meeting's transcription than during dictation; the log
    has no "Meeting: loading" line.
12. **A meeting model that won't load.** Replace the meeting model's file with
    a damaged copy (keep the original to put back), record a Hindi meeting.
    Expected: one "didn't load" in the log, not one per passage; the Meetings
    card says the model didn't load and which model meetings use; the note has
    the line about the dictation model. Put the file back, record again: the
    meeting model is used.
13. **Short replies under Auto-detect.** In a Hindi + English call, answer
    "haan" / "ok" between longer Hindi sentences. Expected: the short replies
    come out in Devanagari like the sentences around them, not in a random
    script.
