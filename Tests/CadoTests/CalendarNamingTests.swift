import XCTest
import ServiceManagement
@testable import Cado

private struct NoTrash: NoteTrashing { func trash(_ url: URL) throws {} }

/// Meeting titles from the calendar (#38): matching rules (pure), the naming
/// gate (off / no access), the note's front matter, the spool's stored event,
/// the Settings switch and the onboarding step. A fake calendar throughout:
/// the real one is never touched.
final class CalendarNamingTests: XCTestCase {

    final class FakeCalendar: CalendarPort {
        var access: CalendarAccess
        var onRequest: CalendarAccess
        var events: [CalendarEventInfo] = []
        private(set) var requests = 0
        private(set) var reads = 0
        private(set) var settingsOpened = 0
        init(access: CalendarAccess = .granted, onRequest: CalendarAccess = .granted) {
            self.access = access
            self.onRequest = onRequest
        }
        func requestAccess(_ completion: @escaping (CalendarAccess) -> Void) {
            requests += 1
            if access == .notDetermined { access = onRequest }
            completion(access)
        }
        func events(from start: Date, to end: Date) -> [CalendarEventInfo] {
            reads += 1
            return access == .granted ? events : []
        }
        func openSettings() { settingsOpened += 1 }
    }

    private let now = Date(timeIntervalSince1970: 1_794_839_520)

    private func event(_ title: String, from startOffset: TimeInterval = -60, minutes: Double = 30,
                       people: [String?] = [], video: Bool = false, allDay: Bool = false,
                       declined: Bool = false) -> CalendarEventInfo {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEventInfo(title: title, start: start, end: start.addingTimeInterval(minutes * 60),
                                 isAllDay: allDay, isDeclined: declined,
                                 attendees: people.map { .init(name: $0) }, hasVideoLink: video)
    }

    private func pick(_ events: [CalendarEventInfo]) -> String? {
        CalendarMatcher.match(start: now, events: events)?.title
    }

    // MARK: - Matching

    func testNothingMatchesWithNoEvents() {
        XCTAssertNil(pick([]))
    }

    func testAnEventInProgressMatches() {
        XCTAssertEqual(pick([event("Weekly sync", from: -600)]), "Weekly sync")
    }

    func testAnEventStartingWithinFiveMinutesMatchesButNotLater() {
        XCTAssertEqual(pick([event("Soon", from: 4 * 60)]), "Soon")
        XCTAssertEqual(pick([event("Edge", from: 5 * 60)]), "Edge")
        XCTAssertNil(pick([event("Too late", from: 5 * 60 + 1)]))
    }

    func testAnEventThatAlreadyEndedDoesNotMatch() {
        XCTAssertNil(pick([event("Done", from: -3600, minutes: 30)]))
        XCTAssertNil(pick([event("Just ended", from: -1800, minutes: 30)]), "End is exclusive")
    }

    func testAllDayDeclinedCancelledAndUntitledAreIgnored() {
        var cancelled = event("Cancelled")
        cancelled.isCancelled = true
        XCTAssertNil(pick([event("Holiday", allDay: true), event("No thanks", declined: true), cancelled,
                           event("   \n "), event("")]))
    }

    func testAnEventWithAttendeesOrAVideoLinkBeatsAPlainBlock() {
        XCTAssertEqual(pick([event("Focus time", from: -10), event("Standup", from: -3000, minutes: 90, people: ["Ada"])]), "Standup")
        XCTAssertEqual(pick([event("Focus time", from: -10), event("Call", from: -3000, minutes: 90, video: true)]), "Call")
    }

    func testAnEventWithOnlyTheUserDoesNotCountAsHavingAttendees() {
        var solo = event("Solo", from: -3000)
        solo.attendees = [.init(name: "Me", isCurrentUser: true)]
        XCTAssertEqual(pick([solo, event("Block", from: -10)]), "Block", "Neither has a signal: the closest start wins")
    }

    func testTheClosestStartWinsAmongEqualSignals() {
        let events = [event("Earlier", from: -1200, video: true), event("Later", from: 120, video: true)]
        XCTAssertEqual(pick(events), "Later", "2 minutes away beats 20")
        XCTAssertEqual(pick(events.reversed()), "Later", "Order of the input doesn't matter")
    }

