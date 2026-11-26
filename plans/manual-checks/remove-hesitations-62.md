# Manual checks: remove hesitation sounds (#62)

What the unit tests can't reach: real voices with Turbo, Whisper, WhisperKit and
Apple Speech, Settings layout in light/dark mode, and real on-device/OpenRouter
summaries on an older meeting note. Design notes: `plans/remove-hesitations-62.md`.

Already verified without a human:
- `HesitationFilterTests`: English and multilingual hesitation removal,
  punctuation/spacing/capitalization tidying, cross-segment capitalization,
  meaningful words (`uh-huh`, `uh huh`, `uh-oh`, `mm-hmm`, `like`, `you know`),
  acronyms (`UM`, `UH`, `ERM`), measurements (`5 um`), real words in German,
  Portuguese, French, Dutch, Nordic and Slavic languages, summary turn cleaning,
  and idempotency.
- `ConfigTests` / `SettingsViewModelTests` / `UserFacingCopyTests`:
  `removeHesitations` defaults on, older configs decode as on, Settings toggle
  persists, copy is plain.
- `TextDeliveryTests` / `DictationSessionTests` / `DictationAdaptersTests`:
  dictation cleans hesitations by default, drops hesitation-only dictations
  without touching the clipboard or history, passes detected/model language,
  and stays verbatim when off.
- `MeetingHesitationTests`: live meetings, hesitation-only meetings, switch off,
  German/Portuguese/auto-detect meetings, `meeting.json` spool round-trip and
  older spool compatibility, and crash recovery matching live output even after
  flipping the switch.
- `MeetingSummaryTests` / `MeetingSummariesTests`: summaries never see
  hesitations (including older notes whose saved transcripts stay untouched on
  disk), and the automatic-summary word floor ignores hesitations.

## Setup

```sh
make package
pkill -x Cado
open dist/Cado.app
```

## Checks

1. **Settings UI.** Open **Settings › Speech Model**. Confirm the **Transcript**
   section appears below the model card in both light and dark mode with
   **Remove hesitation sounds** switched **on** by default and its plain-English
   description visible without truncation.
2. **Dictation on Turbo (default on).** Focus a text field and dictate:
   *"Um, we should, uh, ship the release on Friday."*
   Expected: pastes `We should ship the release on Friday.` — no `um`/`uh`,
   no double spaces, no orphaned commas, capitalized `We`.
3. **Hesitation-only dictation.** Dictate only *"Um... uh."*
   Expected: nothing is pasted or copied, clipboard is untouched, no entry is
   added to Recent Dictations.
4. **Meaningful words stay.** Dictate:
   *"Uh-huh, I was like, you know, surprised, mm-hmm."*
   Expected: `Uh-huh`, `like`, `you know`, `mm-hmm` all stay.
5. **Switch off = verbatim.** Turn off **Remove hesitation sounds** in
   Settings › Speech Model and repeat check 2.
   Expected: `Um` and `uh` appear verbatim as before #62. Turn the switch back
   on afterwards.
6. **Multilingual safety.** Switch Speech Model › Language to **German** (or
   **Portuguese**) and dictate *"Wir treffen uns um 14 Uhr."* (or *"Preciso de
   um minuto."*).
   Expected: `"um"` is preserved verbatim; German `"ähm"` (if spoken) is
   removed.
7. **Meeting transcript & crash recovery.** Record a short English meeting with
   deliberate *"um"* / *"uh"* fillers and one hesitation-only turn.
   - Live meeting: the saved Markdown note has cleaned turns and drops the
     hesitation-only turn.
   - Crash recovery: start a second meeting, speak with *"um"* / *"uh"*, Force
     Quit Cado mid-meeting, toggle **Remove hesitation sounds** off in
     `config.json`, then relaunch. Expected: the recovered note still cleans
     the meeting's remaining passages (matching the setting recorded when the
     meeting started).
8. **Summaries on an older note.** Open a meeting note saved before #62 whose
   transcript contains *"um"* / *"uh"* (or create one with the switch off), and
   click **Regenerate Summary** (or **Summarize**) in the Library.
   Expected: the summary reads cleanly without hesitations, and the saved
   transcript below `## Transcript` on disk is byte-for-byte unchanged.
