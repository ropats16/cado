import Foundation
@testable import Cado

/// Synthetic meeting transcripts for evaluating summary quality (#64).
/// All names, products, numbers and discussions are invented; nothing here
/// comes from real meetings. Hesitation sounds ("um", "uh") are included on
/// purpose so #62's hesitation filter can be checked alongside these once merged.
enum SummaryQualityFixtures {
    typealias Turn = (speaker: MeetingSpeaker, text: String)

    struct Fixture {
        let id: String
        let title: String
        let turns: [Turn]
        let expectsEmpty: Bool
        let expectsMultiPart: Bool
        let forbiddenSubstrings: [String]
    }

    static let all: [Fixture] = [
        cleanShort,
        longMultiTopic,
        standupNoDecisions,
        noisyASR,
        mixedHindiEnglish,
        sensitiveTopic,
        pureSmallTalk,
        tiny,
    ]

    /// 1. Clean 1:1 decision sync: 2 decisions, 2 owned actions, 2 open questions,
    /// 1 unowned suggestion trap ("auto-resize big photos").
    static let cleanShort = Fixture(
        id: "clean-short",
        title: "Clean 1:1 decision sync",
        turns: [
            (.me, "Thanks for jumping on. We need to lock the export format for Kestrel's November 18 beta."),
            (.them, "Right. Engineering timed both options: CSV plus zipped receipts takes about 2 days, whereas PDF layout generation adds around 8 days."),
            (.me, "Eight extra days blows past November 18. Let's ship CSV plus zipped receipts for the beta and defer PDF export to version 2."),
            (.them, "Agreed. CSV and zipped receipts for November 18, PDF in v2. What about large accounts? Exporting a thousand receipts spikes memory on older Macs."),
            (.me, "Let's cap v1 exports at 200 receipts per bundle so older Macs stay safe."),
            (.them, "Makes sense, 200-receipt cap it is. Though we haven't decided whether going over 200 should show a warning or split into multiple zips."),
            (.me, "Let's leave that UX choice open until we test with a few beta users."),
            (.them, "One more bug: uploads over 15 MB are timing out for roughly 3% of test accounts. We still don't know if that's client-side compression or the storage API limit."),
            (.them, "Maybe we could build an automatic image resizer later? Just an idea."),
            (.me, "Interesting thought, let's not commit to an image resizer yet until we know the root cause."),
            (.me, "I will build the CSV and zip exporter and share a test build by Thursday."),
            (.them, "Great. I'll verify the CSV column headers against the accounting tools and pull the 15 MB timeout logs before Friday."),
            (.me, "Sounds good. Talk Friday."),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: []
    )

    /// 2. Long multi-topic product review (~3 passages under real 2,000-token on-device limit):
    /// - Early decision in part 1: launch Canada rollout on May 12.
    /// - Mid-meeting decision in part 2 (Lost-in-the-Middle test): switch search indexing from nightly batch to incremental updates.
    /// - Late reversal in part 3 (Merge override test): scrap Canada May 12, launch UK on May 19 instead.
    static let longMultiTopic = Fixture(
        id: "long-multi-topic",
        title: "Long multi-topic review with mid-meeting decision and reversal",
        turns: [
            // Part 1: Regional rollout initial plan + Support SLA review
            (.me, "Welcome to the Bramble Q2 planning review. We have three areas to cover today: regional rollout, support response times, and search infrastructure."),
            (.them, "Let's start with regional expansion. The localization team finished English-Canada and UK copy last week, and payment processor onboarding is underway for both regions."),
            (.me, "Our original goal was to pick one launch market for May so support isn't split across time zones. Canada looked simplest because our billing currency setup is close."),
            (.them, "Right, Stripe CAD settlement is already tested in staging. If we go with Canada first, we can turn on sign-ups on May 12 and watch ticket volume for two weeks before opening another market."),
            (.me, "Okay, let's decide to start the regional rollout in Canada on May 12. That keeps the first launch manageable while engineering watches the payment webhooks."),
            (.them, "Agreed, Canada rollout on May 12. Moving to support metrics: our Q1 median first-response time for Pro tier customers was 6.5 hours, well above our 4-hour target."),
            (.me, "Six and a half hours is too slow for paying teams. Where is the queue backing up—is it billing questions, onboarding, or bug reports?"),
            (.them, "About 48% of tickets are workspace permission issues after team imports, 30% are invoice formatting questions, and the remaining 22% are genuine product bugs."),
            (.me, "If nearly half are permission issues, fixing the team-import preview screen would take real pressure off support without hiring right away."),
            (.them, "Agreed, though we haven't sized the import preview redesign yet. Meanwhile, we added a dedicated triage rotation on Mondays and Thursdays, which already brought Tuesday backlogs down by 20%."),
            (.me, "Let's track whether that rotation holds once regional sign-ups begin. Also, remember our help center articles on role permissions are still from last August."),
            (.them, "Yeah, support flagged that three screenshots in the role-permissions guide still show the old sidebar layout. Updating those docs should cut repeat questions too."),
            (.me, "We also had a spike in churn among annual accounts that waited over 12 hours for a reply during tax season, roughly 9 accounts out of 140 renewals."),
            (.them, "Good context. Support leadership wants to keep the 4-hour Pro SLA target for Q2 and review staffing again if ticket volume grows more than 35% after the May launch."),
            (.me, "Makes sense. Let's check in on engineering capacity for the permission-preview work next week once we see the search estimates."),
            (.them, "Sure. Before we switch to search, one quick note on mobile notifications: push delivery latency on Android dropped from 9 seconds to 1.8 seconds after upgrading the worker pool."),
            (.me, "Nice win. Customers noticed that immediately in the beta Slack channel. Anything else on mobile before we dive into search indexing?"),
            (.them, "No, iOS and Android crash-free rates are both above 99.6% this week, so mobile is steady for the Q2 launch window."),
            (.me, "Let's also touch on onboarding activation before search. Self-serve teams that invite a second teammate within 48 hours convert to paid at 38%, compared to 11% for solo sign-ups."),
            (.them, "Right, and our current welcome checklist buries the invite button on step four after workspace theming and notification preferences."),
            (.me, "Moving team invites up to step two seems obvious, though product design wants to test whether asking too early drops solo completion rates."),
            (.them, "Agreed—let's wait for design's prototype numbers before changing onboarding order. How about desktop auto-updates?"),
            (.me, "Desktop updater rollout reached 84% of active macOS users within 72 hours of release 2.4, up from 61% on release 2.3 after we added the silent background check."),
            (.them, "Nice improvement. Any spike in support tickets from the updater?"),
            (.me, "Only four tickets total, all from corporate machines behind custom TLS proxies where the signature fetch timed out."),
            (.them, "Good to note. Let's keep monitoring corporate proxy timeouts as enterprise deals pick up in Q2. Speaking of enterprise deals, sales asked about SAML single sign-on support for workspaces above fifty seats."),
            (.me, "We already support Google and Microsoft OAuth, right? How much work is generic SAML 2.0 with Okta and Entra ID?"),
            (.them, "Identity engineering estimated three weeks for SAML assertion handling, metadata rotation, and SCIM deprovisioning, plus another week of security review."),
            (.me, "That's a full sprint cycle we don't have in May. Let's keep SAML on the Q3 roadmap and tell sales we're not committing to a May delivery date."),
            (.them, "Makes sense. Also on billing, finance noticed that three annual customers tried to switch from monthly to annual mid-cycle and got prorated credit memos that confused their accounting software."),
            (.me, "Yeah, Stripe generates a negative line item on the next invoice by default. Billing engineering is checking whether issuing an explicit standalone credit note PDF makes reconciliation cleaner."),
            (.them, "Okay, no urgent change there—just good context for the Q2 billing cleanup backlog. Let's also check API webhook reliability from last month's incident review."),
            (.me, "After we added exponential backoff and a dead-letter queue for webhook deliveries, delivery success rose from 97.4% to 99.85%, and duplicate deliveries dropped below 0.02%."),
            (.them, "That's solid. Partner integrations stopped complaining once retries stretched past ten minutes during their maintenance windows."),
            (.me, "Great. Let's spend the middle of this meeting on search infrastructure because our nightly batch jobs are starting to collide with morning traffic."),
            (.them, "Yes. Right now our full-text search index rebuilds in a single nightly batch starting at 2 AM UTC. Six months ago it finished in 25 minutes; last week it took 82 minutes and spiked database CPU to 91%."),
            (.me, "Eighty-two minutes is cutting it way too close to European morning traffic. What are our options for fixing it before Q2 sign-ups double workspace count?"),
            (.them, "Option A is scaling the batch worker and adding a read replica just for indexing, which costs around $650 a month and still leaves users waiting up to 24 hours for new notes to become searchable."),
            (.me, "And Option B is incremental indexing? Walk me through the numbers on that."),
            (.them, "Option B switches search indexing from nightly batch to incremental updates driven by a lightweight event queue. It cuts peak database CPU duration by about 40 minutes, keeps search freshness under 15 seconds, and only adds about $180 a month in queue storage."),
            (.me, "Forty minutes off peak CPU, 15-second freshness, and $180 a month versus $650 for a replica. Any reliability catch with incremental updates?"),
            (.them, "The main risk is memory usage on the indexing worker when a large workspace bulk-imports thousands of records at once. We need to stress-test it on our 500,000-record staging dataset."),
            (.me, "Even with that check, incremental indexing is clearly the right call. Let's formally decide to switch search indexing from nightly batch to incremental updates."),
            (.them, "Agreed—we are switching search indexing to incremental updates. I will benchmark the incremental index worker's memory usage on the 500k-record staging set and share the numbers by Wednesday."),
            (.me, "Thanks. One open question on search: do enterprise accounts need a manual reindex button in workspace settings if an import ever looks out of sync, or should only support trigger reindexes?"),
            (.them, "Good question—we haven't settled whether customers should get a self-serve reindex button or keep it support-only. Let's park that until after the Wednesday benchmark."),
            (.me, "Also, on the search UI side, um, customers asked about fuzzy typo matching for hyphenated project codes, like matching Q2-401 when they type Q2401."),
            (.them, "That's a tokenizer change rather than an indexing architecture change, so we can evaluate it independently after incremental indexing is live."),
            (.me, "Fair enough. Let's check analytics retention briefly while we have everyone. Our raw clickstream table is up to 4.2 terabytes and query dashboards are timing out on 90-day lookbacks."),
            (.them, "Data engineering proposed partitioning by month and rolling up events older than 60 days into daily aggregates. That would trim storage by roughly 55%."),
            (.me, "Sounds promising, though nobody from data engineering is on this call to approve the schema change. Let's keep analytics retention for Thursday's architecture sync."),
            (.them, "Agreed, no decision on analytics retention today. Let's also mention the design system audit: button contrast in dark mode passed WCAG AA across all core forms."),
            (.me, "What about keyboard navigation on the settings modal? QA flagged focus trapping in the billing tab last sprint."),
            (.them, "Engineering patched focus trapping on Tuesday, and screen-reader labels on the invoice table are scheduled for next sprint."),
            (.me, "Also quick status on our SOC 2 Type II evidence collection: 34 of 42 automated controls are already streaming into the compliance portal."),
            (.them, "The remaining 8 controls are manual quarterly access reviews, which IT runs on the first Monday of May. Auditors confirmed our June window is still on track."),
            (.me, "Before we wrap up the engineering updates, how did the Postgres 16 read-replica failover drill go on Wednesday?"),
            (.them, "Failover completed in 28 seconds, well inside our 60-second recovery objective. One minor wrinkle: background export workers held stale connections for ninety seconds until we added a connection-pool health check."),
            (.me, "Nice catch during a drill instead of production. Did the pool health check ship already?"),
            (.them, "Yes, merged yesterday and verified in staging; exports reconnected in four seconds on the second drill."),
            (.me, "And how are infrastructure costs tracking against our Q2 cloud budget after the worker pool upgrade?"),
            (.them, "We are roughly 6% under budget right now because switching staging databases to spot instances saved about $1,400 a month, which easily offsets the new notification workers."),
            (.me, "Good to hear. Now—hang on, I just got a ping from Maya in Finance and Legal about our regional rollout."),
            (.them, "Oh? What did Maya say?"),
            (.me, "Bad news on Canada: our Canadian GST tax registration hit a paperwork backlog and won't clear until mid-June at the earliest. Legal says we cannot bill Canadian customers before that registration number is active."),
            (.them, "Whoa, that completely rules out May 12 for Canada. What about the UK? Did Legal clear UK VAT?"),
            (.me, "Yes, UK VAT registration is already approved, and Stripe GBP settlement passed end-to-end testing yesterday. Operations just needs one extra week to schedule UK-hours support coverage."),
            (.them, "So May 19 for the UK works cleanly without any legal risk?"),
            (.me, "Exactly. So let's reverse our earlier Canada decision: scrap the May 12 Canada rollout and launch in the UK on May 19 instead. Canada moves to June once GST clears."),
            (.them, "Completely agreed—cancel the May 12 Canada launch and roll out in the UK on May 19 instead. That's much safer than launching without tax registration."),
            (.me, "I'll update the UK launch checklist and send the revised May 19 timeline to operations by Tuesday."),
            (.them, "Perfect. And, uh, maybe we could also look at a German beta sometime in Q3? Nobody has scoped German localization yet, just throwing it out there."),
            (.me, "Let's definitely not commit to a German beta yet—keep it as an open question until Q3 planning."),
            (.them, "Got it. Anything else before we wrap up?"),
            (.me, "Just to recap: UK on May 19 instead of Canada, incremental search indexing approved, Wednesday benchmark from your side, Tuesday UK checklist from mine. Thanks everyone!"),
        ],
        expectsEmpty: false,
        expectsMultiPart: true,
        forbiddenSubstrings: []
    )

    /// 3. Status stand-up with updates, 1 blocker, 2 action items, and ZERO decisions.
    static let standupNoDecisions = Fixture(
        id: "standup-no-decisions",
        title: "Status stand-up with no decisions",
        turns: [
            (.me, "Morning everyone, quick five-minute stand-up."),
            (.them, "Yesterday I finished the staging database migration—it took 14 minutes with zero downtime. Today I'm reviewing the onboarding flow pull request after lunch."),
            (.me, "Nice. On my side, the onboarding flow PR is ready for review, and I noticed our iOS push certificate expires in 9 days so we'll need to renew it soon."),
            (.them, "Heads up on a blocker: the QA environment is still failing OAuth callbacks because IT hasn't rotated the sandbox client secret yet."),
            (.me, "Got it. I will follow up with IT today to get the sandbox OAuth secret rotated so QA is unblocked."),
            (.them, "Thanks, that's the only thing holding up end-to-end sign-in tests. Nothing else from me."),
            (.me, "Cool, short and sweet. See you all tomorrow."),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: []
    )

    /// 4. Noisy ASR transcript with heavy hesitations ("um", "uh", "er"),
    /// stutters, and garbled recognition artifacts, plus 1 real decision, 1 action, 1 open question.
    static let noisyASR = Fixture(
        id: "noisy-asr",
        title: "Noisy ASR with hesitations and garbled words",
        turns: [
            (.me, "Um, hey, can you—uh, sorry, my mic clipped—um, can you hear me okay?"),
            (.them, "Uh, yeah, yeah, mostly. You broke up on, er, purple toaster something, but you're back now."),
            (.me, "Okay, um, so, uh, the—the staging webhook deliveries keep timing out under load. Right now the timeout is, um, 5 seconds."),
            (.them, "Yeah, uh, five seconds is way too tight when the partner endpoint is cold. Velvet bicycle—sorry, background noise—um, we should bump it to 15 seconds."),
            (.me, "Right, uh, let's—let's definitely increase the webhook timeout from 5 seconds to 15 seconds."),
            (.them, "Um, agreed, 15 seconds. I will, uh, deploy the 15-second webhook timeout config change by Thursday evening."),
            (.me, "Great. One thing I'm, um, not sure about yet: should failed webhooks retry 3 times or 5 times?"),
            (.them, "Er, hmm, let's check partner rate limits before deciding between 3 and 5 retries."),
            (.me, "Uh, okay, cool. Thanks, catch you later."),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: ["purple toaster", "velvet bicycle", "um,", "uh,"]
    )

    /// 5. Mixed Hindi/English (romanized Hinglish + occasional Hindi phrases) with clear work substance.
    /// Summary must be clean English without Hindi filler words.
    static let mixedHindiEnglish = Fixture(
        id: "mixed-hindi-english",
        title: "Mixed Hindi/English workplace call",
        turns: [
            (.me, "Namaste, kaise ho? Can you hear me? Haan, okay great."),
            (.them, "Haan sab theek hai. Um, we need to look at the GST invoice export bug before Monday's billing run."),
            (.me, "Haan, customers reported ki GST totals are rounding off by 1 rupee on multi-line invoices."),
            (.them, "Theek hai, I traced it—we were rounding each line item instead of rounding the final subtotal. Let's hotfix the rounding to two decimal places on the subtotal before Monday."),
            (.me, "Agreed, chalo let's ship the two-decimal subtotal rounding hotfix before Monday's billing cycle."),
            (.them, "Can you add regression tests for GST rounding?"),
            (.me, "Haan, I will write the GST rounding regression tests by Friday."),
            (.them, "Acha, one open question: last month 12 invoices were affected by that 1-rupee difference—do we need to re-issue those 12 invoices or issue credit notes?"),
            (.me, "Finance hasn't confirmed yet, so let's keep that open until they reply."),
            (.them, "Theek hai, shukriya! Bye bye."),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: ["namaste", "kaise ho", "shukriya", "theek hai", "haan"]
    )

    /// 6. Sensitive workplace topic: security token leak + employee medical leave reassignment.
    /// Verifies permissive guardrails summarize calmly without refusing.
    static let sensitiveTopic = Fixture(
        id: "sensitive-topic",
        title: "Sensitive workplace topic (credential leak and medical leave)",
        turns: [
            (.me, "Thanks for getting on quickly. Two urgent things: the leaked analytics API token and covering Raj's medical leave."),
            (.them, "First on the security incident: a read-only analytics API token was accidentally committed to a public demo repo about three hours ago."),
            (.me, "Okay, let's immediately revoke the leaked analytics token and rotate all read-only analytics keys today."),
            (.them, "Agreed—revoke that token right away and rotate every read-only key. Do we know if we have to send a formal incident notice to enterprise customers under the SLA?"),
            (.me, "Not yet; legal needs to review the access logs first, so whether to send a formal customer incident notice stays open."),
            (.me, "I will revoke the leaked token and audit the past 48 hours of API access logs today."),
            (.them, "Good. Second, Raj is out on unexpected medical leave for the next two weeks, and he was primary on-call for the payments service."),
            (.me, "Let's reassign the payments on-call shift to Maya for the next two weeks so Raj doesn't have to worry about alerts while recovering."),
            (.them, "Agreed, Maya takes payments on-call for two weeks. I will hand off the payments on-call runbook to Maya by end of day."),
            (.me, "Thank you. Let's check back once the access log audit finishes."),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: []
    )

    /// 7. Pure small talk, audio checks, hesitations, and disconnected ASR noise.
    /// Must produce an empty summary.
    static let pureSmallTalk = Fixture(
        id: "pure-small-talk",
        title: "Pure small talk and recognition noise",
        turns: [
            (.me, "Hello? Hello, um, can you hear me?"),
            (.them, "Uh, yeah, yeah, I can hear you. How's your week going?"),
            (.me, "Pretty good, raining a lot here. Wait, let me switch my AirPods, um, testing one two."),
            (.them, "Haha, yeah, sound is fine now. Orange umbrella table clock."),
            (.me, "Okay, uh, looks like nobody else is joining this link—wrong room maybe."),
            (.them, "Alright, catch you in the other call. Bye!"),
            (.me, "Bye bye."),
        ],
        expectsEmpty: true,
        expectsMultiPart: false,
        forbiddenSubstrings: []
    )

    /// 8. Tiny meeting (<60s, 3 turns): one quick schedule change, must stay tight without padding.
    static let tiny = Fixture(
        id: "tiny",
        title: "Tiny 3-turn schedule confirmation",
        turns: [
            (.me, "Quick check—can we move tomorrow's client demo from 11 AM to 3 PM? Design needs two extra hours."),
            (.them, "Works for me, 3 PM is fine. I'll send the updated calendar invite now."),
            (.me, "Awesome, thanks!"),
        ],
        expectsEmpty: false,
        expectsMultiPart: false,
        forbiddenSubstrings: []
    )
}

/// Deterministic structural, bounds, emptiness, and duplicate checks for a summary (#64).
enum SummaryQualityChecks {
    static let maxOverviewSentences = 2
    static let maxOverviewWords = 60
    static let maxBulletWords = 40

    static func violations(for outcome: SummaryOutcome, fixture: SummaryQualityFixtures.Fixture,
                           provider: SummaryProvider = .onDevice) -> [String] {
        var issues: [String] = []
        let summary = outcome.summary
        let markdown = SummarySection.markdown(outcome, provider: provider)

        if !markdown.contains("## Summary") || !markdown.contains("## Transcript") {
            issues.append("Markdown missing required Summary or Transcript heading")
        }

        if fixture.expectsEmpty {
            if !summary.isEmpty {
                issues.append("Expected empty summary for noise fixture, got items: \(SummaryText.render(summary))")
            }
            if !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Expected empty overview for noise fixture, got: \(summary.overview)")
            }
            if !markdown.contains("Nothing to note was found in this meeting.") {
                issues.append("Empty summary must render the standard nothing-found line")
            }
            return issues
        }

        if summary.isEmpty {
            issues.append("Expected non-empty summary for substantive fixture")
        }

        // Overview bounds
        let overview = summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overview.isEmpty {
            let overviewWords = overview.split(whereSeparator: \.isWhitespace).count
            if overviewWords > maxOverviewWords {
                issues.append("Overview exceeds \(maxOverviewWords) words (\(overviewWords))")
            }
            let sentences = sentenceCount(overview)
            if sentences > maxOverviewSentences {
                issues.append("Overview exceeds \(maxOverviewSentences) sentences (\(sentences)): \(overview)")
            }
        }

        // Empty sections must be omitted in rendered Markdown
        let sections: [(String, [String])] = [
            ("Decisions", summary.decisions),
            ("Action items", summary.actionItems),
            ("Discussion", summary.discussion),
            ("Open questions", summary.openQuestions),
        ]
        for (title, items) in sections {
            let heading = "### \(title)"
            if items.isEmpty && markdown.contains(heading) {
                issues.append("Empty section \(heading) was not omitted")
            }
            if !items.isEmpty && !markdown.contains(heading) {
                issues.append("Non-empty section \(heading) missing from Markdown")
            }
        }

        // Total item and word bounds
        let allItems = summary.decisions + summary.actionItems + summary.discussion + summary.openQuestions
        if allItems.count > SummaryQualityFilter.maximumItems {
            issues.append("Item count \(allItems.count) exceeds maximum \(SummaryQualityFilter.maximumItems)")
        }
        let totalWords = allItems.joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        if totalWords > SummaryQualityFilter.maximumWords {
            issues.append("Total list words \(totalWords) exceeds maximum \(SummaryQualityFilter.maximumWords)")
        }

        // Per-bullet single-line & word bounds
        for item in allItems {
            if item.contains("\n") {
                issues.append("Multi-line bullet: \(item)")
            }
            let words = item.split(whereSeparator: \.isWhitespace).count
            if words > maxBulletWords {
                issues.append("Bullet exceeds \(maxBulletWords) words (\(words)): \(item)")
            }
        }

        // Cross-section duplicates (normalized)
        var seen: [String: String] = [:]
        for (title, items) in sections {
            for item in items {
                let key = normalized(item)
                if let firstSection = seen[key] {
                    issues.append("Duplicate item across \(firstSection) and \(title): \(item)")
                } else {
                    seen[key] = title
                }
            }
        }

        // Forbidden substrings (noise / untranslated filler / hesitation artifacts)
        let renderedLower = SummaryText.render(summary).lowercased()
        for forbidden in fixture.forbiddenSubstrings {
            if renderedLower.contains(forbidden.lowercased()) {
                issues.append("Output contains forbidden substring '\(forbidden)'")
            }
        }

        return issues
    }

    static func normalized(_ item: String) -> String {
        item.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?:;-•* "))
    }

    static func sentenceCount(_ text: String) -> Int {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return 0 }
        var count = 0
        var index = collapsed.startIndex
        while index < collapsed.endIndex {
            let ch = collapsed[index]
            let next = collapsed.index(after: index)
            if (ch == "." || ch == "!" || ch == "?"),
               next == collapsed.endIndex || collapsed[next] == " " {
                count += 1
            }
            index = next
        }
        return max(1, count)
    }
}
