# Remove hesitation sounds (#62)

## What was wrong

Turbo (NVIDIA Parakeet v3) transcribes speech verbatim, so spoken hesitation
sounds ("um", "uh") filled dictated text, meeting notes and, through the
transcript, meeting summaries.

## What changed

- **One pure filter (`HesitationFilter`, `Sources/Cado/Transcription/HesitationFilter.swift`)**
  shared by dictation (`TextDelivery`), meetings (`MeetingSession`) and
  summaries (`SummaryPipeline`).
- **Language-aware word rules** so real words are never removed in any language
  Cado transcribes:
  - Unambiguous non-word hesitations (`uh`, `uhh…`, `uhm…`, `umm…`) apply in
    every language without running language detection.
  - Single-`m` `"um"` and `"erm…"` are ambiguous (`"um"` is a real word in
    German, Portuguese, Croatian, Slovenian, Czech, Slovak, Icelandic,
    Luxembourgish, Faroese and Latin) and are removed only when English is
    confirmed for that text: either the supplied language normalizes to `"en"`
    and text-based detection (`NLLanguageRecognizer`, run lazily only when a
    language-dependent candidate token is present and ignoring hesitation
    tokens) agrees (`"en"`) or abstains (too few other words or low confidence),
    or the supplied language is `nil`/`"auto"` and text detection positively
    answers `"en"` (abstaining is not English).
  - German (`äh`, `ähm`, `öh`, `öhm`) and French (`euh`) hesitations follow the
    same confirmation rule for `"de"` and `"fr"` (never `"er"` or `"eu"`).
  - **Known limit:** a one- or two-word utterance in another language with the
    language set to English can still lose `"um"` because text detection
    abstains when too few non-hesitation words are present.
  - Meaning-carrying words and compounds (`uh-huh`, `uh huh`, `uh, huh`,
    `uh-oh`, `uh oh`, `uh-uh`, `uh uh`, `mm-hmm`, `hmm`, `oh`, `ah`, `eh`,
    `huh`, `like`, `you know`), quoted hesitation spans (`"Um," she said.`),
    all-caps acronyms (`UM`, `UH`, `ERM`), measurements (`5 um`) and
    identifiers (`file_um`, `foo-um`, `foo/um`) are preserved.
- **Natural punctuation, spacing and capitalization:** removes parenthetical
  commas and dashes around hesitations without leaving doubled or orphaned
  commas, `:.` / `,.`, or double spaces, preserves structural punctuation
  (`:`, `;`, quotes, leading ellipses like `I think... um... maybe`), carries
  sentence-start capitalization onto the next word (including across dropped
  segments in `HesitationFilter.filter`, while preserving camelCase names like
  `iOS`/`macOS`), and drops hesitation-only passages like non-speech tags. Text
  with no hesitations returns byte-for-byte unchanged.
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
- **Summaries:** `SummaryPipeline.run` always runs `HesitationFilter.cleanTurns`
  once on the turns sent to the summarizer, using each turn's own detected
  language, else the whole note's detected language, else unknown (keeping
  ambiguous tokens when unknown) so short turns like Portuguese `"Um."` ("One.")
  stay while English `"Um."` drops. `MeetingSummaries`'s automatic-summary word
  floor counts raw turns as before, saved transcripts on disk are never
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
3. **Require confirmed English (via lazy `NLLanguageRecognizer` check) for
   `"um"`/`"erm"`, and the same confirmation for `de`/`fr` lists, rather than
   trusting the configured language blindly or using a blocklist.** `"um"` is a
   real lexical word in at least ten languages supported by Parakeet and
   Whisper (including `de`, `pt`, `hr`, `sl`, `cs`, `sk`, `is`), and engines
   like Turbo (Parakeet) and Apple Speech hand down the configured language
   (default `"en"`) even when the user speaks another language. Requiring text
   detection not to contradict `"en"` (and to positively confirm `"en"` when
   language is `nil`/`"auto"`) protects non-English sentences without slowing
   down hesitation-free text. Known limit: a one- or two-word utterance in
   another language with Language set to English can still lose `"um"`.
4. **Drop both commas around `, um,` rather than keeping one.** Speech models
   wrap mid-clause hesitations in parenthetical commas (`"We should, um, ship
   it."`); keeping one comma leaves an awkward orphaned comma (`"We should, ship
   it."`).
5. **Place the single Settings switch on the Speech Model tab under a
   Transcript section.** The setting applies equally to dictation and meetings,
   and Speech Model is where shared speech-to-text settings live.