    func testTiesBreakByShorterThenEarlierThenTitle() {
        XCTAssertEqual(pick([event("Long", from: -60, minutes: 90), event("Short", from: -60, minutes: 30)]), "Short")
        XCTAssertEqual(pick([event("Beta", from: -60), event("Alpha", from: -60)]), "Alpha")
        XCTAssertEqual(pick([event("Beta", from: -60), event("Alpha", from: -60)].reversed()), "Alpha")
        XCTAssertEqual(pick([event("Starts later", from: 60), event("Started earlier", from: -60)]), "Started earlier")
    }

    func testTitlesAreOneLineAndCapped() {
        XCTAssertEqual(pick([event("  Design\nreview \t  v2  ")]), "Design review v2")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(pick([event(long)])?.count, CalendarMatcher.titleLimit)
    }

    func testAttendeeNamesAreNamesOnly() {
        let names = CalendarMatcher.attendeeNames([
            .init(name: "Ada Lovelace"), .init(name: "Me", isCurrentUser: true), .init(name: nil),
            .init(name: "  "), .init(name: "grace@example.com"), .init(name: "ada lovelace"),
            .init(name: "Alan\nTuring"),
        ])
        XCTAssertEqual(names, ["Ada Lovelace", "Alan Turing"], "No emails, no you, no blanks, no repeats")
    }

    func testAttendeesAreCapped() {
        let many = (0..<50).map { CalendarEventInfo.Attendee(name: "Person \($0)") }
        XCTAssertEqual(CalendarMatcher.attendeeNames(many).count, CalendarMatcher.attendeeLimit)
    }

    func testVideoLinks() {
        XCTAssertTrue(VideoLink.isIn("Join: https://us02web.zoom.us/j/123"))
        XCTAssertTrue(VideoLink.isIn("HTTPS://MEET.GOOGLE.COM/abc-defg"))
        XCTAssertTrue(VideoLink.isIn("https://teams.microsoft.com/l/meetup-join/x"))
        XCTAssertFalse(VideoLink.isIn("Room 4B"))
        XCTAssertFalse(VideoLink.isIn(nil))
    }

    // MARK: - The gate

    func testNamingIsOffUntilEnabledAndAllowed() {
        let calendar = FakeCalendar()
        calendar.events = [event("Weekly sync", people: ["Ada"])]
        var enabled = false
        let naming = MeetingCalendarNaming(isEnabled: { enabled }, calendar: calendar)
        XCTAssertNil(naming.event(forMeetingStartingAt: now))
        XCTAssertEqual(calendar.reads, 0, "Off: the calendar isn't even read")
        enabled = true
        XCTAssertEqual(naming.event(forMeetingStartingAt: now), MatchedEvent(title: "Weekly sync", attendees: ["Ada"]))
        for access in [CalendarAccess.notDetermined, .denied, .restricted, .unavailable] {
            calendar.access = access
            XCTAssertNil(naming.event(forMeetingStartingAt: now), "\(access)")
        }
        XCTAssertEqual(calendar.requests, 0, "Naming never asks for access")
        XCTAssertNil(MeetingCalendarNaming.off.event(forMeetingStartingAt: now))
    }

    // MARK: - Note and front matter

    func testNoteIsNamedAfterTheEventAndRecordsIt() {
        let event = MatchedEvent(title: "Weekly sync", attendees: ["Ada Lovelace", "Alan Turing"])
        let note = MeetingNote(appName: "Zoom", start: now, duration: 60, turns: [], event: event)
        let draft = note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(draft.title, "Weekly sync")
        XCTAssertEqual(draft.event, "Weekly sync")
        XCTAssertEqual(draft.attendees, ["Ada Lovelace", "Alan Turing"])
        XCTAssertTrue(draft.body.hasPrefix("Recorded from Zoom (Others)"), "The body is unchanged")
    }

