# Remove hesitation sounds (#62)

## What was wrong

Turbo (NVIDIA Parakeet v3) transcribes speech verbatim, so spoken hesitation
sounds ("um", "uh") filled dictated text, meeting notes and, through the
transcript, meeting summaries.

## What changed

- **One pure filter (`HesitationFilter`, `Sources/Cado/Transcription/HesitationFilter.swift`)**
  shared by dictation (`TextDelivery`), meetings (`MeetingSession`) and
  summaries (`SummaryPipeline` / `MeetingSummaries`).
- **Language-aware word rules** so real words are never removed in any language
  Cado transcribes:
  - Unambiguous non-word hesitations (`uh`, `uhh…`, `uhm…`, `umm…`) apply in
    every language.
  - Single-`m` `"um"` and `"erm…"` apply only in English (`"en"`): `"um"` is a
    real word in German, Portuguese, Croatian, Slovenian, Czech, Slovak,
    Icelandic, Luxembourgish, Faroese and Latin.
  - German (`äh`, `ähm`, `öh`, `öhm`) and French (`euh`) hesitations apply in
    their own languages (never `"er"` or `"eu"`).
  - Meaning-carrying words and compounds (`uh-huh`, `uh huh`, `uh-oh`, `uh oh`,
    `uh-uh`, `uh uh`, `mm-hmm`, `hmm`, `oh`, `ah`, `eh`, `huh`, `like`,
    `you know`), all-caps acronyms (`UM`, `UH`, `ERM`), measurements (`5 um`)
    and identifiers (`file_um`, `foo-um`, `foo/um`) are preserved.
- **Natural punctuation, spacing and capitalization:** removes parenthetical
  commas and dashes around hesitations without leaving doubled or orphaned
  commas or double spaces, preserves structural punctuation (`:`, `;`, quotes),
  carries sentence-start capitalization onto the next word (including across
  dropped segments in `HesitationFilter.filter`, while preserving camelCase
  names like `iOS`/`macOS`), and drops hesitation-only passages like non-speech
  tags. Text with no hesitations returns byte-for-byte unchanged.
- **One switch, on by default:** `Config.removeHesitations` (default `true`;
  missing in older configs decodes as `true`), shown in **Settings › Speech
  Model › Transcript › Remove hesitation sounds**. Turning it off skips
  `HesitationFilter` entirely on dictation and meetings (byte-for-byte
  identical output to before #62).
- **Spools and recovery:** each new meeting records `removeHesitations` in
  `SpooledMeeting` (`meeting.json`, optional for backward compatibility), and
  `MeetingSession.recordResult` filters each passage's segments right beside
  `NonSpeechFilter.filter` using the passage's detected language (or the
  meeting's fixed language). A recovered meeting therefore gets the exact same
  text as a live one, even if the setting changed before relaunch, and
  `RecoveryPlan.isWholeNote` stays consistent with journaled segments. Pre-#62
  spools (missing `removeHesitations`) decode as `nil` and recover verbatim as
  recorded.
- **Summaries:** `SummaryPipeline.run` (and `MeetingSummaries`'s automatic word
  floor) always runs `HesitationFilter.cleanTurns` on the turns sent to the
  summarizer, detecting the note's language via `NLLanguageRecognizer` (and per
  turn for mixed-language notes) so short turns like Portuguese `"Um."` ("One.")
  stay while English `"Um."` drops. Saved transcripts on disk are never
  rewritten, and `writeSection` still checks edits against the raw turns read
  from disk.

## Key decisions and rejected alternatives

1. **Filter at `TextDelivery` + `MeetingSession` + `SummaryPipeline`, not inside
   engine adapters.** Engine adapters stay pure (so `--bench` continues to score
   raw engine WER, and the user's live switch can disable filtering cleanly
   without reloading models).
2. **Filter in `MeetingSession.recordResult` rather than `MeetingTranscript.turns`.**
   `recordResult` still has per-passage `Transcript.language` (from Whisper /
   WhisperKit auto-detect), runs before `SpeakerBleedFilter` (preventing
   hesitation differences between Me and Others from breaking bleed alignment),
   and journals the same text written to the note (keeping
   `RecoveryPlan.isWholeNote` exact).
3. **Allowlist `"um"` to English (with `NLLanguageRecognizer` fallback when
   language is unknown) instead of a blocklist.** `"um"` is a real lexical word
   in at least ten languages supported by Parakeet and Whisper (including `de`,
   `pt`, `hr`, `sl`, `cs`, `sk`, `is`); allowlisting English is strictly safer
   and avoids missing smaller languages.
4. **Drop both commas around `, um,` rather than keeping one.** Speech models
   wrap mid-clause hesitations in parenthetical commas (`"We should, um, ship
   it."`); keeping one comma leaves an awkward orphaned comma (`"We should, ship
   it."`).
5. **Place the single Settings switch on the Speech Model tab under a
   Transcript section.** The setting applies equally to dictation and meetings,
   and Speech Model is where shared speech-to-text settings live.
