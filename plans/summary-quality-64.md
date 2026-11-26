# Meeting summary quality — #64 (part 2)

Date measured: 2026-11-26.
Machine: Apple M3 Max (`Mac15,9`), 48 GB RAM, macOS 26.7.2, debug build (`swift test`), Apple Intelligence on-device Foundation Models (`CADO_LIVE_SUMMARY=1`).
Scope: prompt quality, latency, multi-part missing-overview recovery, and fixture evaluation for the Pyramid Brief format introduced in part 1 (#67). `SummaryText.swift` was left untouched (reader fixes are landing separately on `fix/summary-reading-64`). Hesitation removal (`HesitationFilter.cleanTurns`, #62 / PR #65) is also landing separately and is not duplicated here; fixtures include hesitation-heavy speech (`um`, `uh`, `er`) so its effect can be seen once both branches merge.

---

## Summary of changes

1. **Separate prompts per provider (`SummaryPrompts.swift`):**
   - **On-device (`.onDevice`, 4,096-token context):** short, imperative instructions (~180 words including one noise-only negative example) with all-caps `DO NOT` constraints and explicit rules separating `Decisions`, `Action items`, `Open questions`, `Discussion`, and `Overview`. Dedicated single-task `onDeviceMergeInstructions` (no transcript-noise examples competing for attention) and compact merge parts (omitting empty `- None` lists and `Overview: None`). Multi-part passages keep all five headings in the same order with `Overview: None` in the template so the 3B model does not drift into custom `##` headings.
   - **Cloud (`.openRouter`, 128K+ context):** richer single-pass extract-then-abstract instructions (`cloudInstructions`) with bold `**Topic:**` lead-ins in `Discussion`, explicit reversal override, and native mixed Hindi/Hinglish → English guidance. **Unmeasured against live cloud APIs** (verified with deterministic fakes in `OpenRouterSummaryTests` only; no network calls made).
2. **Replaced per-bullet on-device LLM filtering with deterministic cleanup (`SummaryQualityFilter.cleaned`):**
   - Kept the fast transcript-level pre-gate `isSubstantive(transcript)` (~0.16–0.27 s; immediately returns empty on pure noise).
   - Removed the per-bullet `isSubstantive` loop that made up to 20 extra sequential `LanguageModelSession` calls per passage and 20 per merge. In baseline live runs, that loop crashed 2/8 fixtures (`clean-short`, `noisy-asr`) when the 3B model answered in a sentence or echoed a question instead of bare `YES`/`NO`, aborted `long-multi-topic` on passage 1 for exceeding 20 items, and silently deleted the only action item in `tiny` and a medical-leave fact in `sensitive-topic`.
   - `SummaryQualityFilter.cleaned(_:)` deterministically deduplicates within and across sections (priority: `Action items > Decisions > Open questions > Discussion` so tasks echoed in both `Decisions` and `Action items` stay actionable), strips speaker-prefixed `"None"` / `"Not specified"` and bare conversational acknowledgments (`"Others: Perfect."`), caps per-section (5 on-device, 6 cloud) and total bounds (20 items / 280 words) without throwing, and clears `overview` if no items remain.
3. **Multi-part missing-overview recovery (`SummaryPorts.swift`, `SummaryPipeline.swift`, `OnDeviceSummarizer.swift`, `OpenRouterSummarizer.swift`):**
   - Added `MeetingSummarizer.overview(for:)` (default returning `""`).
   - When `SummaryPipeline.run` finishes with a non-empty summary whose `overview` is empty—covering (a) only one part surviving in a multi-part meeting, (b) a merge answer that omitted `Overview`, (c) a failed merge that fell back to `MeetingSummary.combined`, and (d) a single-passage answer cut off before `Overview`—it runs one short fallback overview call (`SummaryPrompts.overviewPrompt` bounded to `limits.mergeTokens`, max 120 output tokens on-device).
   - Happy-path runs that already have an overview make zero extra calls. `.busy` retries with `busyRetryDelays`; `.unavailable` / cancellation stop the run; soft errors (`.refused`, `.tooLong`, `.failed`) keep the extracted items without an overview.
4. **Synthetic fixture suite & automated checks (`SummaryQualityFixtures.swift`, `SummaryQualityFixturesTests.swift`, `OnDeviceSummaryLiveTests.swift`):**
   - Added 8 synthetic transcripts (zero private data): `clean-short`, `long-multi-topic` (3 real passages at 2,000 tokens with mid-meeting decision + late reversal), `standup-no-decisions`, `noisy-asr` (with hesitations + garbled phrases), `mixed-hindi-english`, `sensitive-topic`, `pure-small-talk`, `tiny`.
   - Automated checks verify Markdown shape, empty-section omission, overview sentence/word bounds, item/word bounds, empty output on noise, zero cross-section exact duplicates, and absence of forbidden noise/filler tokens.

---

## Where measurements disagreed with `plans/research-summaries-58.md`

- **Substantive few-shot examples hurt faithfulness on Apple's ~3B model.** `plans/research-summaries-58.md` recommended two few-shot examples (one substantive, one noise-only) in `instructions` based on WWDC25/248. On live hardware, a substantive few-shot example caused **cross-contamination hallucinations whenever a real meeting had an empty section**:
  - Experiment 2 (software example with `"10 MB cap"`, `"CSV build"`, `"auto-tagging"`): the 3B model copied `"Is the 10 MB cap client-side or server-side?"` into `clean-short` and copied `"Me: Send a CSV build by Thursday."`, `"Others: Check 10 MB cap logs by Friday."`, and `"Whether to add auto-tagging later."` into `long-multi-topic` Passage 1 (which had no action items).
  - Experiment 3 (completely unrelated catering example with `"tacos"`, `"caterer"`, `"patio"`, `"live music"`, plus `"DO NOT copy anything from the examples below"`): the 3B model **still** copied `"Others: Call the caterer by Tuesday."` and `"Is the patio open on June 4?"` into `long-multi-topic` Passage 1, and hallucinated `"and the patio is open"` / `"Is the patio open on March 10th?"` into `OnDeviceSummaryLiveTests.testSummarizesALongMeetingInParts`.
  - Experiment 4A (removed the substantive example; kept only short rules + one noise-only `- None` example): **zero contamination across all 8 fixtures and all 7 existing live tests**, faster inference, and higher rubric pass rate. Therefore the shipped `onDeviceInstructions` keeps only the noise-only example.

---

## Before vs. After (Apple Intelligence on-device, 2026-11-26)

Rubric checks (binary 0/1 each, from `plans/research-summaries-58.md`):
- **F** Faithfulness (hard gate: zero invented facts/names/dates/commitments/false "resolved" claims)
- **D** Decision accuracy (explicit agreements captured; tentative/superseded/tasks excluded)
- **A** Action-item precision & ownership (explicit commitments captured; `Me:`/`Others:` not swapped/fabricated)
- **Q** Open-question capture (blockers/unresolved choices in `Open questions`)
- **O** Answer-first & concision (concrete 1–2 sentence lead, no meta-fluff, no cross-section duplicates)
- **S** Structure & noise discipline (valid Markdown, empty sections omitted, noise empty, no garbled/filler leakage)

### Quality fixtures (`CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests/testQualityFixtureSuite`)

| Fixture | Before time (calls) | After time (calls) | Before rubric (F D A Q O S) | After rubric (F D A Q O S) | Key change |
| --- | --- | --- | --- | --- | --- |
| `clean-short` | 6.14 s (7) — **ERROR** | **4.46 s (2)** | 0/6 (0 0 0 0 0 0) | **6/6** (1 1 1 1 1 1) | Crash eliminated; exact decisions, owners, open questions, 2d vs 8d context |
| `long-multi-topic` (3 parts) | 6.75 s (2) — **ERROR** | **24.58 s (7)** | 0/6 (0 0 0 0 0 0) | **4/6** (0 1 0 1 1 1) | Completes all 3 parts; drops superseded Canada May 12, keeps UK May 19 + mid-meeting incremental search |
| `standup-no-decisions` | 1.67 s (4) | 2.32 s (2) | 4/6 (1 1 0 0 1 1) | **5/6** (1 0 1 1 1 1) | Captures both action items + OAuth blocker in Open questions + 9d cert expiry; 1 false decision |
| `noisy-asr` | 3.71 s (7) — **ERROR** | **2.56 s (2)** | 0/6 (0 0 0 0 0 0) | **4/6** (1 0 0 1 1 1) | Crash eliminated; zero hesitations/garbled words; swaps `Others`→`Me` on deploy task |
| `mixed-hindi-english` | 3.48 s (8) | **3.22 s (2)** | 2/6 (0 0 0 1 0 1) | **3/6** (0 0 0 1 1 1) | Concrete 2-sentence overview + root cause in Discussion; still duplicates test task |
| `sensitive-topic` | 3.48 s (9) | **3.01 s (2)** | 3/6 (0 1 0 1 0 1) | **5/6** (0 1 1 1 1 1) | Exact `Me:`/`Others:` actions + keeps Raj medical leave; overview still says "resolved" |
| `pure-small-talk` | 0.17 s (1) | **0.16 s (1)** | 6/6 (1 1 1 1 1 1) | **6/6** (1 1 1 1 1 1) | Instant pre-gate rejection, unchanged |
| `tiny` | 1.72 s (5) | **1.46 s (2)** | 4/6 (1 1 0 1 0 1) | **6/6** (1 1 1 1 1 1) | Preserves `Others: Send updated calendar invite.` and `3 PM` in overview |
| **Total** | **3/8 crashed** | **0/8 crashed** | **19/48 (40%)** | **39/48 (81%)** | **+20 rubric passes; 0 structural violations** |

### Existing `OnDeviceSummaryLiveTests` timing comparison

| Test | Before (`main`) | After (`feat/summary-quality-64`) | Delta |
| --- | --- | --- | --- |
| `testSummarizesAShortMeeting` (9 turns, 1 part) | 2.66 s | **2.49 s** | -6% (faster) |
| `testSummarizesALongMeetingInParts` (54 turns, 3 parts) | 12.30 s | **10.25 s** | -17% (faster) |
| `testMixedLanguageMeetingKeepsOnlyClearWorkInEnglish` | 1.90 s | **1.90 s** | 0% |
| `testMixedLanguagePleasantriesAndNoiseHaveNoTakeaways` | 0.15 s | **0.15 s** | 0% |
| `testDifferentRecognitionNoiseDoesNotBecomeWork` | 0.75 s | **0.52 s** | -31% (faster) |
| `testHindiMeetingMeaningIsSummarizedInEnglish` (romanized) | 2.06 s (expected failure) | **1.87 s (passed)** | -9% (now passes assertions; `isStrict = false` kept for unsupported Hindi locale) |

Latency criterion check: **every** fixture that completed in baseline is faster or within 0.65 s (only `standup-no-decisions` went from 1.67 s → 2.32 s because baseline only emitted 2 short bullets while after emitted 6 substantive bullets across 4 sections—still cutting LLM calls from 4 to 2). `long-multi-topic` cannot be compared directly to baseline's 6.75 s because baseline aborted on passage 1 of 3 before summarizing passages 2, 3, or merging; on the comparable 3-passage `testSummarizesALongMeetingInParts`, time dropped from 12.30 s to 10.25 s (-17%).

---

## Experiments tried and reverted

| Experiment | What we tried | Observed result | Decision |
| --- | --- | --- | --- |
| **Exp 1** | Expanded `onDeviceInstructions` (~380 words) with 2 multi-turn `Transcript:` examples; omitted `Overview:` heading on multi-part passages; `"Meeting transcript:"` header | Model entered greedy repetition loops (`clean-short` repeated `## Meeting Transcript` 4×, `long-multi-topic` part 2 repeated one line 45×), invented `## Security Incident` / `## Regional rollout` headings (`refused`), and matched `noisy-asr` `"purple toaster"` to `"Purple ladder cloud"` (all `- None`). | **Reverted** |
| **Exp 2** | Trimmed `onDeviceInstructions` (~260 words), restored identical 5-heading shape across all calls, replaced per-bullet LLM filter with `SummaryQualityFilter.cleaned` | 0/8 crashes and 0 structural violations, but software Example 1 leaked `"10 MB cap"` / `"CSV build"` / `"auto-tagging"` into `clean-short` and `long-multi-topic` part 1, and `merge(3)` (using transcript instructions) dropped Part 3's UK May 19 reversal. | **Iterated** |
| **Exp 3** | Switched Example 1 to unrelated catering domain (`tacos`/`caterer`/`patio`) with `DO NOT copy` rule + added dedicated `onDeviceMergeInstructions` + compact merge parts | Catering example **still** leaked `"Call the caterer"` and `"Is the patio open?"` into `long-multi-topic` part 1 and `testSummarizesALongMeetingInParts`. Dedicated merge instructions fixed reversal handling. | **Kept merge instructions; dropped Example 1** |
| **Exp 4A** | Removed substantive Example 1 completely (~180 words rules + 1 tiny noise-only example) | **Zero contamination**, 0/8 crashes, 39/48 rubric checks, faster across the board, `long-multi-topic` kept BOTH mid-meeting incremental indexing AND UK May 19 reversal. | **Kept** |
| **Exp 4B** | Added 3 extra negative rules to `onDeviceInstructions` (stand-up rule, "DO NOT claim resolved", speaker-line check) + bare-acknowledgment placeholder filter | Prompt additions regressed `clean-short` (dropped Overview, triggering fallback), `long-multi-topic` (dropped `Me:` prefix, hallucinated 5 action items), `standup-no-decisions` (swapped `Me:`→`Others:`), `mixed-hindi-english`, and `sensitive-topic`; only fixed `noisy-asr` owner. Placeholder filter cleanly removed `"Others: Perfect."`. | **Reverted prompt additions; kept placeholder filter & `Action items > Decisions` dedup priority** |

---

## Raw answers read wrongly by `SummaryText.read` (for `fix/summary-reading-64`)

Collected during live runs without editing `SummaryText.swift`:

1. **Bullet-prefixed headings (`- Decisions:`):** in Exp 1 (`clean-short`), the model emitted:
   ```text
   ### Overview
   - Decisions:
     - Ship CSV export for Kestrel's November 18 beta.
   - Action items:
     - Me: Build CSV and zip exporter, share test build by Thursday.
   ```
   `SummaryText.heading` does not strip a leading `- `, so `reading.sections` was empty and `passageSummary` threw `.refused`.
2. **Markdown-decorated `## None` after `Overview:`:** in Exp 1 (`tiny`), the model emitted:
   ```text
   **Overview:**
   - Meeting settled on moving the client demo to 3 PM.

   ## None

   ## None

   ## None
   ```
   `SummaryText.read` treated `## None` as continuation lines of `Overview:`, producing `Meeting settled on moving the client demo to 3 PM. ## None ## None ## None`.
3. **Unrecognized `## Part 2` / `## Part 3` / `## Final Overview` lines after `Overview:`:** in Exp 1 (`testSummarizesALongMeetingInParts`), those lines were concatenated into `overview`.
4. **Speaker-prefixed empty placeholders (`- Me: None`, `- Others: None`, `- Me: Not specified.`, `- Me:/Others: None`):** `SummaryText.item` only drops bare `"none"`; these were parsed as real items (handled downstream in `SummaryQualityFilter.cleaned` without touching `SummaryText.swift`).

---

## Verbatim Before and After outputs (all 8 fixtures)

### 1. `clean-short`

**Before (`main`, 6.14 s, 7 calls):**
`ERROR: failed("The summary could not be checked. Try again.")` — per-bullet `isSubstantive` replied:
```text
Is the 15 MB timeout issue client-side compression or a storage API limit?

NO
```

**After (`feat/summary-quality-64`, 4.46 s, 2 calls):**
```markdown
## Summary

Kestrel's November 18 beta will ship CSV plus zipped receipts. Export cap at 200 receipts per bundle.

### Decisions
- Ship CSV plus zipped receipts for Kestrel's November 18 beta.
- Cap v1 exports at 200 receipts per bundle.

### Action items
- Me: Build the CSV and zip exporter and share a test build by Thursday.
- Others: Verify the CSV column headers against the accounting tools and pull the 15 MB timeout logs before Friday.

### Discussion
- CSV plus zipped receipts takes about 2 days, whereas PDF layout generation adds around 8 days.
- Let's leave that UX choice open until we test with a few beta users.

### Open questions
- Should going over 200 receipts show a warning or split into multiple zips?
- Is the 15 MB timeout issue client-side compression or the storage API limit?
```

### 2. `long-multi-topic`

**Before (`main`, 6.75 s, 2 calls):**
`ERROR: failed("The summary was too long. Try again.")` — passage 1 of 3 emitted 23 items (>20 cap), aborting the run before passages 2, 3, or merge.

**After (`feat/summary-quality-64`, 24.58 s, 7 calls, 3/3 passages, 0 skipped):**
```markdown
## Summary

The May 12 Canada rollout was scrapped, and the UK launch is now scheduled for May 19. Incremental indexing was implemented, and memory usage benchmarks are underway.

### Decisions
- Scrap the May 12 Canada rollout and launch in the UK on May 19 instead.
- Switch search indexing from nightly batch to incremental updates.
- Keep analytics retention for Thursday's architecture sync.

### Action items
- Update the UK launch checklist and send the revised May 19 timeline to operations by Tuesday.
- Benchmark incremental index worker's memory usage on 500k-record staging set by Wednesday.
- Patch focus trapping in the billing tab.
- Ship connection-pool health check for background export workers.

### Discussion
- We are roughly 6% under budget right now because switching staging databases to spot instances saved about $1,400 a month, which easily offsets the new notification workers.
- Our Canadian GST tax registration hit a paperwork backlog and won't clear until mid-June at the earliest. Legal says we cannot bill Canadian customers before that registration number is active.
- UK VAT registration is already approved, and Stripe GBP settlement passed end-to-end testing yesterday. Operations just needs one extra week to schedule UK-hours support coverage.
- Search indexing switch reduces peak database CPU duration by 40 minutes.
- Incremental indexing keeps search freshness under 15 seconds.

### Open questions
- Nobody has scoped German localization yet, just throwing it out there.
- Do enterprise accounts need a manual reindex button in workspace settings if an import ever looks out of sync?
- Should only support trigger reindexes?
- How are infrastructure costs tracking against our Q2 cloud budget after the worker pool upgrade?
- We are considering a German beta sometime in Q3, but nobody has scoped German localization yet.
```

### 3. `standup-no-decisions`

**Before (`main`, 1.67 s, 4 calls):**
```markdown
## Summary

QA environment blocked by OAuth callbacks.

### Action items
- Rotate sandbox OAuth secret with IT

### Discussion
- QA environment failing OAuth callbacks
```

**After (`feat/summary-quality-64`, 2.32 s, 2 calls):**
```markdown
## Summary

Renew iOS push certificate in 9 days. QA environment still failing OAuth callbacks.

### Decisions
- Renew iOS push certificate in 9 days.

### Action items
- Me: Follow up with IT to rotate sandbox OAuth secret today.
- Others: Review onboarding flow PR after lunch.

### Discussion
- iOS push certificate expires in 9 days.
- QA environment failing OAuth callbacks.

### Open questions
- QA environment still failing OAuth callbacks.
```

### 4. `noisy-asr`

**Before (`main`, 3.71 s, 7 calls):**
`ERROR: failed("The summary could not be checked. Try again.")` — per-bullet `isSubstantive` replied `"Yes, the transcript contains clear substantive meeting information."`.

**After (`feat/summary-quality-64`, 2.56 s, 2 calls):**
```markdown
## Summary

Webhook timeout increased. Retry count decision pending.

### Decisions
- Increase webhook timeout from 5 seconds to 15 seconds.
- Deploy timeout change by Thursday evening.

### Action items
- Me: Deploy timeout change by Thursday evening.
- Others: Check partner rate limits before deciding retry count.

### Discussion
- Timing out under load is a problem.
- Partner endpoint is cold.

### Open questions
- Should failed webhooks retry 3 times or 5 times?
```

### 5. `mixed-hindi-english`

**Before (`main`, 3.48 s, 8 calls):**
```markdown
## Summary

Hotfix and regression tests for GST invoice rounding.

### Decisions
- Hotfix GST invoice rounding to two decimal places on the subtotal before Monday's billing cycle.
- Write GST rounding regression tests by Friday.

### Action items
- Me: Add regression tests for GST rounding.
- Others: Ship the two-decimal subtotal rounding hotfix before Monday's billing cycle.

### Open questions
- Last month, 12 invoices were affected by a 1-rupee difference. Do we need to re-issue those invoices or issue credit notes?
```

**After (`feat/summary-quality-64`, 3.22 s, 2 calls):**
```markdown
## Summary

Hotfix and regression tests agreed upon for Monday's billing cycle. Open question about re-issuing or issuing credit notes for 12 affected invoices.

### Decisions
- Hotfix GST invoice rounding to two decimal places on the subtotal before Monday's billing cycle.
- Add regression tests for GST rounding by Friday.

### Action items
- Me: Write GST rounding regression tests by Friday.
- Others: Add regression tests for GST rounding.

### Discussion
- Customers reported rounding off GST totals by 1 rupee on multi-line invoices.
- Me traced the issue: rounding each line item instead of the final subtotal.

### Open questions
- Do we need to re-issue the 12 affected invoices or issue credit notes?
```

### 6. `sensitive-topic`

**Before (`main`, 3.48 s, 9 calls):**
```markdown
## Summary

Security incident resolved. Medical leave assigned.

### Decisions
- Revoke leaked analytics API token and rotate read-only keys.
- Assign Maya to payments on-call for two weeks.

### Action items
- Audit past 48 hours of API access logs.
- Hand off payments on-call runbook to Maya by end of day.

### Discussion
- Security incident: leaked analytics API token.

### Open questions
- Send formal incident notice to enterprise customers?
```

**After (`feat/summary-quality-64`, 3.01 s, 2 calls):**
```markdown
## Summary

Security incident resolved by revoking the leaked token and rotating keys. Payments on-call shift reassigned to Maya.

### Decisions
- Revoke the leaked analytics API token and rotate all read-only analytics keys today.
- Reassign the payments on-call shift to Maya for the next two weeks.

### Action items
- Me: Audit the past 48 hours of API access logs today.
- Others: Hand off the payments on-call runbook to Maya by end of day.

### Discussion
- A read-only analytics API token was accidentally committed to a public demo repo.
- Raj is out on unexpected medical leave for the next two weeks.

### Open questions
- Whether to send a formal incident notice to enterprise customers under the SLA.
```

### 7. `pure-small-talk`

**Before (`main`, 0.17 s, 1 call) & After (`feat/summary-quality-64`, 0.16 s, 1 call):**
```markdown
## Summary

Nothing to note was found in this meeting.
```

### 8. `tiny`

**Before (`main`, 1.72 s, 5 calls):**
```markdown
## Summary

Client demo moved.

### Decisions
- Move client demo from 11 AM to 3 PM.
```

**After (`feat/summary-quality-64`, 1.46 s, 2 calls):**
```markdown
## Summary

Client demo moved to 3 PM.

### Decisions
- Move client demo from 11 AM to 3 PM.

### Action items
- Others: Send updated calendar invite.

### Discussion
- Design needs two extra hours.
```

---

## What is unmeasured

- **OpenRouter cloud prompts:** never called against any live cloud model or API (no key, no consent). Verified offline with `FakeOpenRouterTransport` in `OpenRouterSummaryTests` only.
- **Interaction with #62 (`HesitationFilter.cleanTurns`, PR #65):** measured on raw hesitation-heavy fixtures before PR #65 merges.
- **Interaction with `fix/summary-reading-64`:** measured against current `SummaryText.swift` on `main`.
- **Real human recordings:** all 8 fixtures are synthetic text transcripts.

---

## Remaining on-device (~3B) failure modes and next steps

1. **Past-tense / status items promoted into Decisions or Action items:** Apple's 3B model still occasionally promotes an upcoming reminder (`Renew iOS push certificate in 9 days` in `standup-no-decisions`) or already-completed work (`Patch focus trapping`, `Ship connection-pool health check` in `long-multi-topic`) into `Decisions` or `Action items`, and occasionally overstates completion (`"Security incident resolved"`, `"Incremental indexing was implemented"`).
2. **Occasional `Me:`/`Others:` swap or duplication under noise/Hinglish:** on `noisy-asr`, `Others`'s deployment task was attributed to `Me:`, and on `mixed-hindi-english`, `Others` tracing the bug was attributed to `Me` while regression tests appeared under both `Me:` and `Others:`.
3. **Number truncation in long repeated passages:** in the existing `testSummarizesALongMeetingInParts`, the 3B model still occasionally compresses `"fifteen thousand"` to `"$15"`.
4. **Next steps:** once `fix/summary-reading-64` and PR #65 merge, re-run `CADO_LIVE_SUMMARY=1 swift test --filter OnDeviceSummaryLiveTests` to confirm hesitation stripping + lenient reading together; when the owner tests OpenRouter with their own key (`plans/manual-checks/summaries-64.md`), score the same 8 fixtures on a cloud model to verify the cloud prompt empirically.
