# Manual checks: on-device meeting summaries (#34)

What the tests can't reach: the real Apple Intelligence model (its answers,
speed, refusals), a real meeting end to end, and how the note looks in
Obsidian.

Already verified without a human:
- `MeetingSummaryTests` (pure, fake summarizer): the answer format parses
  leniently; transcripts split on turn boundaries and fit the token budget
  (over-long turns cut at sentences, giant words by length); map-reduce
  merges in order and always converges; a refused/failed passage is left out
  and counted; "too long" is halved and retried twice; `unavailable` stops at
  once; a failed merge falls back to joining the parts; the Summary section's
  Markdown, its placement (after notices, before the first turn), idempotent
  replace, edits outside it kept, a missing end marker, front matter kept byte
  for byte; the reading view splits summary from transcript, older notes
  read as before, markers never show.
- `MeetingSummariesTests` (temp notes folder, fake summarizer): the save hook
  hands the note on only after the save returns (so #31's journaling comes
  first) and never for a failed save; summary written in place; regenerate
  idempotent and replacing; off / unavailable leave the note alone; a failed
  summary leaves the file byte for byte; one note at a time; plain messages.
- `LibrarySummaryTests`: the card's states, Regenerate from the reading view,
  the Settings switch (on by default, persisted, explained when unavailable),
  older configs.
- `CADO_RENDER_LIBRARY=<dir> swift test --filter LibraryRenderHarness`
  renders `library-summary*` scenes (summary, offer, working, unavailable).

Not verified: the live model. On the Mac this was built on, Apple
Intelligence was off (`appleIntelligenceNotEnabled`), so
`OnDeviceSummaryLiveTests` skipped.

## Owner steps

1. Turn on Apple Intelligence (System Settings › Apple Intelligence & Siri)
   and wait for its model to finish downloading. (Cado never changes this.)
2. Live model, short: `CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests`.
   It prints the summary of a 9-turn sample meeting and of a 54-turn one
   (several parts, merged). Check: sensible key points, the date change as a
   decision, Sam's and the writer's action items; time taken (expect seconds
   per part).

## In the app

```sh
make package
pkill -x Cado
open dist/Cado.app
```

1. **Settings › Meeting Summaries:** with Apple Intelligence on, the switch is
   on and the line says it runs on this Mac. Turn Apple Intelligence off in
   System Settings, reopen Settings: the switch is off and greyed, and the line
   says to turn it on.
2. **A short meeting** (a minute of talk with decisions and to-dos): stop it.
   The "Meeting note saved" notification comes as before (no wait for the
   summary). Open it in the Library: within a few seconds the Summary card
   appears above "Transcript" by itself.
3. **The file** in Finder / Obsidian: front matter unchanged, then the intro
   line and notices, `## Summary` with `### Key points` / `### Decisions` /
   `### Action items`, the italic attribution, `## Transcript`, then the turns.
   The two `<!-- cado:summary -->` comments don't show in Obsidian's reading
   view.
4. **Regenerate:** click **Regenerate Summary**: "Summarizing…", then the new
   summary replaces the old one; one Summary section in the file. Add a line
   of your own at the end of the note in Obsidian, regenerate: your line stays.
5. **An older note** (saved before this version): opens as before; the card
   says "This meeting has no summary yet." with **Summarize**.
6. **Off:** turn the switch off, record a short meeting: no summary is added;
   **Summarize** in the Library still works.
7. **A long meeting** (20+ minutes, or a long `MeetingReplayTests`-style
   replay): the summary covers the whole meeting; the log (Console, `Cado`)
   has "Summary: wrote … (n passage(s), 0 left out) in x s".
8. **Quit during a summary** (right after "Meeting note saved"): the note is
   intact without a summary; nothing else happens at next launch.
9. **Sensitive topic** (optional): a meeting the model may decline; the note
   is kept as is, and the card says the model declined, or the summary says
   part of the meeting couldn't be summarized.