    func testNoEventKeepsTodaysNaming() {
        let note = MeetingNote(appName: "Zoom", start: now, duration: 60, turns: [])
        let draft = note.draft(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(draft.title, "Meeting with Zoom — 16 Nov 2026 at 14:32")
        XCTAssertNil(draft.event)
        XCTAssertEqual(draft.attendees, [])
    }

    func testFrontMatterGainsEventAndAttendeesOnlyWhenPresent() {
        let plain = NoteFrontMatter.render(title: "T", date: now, kind: "meeting", duration: 5, body: "B\n")
        XCTAssertFalse(plain.contains("event:"))
        XCTAssertFalse(plain.contains("attendees:"))
        let rich = NoteFrontMatter.render(title: "Q4 \"plan\"", date: now, kind: "meeting", duration: 5, body: "B\n",
                                          event: "Q4 \"plan\"", attendees: ["Ada", "Alan"])
        XCTAssertTrue(rich.contains("event: \"Q4 \\\"plan\\\"\"\n"))
        XCTAssertTrue(rich.contains("attendees: [\"Ada\", \"Alan\"]\n"))
        let parsed = NoteFrontMatter.parse(rich)
        XCTAssertTrue(parsed.hasBlock)
        XCTAssertEqual(parsed.value(for: "title"), "Q4 \"plan\"")
        XCTAssertEqual(parsed.value(for: "event"), "Q4 \"plan\"")
        XCTAssertEqual(parsed.value(for: "kind"), "meeting", "Existing keys read as before")
        XCTAssertEqual(parsed.body.trimmingCharacters(in: .whitespacesAndNewlines), "B")
    }

    func testAnEventNamedNoteSavesWithASafeFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(folder: { dir }, trasher: NoTrash(), watcher: FakeFolderWatcher(),
                                   timeZone: TimeZone(identifier: "UTC")!)
        let event = MatchedEvent(title: "Q4 / budget: \"final\"? #1", attendees: ["Ada"])
        let note = MeetingNote(appName: "Zoom", start: now, duration: 60, turns: [], event: event)
        let first = try library.create(note.draft())
        let second = try library.create(note.draft())
        XCTAssertEqual(first.summary.id, "2026-11-16 Q4 budget final 1.md")
        XCTAssertEqual(second.summary.id, "2026-11-16 Q4 budget final 1 2.md", "A clash gets a number")
        XCTAssertEqual(first.summary.title, "Q4 / budget: \"final\"? #1", "The title keeps what the event said")
        let text = try String(contentsOf: first.summary.url, encoding: .utf8)
        XCTAssertTrue(text.contains("attendees: [\"Ada\"]"))
        XCTAssertEqual(library.list().count, 2)
    }

    // MARK: - Spool

    func testTheEventIsStoredInTheSpoolAndOldFilesStillOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("spool-cal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let event = MatchedEvent(title: "Weekly sync", attendees: ["Ada"])
        let meeting = SpooledMeeting(id: UUID(), appName: "Zoom", appBundleID: "us.zoom.xos", startDate: now, event: event)
        var handle: MeetingSpoolHandle? = try FolderMeetingSpool(root: root).create(meeting)
        handle?.append([Float](repeating: 0.1, count: 20_000), for: .me)
        handle = nil
        do {   // released at the end: a leftover holds its folder's lock
            let left = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
            XCTAssertEqual(left.handle.meeting.event, event, "A recovered meeting keeps its event")
        }

        // A meeting.json from before this feature has no "event" key.
        let file = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "meeting.json" })
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["event"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let old = try XCTUnwrap(FolderMeetingSpool(root: root).leftovers().first)
        XCTAssertNil(old.handle.meeting.event)
        XCTAssertEqual(old.handle.meeting.appName, "Zoom")
    }

    // MARK: - Config

    func testConfigDefaultsOffAndOlderConfigsStayOff() throws {
        XCTAssertFalse(Config.defaults.nameMeetingsFromCalendar)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.nameMeetingsFromCalendar)
        var on = Config.defaults
        on.nameMeetingsFromCalendar = true
        let round = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(on))
        XCTAssertTrue(round.nameMeetingsFromCalendar)
    }

    // MARK: - Onboarding step

    private func content(_ access: CalendarAccess?, on: Bool = false) -> OnboardingContent {
        let inputs = ReadinessInputs(
            accessibility: .granted, microphone: .authorized,
            engine: EngineReadiness(status: .ready, modelPath: "/m", download: nil, isFirstLoad: false),
            hotkeyTap: .installed)
        let model = OnboardingModelFacts(options: [], selected: nil, downloads: [:], partial: [])
        return OnboardingContent(inputs: inputs, model: model, notifications: .authorized, calendar: access,
                                 calendarOn: on, hold: .controlShift, toggle: .controlOptionSpace,
                                 cancelKeyCode: KeyBinding.escapeKeyCode)
    }

    func testOnboardingCalendarStepIsOptionalAndAsksOnlyByButton() {
        let c = content(.notDetermined)
        XCTAssertTrue(OnboardingStepID.calendar.isOptional)
        XCTAssertEqual(c.step(.calendar).state, .todo)
        XCTAssertEqual(c.step(.calendar).primary?.action, .enableCalendar)
        XCTAssertTrue(c.isSetUp, "Optional: never needed to be set up")
        XCTAssertNotEqual(c.landing(isFirstShow: false), .calendar)
    }

    func testOnboardingCalendarStepStates() {
        XCTAssertEqual(content(.granted, on: true).step(.calendar).state, .done)
        XCTAssertEqual(content(.granted, on: false).step(.calendar).primary?.action, .enableCalendar)
        let denied = content(.denied).step(.calendar)
        XCTAssertEqual(denied.state, .declined)
        XCTAssertEqual(denied.primary?.action, .openCalendarSettings)
        XCTAssertEqual(content(.restricted).step(.calendar).state, .declined)
        XCTAssertEqual(content(.unavailable).step(.calendar).state, .declined)
    }
}

