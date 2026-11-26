# Manual checks: summary quality (#64, part 2)

What the deterministic tests can't reach: Apple Intelligence's live answers on real recorded calls (including background rate-limiting), OpenRouter's live answers with the new cloud prompt, and how the updated summaries read in the Library and Obsidian.

Already verified without a human:
- `MeetingSummaryTests` (pure, fake summarizer): provider-specific prompts (`onDevice` vs `openRouter`, dedicated on-device merge instructions, compact merge parts), fallback overview prompt/parsing and token bounding, missing-overview recovery in `SummaryPipeline` (only one part survived, merge omitted overview, failed merge fell back to combined, zero extra calls when overview is present or summary is empty, `.busy` retry, soft-error preservation, `.unavailable` stop).
- `SummaryQualityFilterTests`: deterministic cross-section and within-section deduplication (`Action items > Decisions > Open questions > Discussion`), speaker-prefixed `"None"` / `"Not specified"` and bare-acknowledgment stripping, per-section and total bounds without aborting a meeting, overview clearing when empty, explicit `YES`/`NO` transcript gate parsing.
- `SummaryQualityFixturesTests`: all 8 synthetic fixtures (including 3-passage chunking under the real 2,000-token on-device limit and hesitation coverage) and the automated structural/bounds/duplicate/noise validator.
- `OpenRouterSummaryTests` (fake transport, fake key store; **no live OpenRouter requests made**): `.openRouter` system, passage, merge, and fallback overview prompts sent unchanged through the existing privacy-routing request shape.
- Live on-device suite (`CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests`): all 8 tests passed on M3 Max / macOS 26.7.2 on 2026-11-26; full before/after outputs and rubric scores are in `plans/summary-quality-64.md`.

## Owner steps — Apple Intelligence (on-device)

1. Run the live fixture suite on your Mac (with Apple Intelligence on):
   ```sh
   CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests
   ```
   Check that all 8 tests pass, `pure-small-talk` returns "Nothing to note was found in this meeting." in under a second, `clean-short` and `tiny` keep decisions and action items cleanly separated, and `long-multi-topic` keeps both the mid-meeting incremental search decision and the late UK May 19 reversal (dropping Canada May 12).
2. **Real short call** (2–5 minutes, with at least one explicit decision, one commitment, and one unresolved question): record, stop, and read the note in the Library. Check:
   - The overview sits directly under `## Summary` in 1–2 concrete sentences naming what was decided or what stays open.
   - Tentative ideas land under **Open questions** rather than **Decisions** or **Action items**.
   - Action items show checkboxes and do not invent `Me:` / `Others:` owners when unclear.
   - Empty sections are omitted; no `"Me: None"` or `"Others: Perfect."` lines appear.
3. **Real stand-up or chatter-heavy call:** confirm greetings, audio checks, and small talk are ignored and a pure small-talk call gets the one-line nothing-found summary.
4. **Long meeting (20+ minutes) in the background:** switch to another app while Cado summarizes. Check Console (`Cado`) for `Summary: wrote a note's summary (…)` and confirm the note has a 1–2 sentence overview (even if a passage was skipped or a merge fell back) and finishes at least as fast as before.
5. **Older three-list note:** open a note saved before #64 in the Library—it renders unchanged. Click **Regenerate Summary**—it rewrites in the Pyramid Brief format and keeps edits outside `<!-- cado:summary --> … <!-- /cado:summary -->`.

## Owner steps — OpenRouter (optional, unmeasured in CI/dev)

OpenRouter prompts were verified only with fakes; no live request was sent during development. If you use OpenRouter with your own API key:

1. Regenerate a short decision meeting and a mixed Hindi/English meeting with your chosen OpenRouter model (e.g. `openai/gpt-4.1-mini`).
2. Check:
   - Same Pyramid Brief headings (`## Summary` overview paragraph, `### Decisions`, `### Action items`, `### Discussion` with `**Topic:**` lead-ins, `### Open questions`), empty sections omitted.
   - Clean English output on mixed Hindi/English transcripts.
   - Later reversals override earlier decisions; tentative suggestions stay in `Open questions`.
   - Action items only carry `Me:` / `Others:` when clear.
   - Attribution line still names the model and OpenRouter.
