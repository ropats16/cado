# Research: default meeting summary format and prompting (#58)

Date accessed: 2026-11-26. Scope: default summary format and prompting for Cado (custom templates and transcript chat in #58 are out of scope).
Evidence tags: **(documented)** = primary source verified directly; **(reported)** = user posts, reviews, or secondary write-ups; **(inferred)** = reasoning from sources and Cado's code (`SummaryPrompts.swift`, `SummaryPipeline.swift`, `SummaryText.swift`, `SummarySection.swift`, `OnDeviceSummarizer.swift`, `OpenRouterSummarizer.swift`, `LibrarySummaryView.swift`, `NoteReading.swift`).
Unverified / unreachable sources: `mckinsey.com` and `support.zoom.com` timed out; `tldv.io` help pages timed out or 404'd; Reddit was not readable; `help.otter.ai` returned HTTP 403 on full-body reads after an initial summary fetch; Barbara Minto's book text and Granola's internal prompts are not public. Claims touching those are marked accordingly.

---

## Bottom line
- Replace the flat three-list placeholder with a **Pyramid Brief**: a 1–2 sentence answer-first lead directly under `## Summary`, then four fixed MECE sections omitted when empty: `### Decisions`, `### Action items`, `### Discussion` (topic-led bullets, not generic narrative), and `### Open questions`.
- Adding `### Open questions` is the cheapest way to stop small models from promoting tentative remarks or unresolved blockers into fake decisions or invented action items **(inferred)**.
- Older three-list notes stay compatible with zero migration: `NoteReading` and `LibrarySummaryView` already render arbitrary Markdown blocks between `<!-- cado:summary -->` markers, including lead paragraphs, nested bullets, and checkboxes under `Action items` **(documented, code)**.
- Highest-leverage quality changes for Apple's 3B / 4K-context model: (1) cut `SummaryPrompts.instructions` to a short, single-task command with `DO NOT` rules and 2 concise few-shot examples (substantive + noise-only); (2) extract lists first and write the answer-first lead *last* on the final merge (then render it first); (3) separate on-device prompts from cloud prompts so `gpt-4.1-mini` runs single-pass extract-then-abstract with bold topic lead-ins instead of 4K chunking.
- Build a small fixture suite (8–10 synthetic transcripts) with automated structural/negative checks plus binary pass/fail faithfulness grading before changing prompts.

---

## 1. Consulting-style synthesis (Minto, SCQA, MECE, action titles)

- **Pyramid Principle (Barbara Minto):** Present ideas top-down under a single governing point, even though analysis happens bottom-up ([barbaraminto.com](https://barbaraminto.com/), **documented**). Three structural rules commonly attributed to Minto's book (*book not read directly; McKinsey explainer timed out*): (1) any level summarizes the ideas grouped beneath it; (2) items in a group are logically the same kind; (3) items in a group follow one logical order—time, structure, or importance **(reported)**.
- **SCQA / SCQ framing:** Minto's Situation, Complication, Question (→ Answer) framework identifies the reader's core question before giving the answer ([barbaraminto.com](https://barbaraminto.com/), **documented**).
- **MECE & "So what?":** Categories should be Mutually Exclusive (no double-counting) and Collectively Exhaustive (no gaps); the "so what?" test pushes raw observations ("latency is 4s") into implications ("checkout times out for 3% of users") **(reported; McKinsey pages timed out)**.
- **Action titles:** Replace passive topic labels ("Q3 Export") with declarative assertions stating the takeaway ("CSV export ships Dec 10; PDF moves to v2") **(reported)**.

**What transfers to meeting transcripts — and what breaks (inferred):**
- **Transfers well:** *Answer-first* (1–2 sentence lead stating what changed or was settled), *MECE buckets* (Decisions ≠ Action items ≠ Discussion ≠ Open questions—no overlap), and *"so what?" bullets* (lead with the conclusion/trade-off, not "We talked about X").
- **Transfers poorly as a rigid default:** Full *SCQA* and *action-title subheadings* assume every meeting has one thesis and clean evidence. Stand-ups, brainstorming calls, and noisy ASR transcripts often have several small updates and no single conclusion; forcing SCQA on a small model invites invented narrative arcs.

**Concrete consulting-adapted template for meetings (inferred):**
```markdown
## Summary
<1–2 sentence governing takeaway: meeting goal + main outcome or blocker.>

### Decisions
- <Explicit choice made, plus stated reason if any>

### Action items
- <Commitment> (owner/deadline only if explicitly stated)

### Discussion
- **<Topic or assertion>:** <Substance, numbers, or trade-off—not "discussed X">

### Open questions
- <Unresolved question, blocker, or deferred choice>
```

---

## 2. Granola: default notes, templates, recipes, and user feedback

- **Inputs and human-in-the-loop merge:** Granola combines four inputs: transcript, private notes typed during the call, calendar metadata, and the user's profile ([ai-enhanced-notes.md](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes.md), **documented**). Points tied to the user's own notes stay highlighted in black while AI-added context is gray; headings and bullets typed by the user guide the final structure ([taking-notes-in-granola.md](https://docs.granola.ai/help-center/taking-notes/taking-notes-in-granola.md), **documented**). If the user types nothing, Granola still generates notes from the transcript and calendar info (**documented**).
- **Traceability:** Hovering any summary line reveals a magnifying glass showing matching transcript quotes that jump to that spot in the transcript ([ai-enhanced-notes.md](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes.md), **documented**).
- **Models:** Granola uses a blend of OpenAI and Anthropic cloud models ([ai-enhanced-notes.md](https://docs.granola.ai/help-center/taking-notes/ai-enhanced-notes.md), **documented**).
- **Templates vs. Recipes:** **Templates** shape the initial note structure for recurring meeting types (1:1s, interviews, stand-ups, sales) via four documented ingredients: purpose/context, length/style, named sections with per-section sub-prompts, and iteration ([customise-notes-with-templates.md](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates.md), **documented**). **Recipes** are saved post-meeting chat prompts run on one or many meetings (e.g., follow-up emails, bug reports, cross-call patterns) ([recipes blog](https://www.granola.ai/blog/say-hello-to-recipes), [writing-effective-recipes.md](https://docs.granola.ai/help-center/getting-more-from-your-notes/writing-effective-recipes.md), **documented**).
- **What default ("Auto") notes actually look like:** Granola's docs say default summarization "adapts to most meetings" without publishing its exact prompt ([customise-notes-with-templates.md](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates.md), **documented**). Inspecting a live public shared Granola note ([notes.granola.ai](https://notes.granola.ai/d/2c35c84f-6eb4-497a-8419-294d92141721), linked from [HN 48256570](https://news.ycombinator.com/item?id=48256570), **documented** for that note; generalizing to all calls is **inferred**) shows:
  - Dynamic `### Topic` headings (5–7 for a long interview), no emojis, and no boilerplate prose intro.
  - Terse, telegraphic, fragment-style bullets nested 2 levels deep (top bullet = claim/event; sub-bullets = numbers, context, or short verbatim quotes in quotation marks).
  - Readable in ~1 minute (~200–450 words) and omits sections that do not fit the call (e.g., no forced empty Action Items on an interview). Work-meeting templates add explicit *Decisions made* and *Action items* sections ([customise-notes-with-templates.md](https://docs.granola.ai/help-center/taking-notes/customise-notes-with-templates.md), **documented**).
- **User praise:** Sticky simplicity ("guaranteed a good summary", [HN 50458114](https://news.ycombinator.com/item?id=50458114), **reported**), fast 1-minute scannability ([HN 48256570](https://news.ycombinator.com/item?id=48256570), **reported**), bot-free capture, and manual notes anchoring what matters (**reported**).
- **User complaints:** Summaries can look polished on the surface yet "miss important things, overemphasize the wrong things… if you actually scrutinize them they fall apart" ([HN 47061601](https://news.ycombinator.com/item?id=47061601), **reported**); privacy/cloud reliance and default org-wide folder sharing ([HN 44736878](https://news.ycombinator.com/item?id=44736878), **reported**); no Markdown/Obsidian export (`plans/research-competitors.md`, **documented**).
- **Takeaway for Cado (inferred):** Cado lacks live user-typed notes and calendar context today, so it cannot copy Granola's human-anchor trick yet—but it *can* adopt Granola's telegraphic, low-fluff bullet style, concrete numbers, and strict omission of empty sections.

---

## 3. Other meeting-summary tools

| Tool | Default summary structure (1–2 lines) | What reviews say works / fails |
|---|---|---|
| **Otter** | Overview, Action Items, Outline (timestamped chapters), Insights ([Otter Help](https://help.otter.ai/hc/en-us/articles/31402572907415-Custom-Meeting-Type-Templates), **documented** via title/nav; full body 403). | Fast live transcript and keyword/outline navigation ([HN 30152943](https://news.ycombinator.com/item?id=30152943), **reported**); criticized for intrusive meeting bots and rigid paywalls (**reported**). |
| **Fireflies** | General Summary: Meeting Keywords, Meeting Overview, Meeting Notes (thematic bullets), Action Items ([Fireflies KB](https://guide.fireflies.ai/articles/9547055509-Fireflies-AI-Meeting-Summaries%3A-View%2C-Customise%2C-Expand%2C-Regenerate), **documented**). | Strong customization and length toggle (**documented**); cluttered UI, credit-gated AI prompts, and generic defaults without tuning (**reported**). |
| **Fathom** | Summary narrative, grouped discussion points, Action Items linked to call clips; add-on instructions customizable ([Fathom Help](https://help.fathom.video/en/articles/3239809), **documented** for customization; exact default headings **reported**). | Clean CRM sync and generous free tier (**reported**); narrower template flexibility on lower plans (**reported**). |
| **tl;dv** | Short summary, timestamped topic chapters, Action Items (**reported**; vendor help pages timed out/404). | Strong multi-language support and clip reels (**reported**); default notes feel generic without custom prompts and can stumble on jargon (**reported**). |
| **Notion AI** | Auto summary of key points and checkbox action items inside a Notion page; merges pre-written user Notes; requires ≥1 min audio ([Notion Help](https://www.notion.com/help/ai-meeting-notes), **documented**). | Fits wiki/project workflows cleanly (**reported**); locked into Notion Business/Enterprise plans (**documented**). |
| **Zoom AI Companion** | Structured recap covering decisions made, owned action items, next steps, and topic summaries; customizable templates ([Zoom](https://www.zoom.com/en/products/ai-assistant/features/ai-note-taking/features/ai-meeting-summary/), **documented**; KB timed out). | Zero-friction, bot-free, "works very well" in-workflow ([HN 39621315](https://news.ycombinator.com/item?id=39621315), **reported**); walled-garden lock-in and risky default auto-email sharing (**reported**). |
| **Google Meet (Gemini)** | Google Doc with Summary, Decisions (with status: aligned / needs discussion / shelved), Next steps, Details; standard vs. longer toggle ([Meet Help](https://support.google.com/meet/answer/14754931), [Workspace blog 2026-04](https://workspaceupdates.googleblog.com/2026/04/new-ways-to-customize-ai-generated-meeting-notes.html), **documented**). | Living editable Doc and explicit decision-status tracking (**documented**); one spoken language per call only (**documented**), Drive clutter, and sharing surprises (**reported**). |
| **Microsoft Copilot / Teams** | AI notes (overview + topic chapters), follow-up tasks, and personalized timeline markers (name mentions, screen share) for meetings >5 min ([Teams Support](https://support.microsoft.com/en-us/teams/meetings/recap-in-microsoft-teams), **documented**). | Deep M365 context and hierarchical minutes + highlights backed by Microsoft's own user study ([arXiv:2307.15793](https://arxiv.org/abs/2307.15793), **documented**); pricey add-on and corporate/rigid tone (**reported**). |

**Cross-tool pattern (inferred):** Nearly every successful default converges on **short overview + topic/discussion bullets + explicit decisions + action items**, with Google Meet's 2026 update notably adding decision *status* (aligned vs. needs discussion) to stop tentative talk from looking settled ([Workspace blog 2026-04](https://workspaceupdates.googleblog.com/2026/04/new-ways-to-customize-ai-generated-meeting-notes.html), **documented**). Across all tools, the recurring review complaints (aggregated from HN threads such as [HN 47061601](https://news.ycombinator.com/item?id=47061601), [HN 48454349](https://news.ycombinator.com/item?id=48454349), and web-search review roundups; Reddit threads not directly verified) are **over-inference** (turning tentative ideas into commitments, wrong owners) and **"Day-30 bloat"** (long summaries nobody reads) (**reported**).

---

## 4. Research and practitioner evidence on LLM meeting summarization

- **Map-reduce / hierarchical merging vs. refine (incremental updating):**
  - *BooookScore* (Chang et al., 2023, [arXiv:2310.00785](https://arxiv.org/abs/2310.00785), **documented**) compared **hierarchical merging** (Cado's current map-reduce tree) against **incremental updating** (refine) over 100 long texts with 1,193 human annotations. Hierarchical merging scored higher on global coherence (fewer contradictions and abrupt transitions), while incremental updating kept more detail at the cost of coherence and error propagation (**documented**). For Cado's 4K small model, keeping hierarchical map-reduce is right: refine chains drift and compound small-model hallucinations across chunks (**inferred**).
- **Topic segmentation & locate-then-summarize:**
  - *QMSum* (Zhong et al., 2021, [arXiv:2104.05938](https://arxiv.org/abs/2104.05938), **documented**), *MeetingBank* (Hu et al., 2023, [arXiv:2305.17529](https://arxiv.org/abs/2305.17529), **documented**), and *AMI* ([AMI Corpus](https://groups.inf.ed.ac.uk/ami/corpus/), **documented**) establish that long multi-topic meetings resist naive single-pass compression; divide-and-conquer segment alignment (*MeetingBank*) and topic-based segmentation before parallel action-driven summarization (*Golia & Kalita*, 2023, [arXiv:2312.17581](https://arxiv.org/abs/2312.17581), **documented**) reduce lost long-term dependencies.
- **Extract-then-abstract & fact-based enrichment:**
  - *Re-FRAME* (Kirstein et al., 2025, [arXiv:2509.15901](https://arxiv.org/abs/2509.15901), **documented**) separates salient-fact extraction and thematic grouping from abstractive writing, cutting hallucination and omission by 2/5 points on QMSum/FAME compared with prompt-only baselines (**documented**). Anthropic's engineering guidance similarly recommends chaining extraction → synthesis over monolithic prompts when tasks fail ([Building effective agents](https://www.anthropic.com/research/building-effective-agents), **documented**).
- **Chain of Density (CoD):**
  - Adams et al. (2023, [arXiv:2309.04269](https://arxiv.org/abs/2309.04269), **documented**) iteratively pack missing salient entities into a fixed-length GPT-4 summary; humans preferred denser, less lead-biased summaries up to a readability/faithfulness inflection point (**documented**). Applying 5-step CoD to noisy meetings or a 3B model is dangerous: length pressure triggers over-compression and fabricated links (**inferred**). Use CoD's *lesson* (prefer concrete entities/numbers over meta-prose like "The team discussed…"), not its 5-pass loop.
- **Position bias ("Lost in the Middle"):**
  - Liu et al. (2023, [arXiv:2307.03172](https://arxiv.org/abs/2307.03172), **documented**) showed U-shaped recall across long contexts: models attend best to the beginning and end and drop middle details—directly explaining why long-meeting decisions made mid-call vanish in naive single-pass summaries (**inferred**).
- **Grounding & human-in-the-loop editing:**
  - Microsoft's workplace recap study (Asthana et al., 2023, [arXiv:2307.15793](https://arxiv.org/abs/2307.15793), **documented**) found users value *both* quick highlights and hierarchical minutes, and frequently edit misattributed owners. Grounding extracted items in source utterances/quotes (as in Granola's hover-quotes and Re-FRAME's fact extraction) lets models and users verify claims (**documented / inferred**).
- **Known meeting failure modes & mitigations (documented / inferred):**
  1. *Invented action items:* Mitigate by giving tentative ideas a dedicated `Open questions` bucket and requiring an explicit commitment verb.
  2. *Wrong owners:* Never force an owner field when diarization is absent (`Me`/`Others`); omit owner unless unambiguous.
  3. *Lost or superseded decisions:* Keep chunk order in `mergePrompt` and explicitly tell the merge step that later decisions override earlier discussion.
  4. *ASR noise turned into fiction:* Pre-gate noise chunks (Cado's `isSubstantive` + deterministic length/filler check) and show a concrete noise-only negative example.

---

## 5. Prompting small on-device models (~3B, 4K context)

Apple's Foundation Models documentation ([TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window), [Prompting guide](https://developer.apple.com/documentation/foundationmodels/prompting-an-on-device-foundation-model), [WWDC25/248](https://developer.apple.com/videos/play/wwdc2025/248/), [WWDC25/286](https://developer.apple.com/videos/play/wwdc2025/286/), **documented**) specifies a ~3B-parameter model with a hard 4,096-token session budget (~3–4 chars/token English, ~1 char/token CJK).

- **What helps (documented in Apple docs & WWDC25/248, /286):**
  - **Short, direct commands (1–3 paragraphs max)** with imperative verbs ("Extract", "List") and a single focused goal per call.
  - **Break complex tasks into sequential calls** instead of packing classification, extraction, deduplication, and prose synthesis into one prompt.
  - **Fewer than 5 short few-shot examples** written directly in the prompt to lock in shape and negative behavior (OpenAI's [prompt engineering guide](https://developers.openai.com/api/docs/guides/prompt-engineering), Anthropic's [prompt engineering overview](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/overview), and Google's [prompting strategies](https://aistudio.google.com/docs/prompting-strategies) agree, **documented**).
  - **All-caps `DO NOT` constraints** for recurring unwanted outputs, plus **explicit quantitative length phrases** ("in two sentences", "at most 4 bullets").
  - **Generate summaries *after* details:** WWDC25/286 notes the on-device model produces better summaries when the summary field comes *last* rather than first (**documented**).
  - **Instructions vs. prompt:** Put stable rules/safety in `instructions` (which take precedence over user/transcript input) and keep each session fresh so tokens never accumulate (**documented**).
- **What hurts (documented / inferred):**
  - Long, multi-rule instruction blocks (Cado's current `SummaryPrompts.instructions` is ~245 words with ~10 simultaneous rules—right at the edge where 3B models drop middle constraints, **inferred**).
  - Asking for open-ended heading invention across map-reduce chunks, passive voice, hedging, or world-knowledge inference (**documented**).
  - Relying on `.permissiveContentTransformations` with `@Generable` (triggers stricter guardrails in Cado, `OnDeviceSummarizer.swift`, **documented**).

---

## 6. Evaluating summary quality cheaply and repeatably

- **Why ROUGE fails:** *SummEval* (Fabbri et al., 2020, [arXiv:2007.12626](https://arxiv.org/abs/2007.12626), **documented**) and *G-Eval* (Liu et al., 2023, [arXiv:2303.16634](https://arxiv.org/abs/2303.16634), **documented**) show n-gram overlap correlates poorly with human judgment; G-Eval uses a rubric + chain-of-thought LLM judge (Spearman 0.514 on summarization, **documented**), while *FActScore* (Min et al., 2023, [arXiv:2305.14251](https://arxiv.org/abs/2305.14251), **documented**) checks atomic claims against source text.
- **Practitioner consensus for small teams:** Eugene Yan ([LLM-Evaluators](https://eugeneyan.com/writing/llm-evaluators), **documented**), Hamel Husain ([Your AI Product Needs Evals](https://hamel.dev/blog/posts/evals/), **documented**), Anthropic ([Demystifying evals](https://www.anthropic.com/research/demystifying-evals-for-ai-agents), **documented**), and Apple ([WWDC25/248](https://developer.apple.com/videos/play/wwdc2025/248/), **documented**) converge on a 3-layer loop: (1) deterministic unit assertions (format, bounds, negative-case emptiness); (2) manually inspect a small curated fixture set first; (3) use binary **Pass/Fail** rubrics (easier to calibrate than 1–5 scales) with an LLM judge only after validating it against your own labels.

---

## Candidate default formats (same imaginary 30-minute product meeting)

**Scenario (invented):** 30-minute call for a fictional expense app *Pebble* ahead of a Dec 10 beta. Speakers are `Me` (engineering) and `Others` (two colleagues in product/design, unseparated). They decide to ship CSV + zipped receipts instead of PDF (PDF adds ~8 days) and cap exports at 200 receipts for v1. An existing timeout affects receipts >15 MB (~3% of test accounts); someone in `Others` floats an auto-resizer, but nobody commits. Two open questions remain (how to handle >200-receipt UX; whether the 15 MB timeout is client-side or storage API). `Me` commits to a CSV/zip test build by Thursday; `Others` commits to verifying CSV headers against accounting tools and pulling timeout logs before Friday.

### Candidate A: Pyramid Brief (answer-first + 4 fixed MECE sections)

```markdown
## Summary

Pebble will ship CSV + zipped receipt export for the Dec 10 beta and defer PDF export to v2; a 15 MB upload timeout and the 200-receipt cap UX remain unresolved.

### Decisions
- Ship CSV + zipped receipts for the Dec 10 beta; defer PDF export to v2 to avoid an ~8-day layout delay.
- Cap v1 exports at 200 receipts per bundle to prevent memory spikes on older Macs.

### Action items
- Me: Build the CSV + zip exporter and share a test build by Thursday.
- Others: Confirm accounting tools accept the proposed CSV column headers and check the 15 MB timeout logs before Friday's check-in.

### Discussion
- **Export format:** CSV + zip takes ~2 days vs. ~8 extra days for PDF generation; chosen to protect the Dec 10 beta date.
- **15 MB upload timeout:** Affects ~3% of test accounts; auto-resizing images was floated as an idea but not agreed.

### Open questions
- Should exports over 200 receipts show a warning or split into multiple zips?
- Is the 15 MB timeout caused by client-side compression or the storage API limit?
```

### Candidate B: Granola-style topic notes (adaptive H3 headings + nested telegraphic bullets)

```markdown
## Summary

### Dec 10 Beta Export Scope
- Chose CSV + zipped receipts for v1 (~2 days work) over PDF (~8 extra days)
  - PDF export deferred to v2
- Export cap set at 200 receipts per bundle
  - Protects older Macs from memory spikes
  - UX for >200 receipts still undecided (warn vs. multi-zip split)

### 15 MB Upload Timeout
- Affects ~3% of test accounts on large receipts
- Root cause still unknown (client-side compression vs. storage API limit)
- Auto image resizer floated during call; no commitment made

### Action items
- Me: Implement CSV + zip exporter and share test build by Thursday
- Others: Verify CSV headers with accounting tools and pull timeout logs before Friday
```

### Candidate C: Consulting SCQA + Action-Title Memo

```markdown
## Summary

### Bottom line
To hit the Dec 10 beta without memory regressions, Pebble will ship a 200-receipt capped CSV + zip exporter now and leave PDF export for v2, while investigating a 15 MB upload timeout affecting 3% of test accounts.

### Key findings

#### Shipping CSV + zip first is the only path to the Dec 10 beta
- PDF layout generation adds ~8 days against a two-week runway; CSV + zip takes ~2 days.
- Capping exports at 200 receipts avoids memory spikes on older Macs; multi-zip vs. warning UX is still open.

#### The 15 MB upload timeout needs root-cause logs before picking a fix
- Roughly 3% of test accounts hit timeouts on large receipts; client compression vs. storage API limit is unconfirmed.
- An automatic image resizer was suggested but not approved.

### Decisions
- Ship CSV + zip capped at 200 receipts for Dec 10; defer PDF to v2.

### Action items
- Me: Share a CSV + zip test build by Thursday.
- Others: Validate CSV columns for accounting imports and inspect 15 MB timeout logs before Friday.
```

### Trade-offs against Cado's constraints (inferred)

| Criterion | A: Pyramid Brief | B: Granola-style topics | C: Consulting SCQA memo |
|---|---|---|---|
| **4K small model (3B)** | **Best:** fixed 4 headings + 1-sentence lead; low schema drift. | **Weak:** 3B invents overlapping or trivial headings per chunk. | **Poor:** forces narrative thesis and H4 action titles; high over-inference. |
| **Map-reduce merging** | **Clean:** each fixed list merges or falls back via `combined(_:)`; lead written once at final merge. | **Messy:** merging arbitrary H3 topic trees across 4–8 chunks fails or duplicates without a strong model. | **Fragile:** H4 assertions mutate across merge rounds; verbose for 700-token answer cap. |
| **Anonymous `Me` / `Others`** | Works cleanly: `Me:` only when unambiguous, `Others:` or omitted when unclear. | Works cleanly; telegraphic bullets don't require speaker names. | Slightly awkward—executive prose tempts models to invent team/role names. |
| **Backward compatibility** | **100%:** `LibrarySummaryView` renders lead paragraph, headings, bullets, and `Action items` checkboxes unchanged. | **100%** visually (nested bullets supported), but breaks fixed-slot `MeetingSummary` parser & fallback. | **100%** visually, but adds H4 hierarchy and bloats `SummaryCard`. |

---

## Recommended format, prompting strategy, and what NOT to do

### Recommended default: **Candidate A — Pyramid Brief**
1. **Fixes the exact gaps in the current baseline:** adds an answer-first 1–2 sentence lead (Minto), tightens discussion into topic-led bullets instead of vague "Key points", and introduces `### Open questions` so unresolved issues stop leaking into fake decisions or invented tasks **(inferred)**.
2. **Respects the 3B / 4K constraint:** fixed headings parse leniently via `SummaryText.read`, map-reduce cleanly in `SummaryPipeline`, and degrade safely to `MeetingSummary.combined` on merge failure **(inferred)**.
3. **Scales gracefully:** short meetings omit empty sections (a 2-minute sync may only have the 1-sentence lead + 1 Action item); 60-minute meetings can expand `Discussion` to ~5–6 bullets instead of being squeezed into 3 flat key points. Keep `### Action items` spelled identically so `LibrarySummaryView`'s checkbox styling keeps working **(documented, code)**.

### Prompting strategy: On-device vs. Cloud (should differ)

| Stage | On-device (Apple Foundation Models, ~3B / 4K) | Cloud (OpenRouter, e.g. `gpt-4.1-mini` / 128K+) |
|---|---|---|
| **Chunking** | Keep map-reduce (`passageTokens: 2_000`), but add a cheap deterministic pre-filter in Swift (drop silence/greeting-only chunks <N substantive words) before the `isSubstantive` call **(inferred)**. | Single-pass for most meetings (<24K est. tokens, already `defaultPassageTokens`), falling back to map-reduce only on multi-hour calls **(documented, code)**. |
| **Instruction style** | Trim `instructions` to ~90–120 words, imperative verbs, explicit `DO NOT` caps rules, and **2 short few-shot examples** (one substantive mini-meeting, one noise-only → `- None`) ([WWDC25/248](https://developer.apple.com/videos/play/wwdc2025/248/), **documented**). | Richer single-call instructions with **extract-then-abstract** guidance: mentally ground decisions/actions/open questions in transcript facts first, use **bold topic lead-ins** under `Discussion`, preserve exact numbers/dates, and handle mixed Hindi/Hinglish natively **(inferred)**. |
| **Answer ordering** | Ask the model to output **`Decisions` → `Action items` → `Open questions` → `Discussion` → `Overview` LAST** (WWDC25/286: on-device summaries improve when generated last; also protects decisions/actions if truncated). Render `Overview` as the top lead paragraph in Markdown **(documented + inferred)**. | Same output schema so both providers share `SummarySection` rendering, or generate `Overview` last and hoist it to the top. |
| **Merge pass** | Deduplicate lists, explicitly rule **"later turns override earlier ones"**, and synthesize the 1–2 sentence `Overview` *only* on the final merge (passages don't need per-chunk overviews) **(inferred)**. | Only triggered on very long meetings; same override rule. |
| **Post-filtering** | Benchmark replacing per-bullet `isSubstantive` calls (currently up to 12 sequential LLM calls per pass in `SummaryQualityFilter`) with deterministic checks (length, duplication, boilerplate) + optional single-call prune if needed **(inferred)**. | Skip per-bullet LLM relevance calls (already skipped in `OpenRouterSummarizer`). |

### What NOT to do
- **Do NOT use 5-pass Chain of Density** on meeting transcripts (too slow on-device, triggers hallucinations under length pressure on noisy speech).
- **Do NOT use refine (sequential carry-over)** on the 3B model (early hallucinations compound across chunks; *BooookScore* favors hierarchical merging for coherence).
- **Do NOT force an owner on every action item** (with only `Me`/`Others`, forcing owners causes wrong attribution; omit owner when unclear).
- **Do NOT invent dynamic H3 topic headings on-device** (breaks map-reduce merge stability; save Candidate B for an optional cloud template in #58 follow-up).
- **Do NOT turn on `@Generable` guided generation** on-device while `.permissiveContentTransformations` is required for real workplace meetings (`OnDeviceSummarizer.swift`).
- **Do NOT hard-cap a 45-minute meeting at 100 words / 3 key points** (causes generic fluff; bound *per bullet*—one concise line—and cap sections at ~3–6 items instead).

---

## Evaluation plan

### 1. Quality rubric (binary Pass/Fail per check, per Hamel Husain & Eugene Yan)
Score each fixture summary on six binary checks (0/1); track pass rate per check rather than one blended number:
1. **Faithfulness (hard gate):** Zero invented facts, names, dates, decisions, or commitments unsupported by the transcript.
2. **Decision accuracy:** Every explicit agreement/choice is in `Decisions`; tentative ideas or superseded options are *not*.
3. **Action-item precision & ownership:** Every explicit commitment is in `Action items`; suggestions without commitment are excluded; `Me`/`Others` is never swapped or fabricated.
4. **Open-question capture:** Unresolved blockers or deferred choices appear in `Open questions` (not dropped or mislabeled as decisions).
5. **Answer-first & concision:** Lead paragraph states the main outcome in ≤2 sentences; no meta-fluff ("The participants had a productive discussion"); no duplicate bullets across sections.
6. **Structure & noise discipline:** Valid Markdown headings; empty sections omitted; no-substance fixtures produce an empty summary.

### 2. Automated assertions vs. human / LLM-judge review
- **Automated (Swift unit tests + CLI eval runner, zero/cheap cost):** valid Markdown headings; `Overview` ≤2 sentences and ≤45 words; bullet count and per-bullet word bounds; no verbatim copy of known filler phrases; zero cross-section exact duplicates; noise-only fixtures return empty; older three-list notes still parse in `NoteReading`.
- **Judged by reading (gold standard for 10 fixtures, ~15 min/iteration):** Faithfulness, missed decisions, wrong `Me`/`Others` attribution, and "so what?" usefulness. Once human labels exist on 10+ runs, optionally add a G-Eval / FActScore-style cloud judge (binary claim-against-transcript check) to catch regressions between prompt edits, calibrated against human labels before trusting it.

### 3. Synthetic fixture meetings (8 fixtures to commit under tests/fixtures)
1. **Clean 1:1 decision sync (short, ~10 min):** Clear trade-off, 2 decisions, 2 actions (`Me` + `Others`), 1 open question, 1 unowned suggestion (trap).
2. **Long multi-topic product review (~45 min, forces 3–4 on-device chunks):** Decisions made in the *middle* (tests Lost-in-the-Middle) and one early decision *reversed* near the end (tests merge override).
3. **Status stand-up (no decisions, 5 min):** Updates + 1 blocker, zero formal decisions—verifies `Decisions` is omitted rather than fabricated.
4. **Noisy ASR transcript:** Misrecognized proper nouns, fillers, repeated stutters, partial sentences, plus 1 real decision buried inside.
5. **Mixed Hindi/English (Hinglish, romanized + Devanagari):** Real substance spoken across both languages; summary must be clean English without translating gibberish (tests cloud vs. on-device gap noted in #58).
6. **Sensitive/edgy workplace topic:** HR performance issue, medical leave, or security incident—checks `.permissiveContentTransformations` doesn't refuse unnecessarily.
7. **Pure noise / small talk (negative fixture):** Greetings, audio checks ("can you hear me?"), garbled ASR words—must return empty summary.
8. **Tiny meeting (<60s, 3 turns):** One quick confirmation ("Let's move demo to 3 PM")—must produce a 1–2 line summary without padding.

---

## Open questions for the owner
1. **Default section set:** Are you happy with `Overview (lead paragraph)` + `Decisions` + `Action items` + `Discussion` + `Open questions`, or would you rather keep 3 sections and fold open questions into `Discussion`?
2. **Length budget:** Current code enforces a hard 140-word / 12-item cap (`SummaryQualityFilter`). Are you comfortable raising that to ~220–280 words for 30–60 minute meetings while keeping short meetings tight?
3. **Provider parity vs. cloud advantage:** Should on-device and OpenRouter emit the exact same Markdown structure (Pyramid Brief), or may OpenRouter add nested bullets / richer topic grouping?
4. **Post-filter latency:** Should we benchmark removing/batching the per-bullet `isSubstantive` LLM calls in `OnDeviceSummarizer` once the new prompt + `Open questions` bucket are tested on live macOS 26 hardware?
5. **Owner labels in Action items:** Prefer `Me:` / `Others:` prefixes when unambiguous, or plain action text with `(Me)` only when the user themselves committed (since `"Others"` can mean any of several people)?