/// The Settings switch (#38): the system prompt only from turning it on.
@MainActor
final class SettingsCalendarTests: XCTestCase {
    private final class FakeLogin: LoginItemService {
        var rawStatus: SMAppService.Status = .notRegistered
        func register() throws {}
        func unregister() throws {}
    }

    private var dir: URL!
    private var store: ConfigStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("settings-cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = ConfigStore(url: dir.appendingPathComponent("config.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeVM(_ calendar: CalendarNamingTests.FakeCalendar) -> SettingsViewModel {
        SettingsViewModel(
            configStore: store, loginItem: LoginItem(service: FakeLogin()), availableMics: { [] },
            presentModelFilenames: { [] }, onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: .current, currentModel: { ModelSpec.file("/m/ggml-tiny.en.bin") }, modelStatus: .ready,
            onModelSettingsChange: {}, calendar: calendar)
    }

    func testOffByDefaultAndCreatingTheViewModelNeverAsks() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .notDetermined)
        let vm = makeVM(calendar)
        XCTAssertFalse(vm.nameMeetingsFromCalendar)
        XCTAssertEqual(calendar.requests, 0)
    }

    func testTurningItOnAsksAndGrantedSavesIt() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .notDetermined, onRequest: .granted)
        let vm = makeVM(calendar)
        vm.setNameMeetingsFromCalendar(true)
        XCTAssertEqual(calendar.requests, 1)
        XCTAssertTrue(vm.nameMeetingsFromCalendar)
        XCTAssertTrue(store.config.nameMeetingsFromCalendar)
        vm.setNameMeetingsFromCalendar(false)
        XCTAssertFalse(vm.nameMeetingsFromCalendar)
        XCTAssertEqual(calendar.requests, 1)
    }

    func testDeniedLeavesItOffAndExplainsHowToAllowIt() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .notDetermined, onRequest: .denied)
        let vm = makeVM(calendar)
        vm.setNameMeetingsFromCalendar(true)
        XCTAssertFalse(vm.nameMeetingsFromCalendar)
        XCTAssertFalse(store.config.nameMeetingsFromCalendar)
        XCTAssertTrue(vm.calendarNeedsSystemSettings)
        XCTAssertTrue(vm.calendarNote.contains("System Settings"))
        vm.setNameMeetingsFromCalendar(true)   // already denied: no second prompt
        XCTAssertEqual(calendar.requests, 1)
        vm.openCalendarSettings()
        XCTAssertEqual(calendar.settingsOpened, 1)
    }

    func testRevokedAccessShowsOffButKeepsTheChoice() {
        let calendar = CalendarNamingTests.FakeCalendar(access: .granted)
        let vm = makeVM(calendar)
        vm.setNameMeetingsFromCalendar(true)
        XCTAssertTrue(vm.nameMeetingsFromCalendar)
        calendar.access = .denied
        XCTAssertFalse(vm.nameMeetingsFromCalendar)
        XCTAssertTrue(store.config.nameMeetingsFromCalendar)
    }
}
