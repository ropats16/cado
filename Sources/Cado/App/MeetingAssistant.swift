import Foundation

/// What `MeetingAssistant` needs of the meeting controller. Main thread.
protocol MeetingRecording: AnyObject {
    var status: MeetingStatus { get }
    /// The app being recorded; nil when not recording.
    var recordingBundleID: String? { get }
    /// What's asked, for the menu's meeting rows.
    var prompt: MeetingDetector.Prompt? { get set }
    /// A start passes the consent reminder.
    func perform(_ action: MeetingMenuContent.Action)
    func currentChoice() -> MeetingAppChoice
}

/// Where "Record this meeting?" / "Stop recording?" shows besides the menu:
/// a notification with the two answers as buttons. The live one is
/// `NotificationMeetingPrompts`. Main thread.
protocol MeetingPromptNotices: AnyObject {
    func show(_ prompt: MeetingDetector.Prompt)
    func withdraw(_ prompt: MeetingDetector.Prompt)
}

/// Meeting detection, the meeting hotkey and the mascot's meeting clicks
/// (#32), wired to the meeting controller: polls which meeting apps use the
/// mic every `pollInterval` while detection is on (not at all while it's
/// off), feeds `MeetingDetector`, and shows what it asks everywhere at once
/// (a notification, the menu and menu bar, the asking mascot), so it works
/// with notifications off too. An answer from any of them is the answer.
/// Nothing here records by itself.
///
/// While a dictation holds a "Record?" (`MeetingDetector.Context.busy`) the
/// menu and mascot stop asking but the notification stays up, so it doesn't
/// pop again once the dictation is done; a Record on it meanwhile says to
/// finish dictating first.
///
/// Main-thread only.
final class MeetingAssistant {
    static let pollInterval: TimeInterval = 3
    /// How late a poll may run, so macOS can group wake-ups.
    static let pollTolerance: TimeInterval = 1

    /// The asking mascot shows (or not).
    var onAskingChanged: ((Bool) -> Void)?
    /// The hotkey found several apps (or none known): open the menu to pick.
    var onChoose: (() -> Void)?
    /// The hotkey can't start a meeting now: tell the user why.
    var onExplain: ((_ title: String, _ body: String) -> Void)?

    private let meetings: MeetingRecording
    private let feed: MicUseFeed
    private let clock: Clock
    private let enabled: () -> Bool
    /// A dictation is recording or being transcribed.
    private let dictating: () -> Bool
    private let notices: MeetingPromptNotices
    private var detector: MeetingDetector
    private var usingMic: [MeetingApp] = []
    /// What the menu and mascot ask.
    private var shown: MeetingDetector.Prompt?
    /// What the notification asks (`shown`, or a held "Record?").
    private var posted: MeetingDetector.Prompt?
    private var poll: ClockTimer?
    private var polling = false
    private var started = false

    /// `enabled`: Settings › Meetings › Ask to record meetings (and a Mac
    /// that can tell), read on every poll and `refresh`.
    init(meetings: MeetingRecording, feed: MicUseFeed, notices: MeetingPromptNotices, clock: Clock = SystemClock(),
         timing: MeetingDetector.Timing = .init(), enabled: @escaping () -> Bool, dictating: @escaping () -> Bool) {
        self.meetings = meetings
        self.feed = feed
        self.notices = notices
        self.clock = clock
        self.enabled = enabled
        self.dictating = dictating
        detector = MeetingDetector(timing: timing)
    }

    /// Starts polling (while detection is on); once.
    func start() {
        guard !started else { return }
        started = true
        tick()
    }

    /// Something the detector reads changed (a meeting's status, a
    /// dictation, the setting): re-decide now, not at the next poll; and
    /// polls again if detection was just switched on.
    func refresh() {
        decide()
        if started, poll == nil, !polling, enabled() { tick() }
    }

    /// The app is quitting: no question outlives it.
    func withdrawAll() {
        if let posted { notices.withdraw(posted) }
        posted = nil
    }

    /// The meeting hotkey, or the mascot's Record Meeting / Stop Recording.
    func toggle() {
        switch decision {
        case .start(let app):
            if let prompt = detector.prompt, prompt.isRecord, prompt.app == app { return answer(prompt, yes: true) }
            meetings.perform(.start(app))
        case .stop:
            meetings.perform(.stop)
        case .choose:
            onChoose?()
        case .explain(let title, let body):
            Log.info("Meeting hotkey: \(body)")
            onExplain?(title, body)
        }
    }

    /// The meeting hotkey or the mascot's menu item would start or stop a
    /// meeting now (or let the user pick the app), not just say why it can't.
    var canToggle: Bool {
        if case .explain = decision { return false }
        return true
    }

    private var decision: MeetingToggle {
        MeetingToggle.decide(status: meetings.status, prompt: detector.prompt, usingMic: usingMic,
                             choice: canStart ? meetings.currentChoice() : .nothing,
                             dictating: dictating())
    }

    /// A start would record now: idle, or recovering (the recovery is held
    /// for the new meeting, #48).
    private var canStart: Bool { meetings.status == .idle || meetings.status.isRecovering }

    /// A click on the asking mascot: Record.
    func recordAsked() {
        guard let prompt = detector.prompt, case .record = prompt else { return }
        answer(prompt, yes: true)
    }

    /// An answer from the menu, a notification or the mascot.
    func answer(_ prompt: MeetingDetector.Prompt, yes: Bool) {
        let wasOpen = detector.prompt == prompt || posted == prompt
        if posted == prompt {   // answered: its notification is used up
            notices.withdraw(prompt)
            posted = nil
        }
        if yes, prompt.isRecord, canStart, dictating() {
            Log.info("Meeting not started (\(prompt.app.name)): a dictation is under way.")
            onExplain?(MeetingToggle.notStarted, MeetingToggle.finishDictating)
            return show(detector.prompt)
        }
        let effect = detector.answer(prompt, yes: yes, context: context, now: clock.now)
        if !wasOpen {
            Log.info("Meeting answer ignored (\(prompt.app.name)): that question is no longer open; its call is over "
                + "or was already answered.")
        }
        show(detector.prompt)
        switch effect {
        case .start(let app)?: meetings.perform(.start(app))
        case .stop?: meetings.perform(.stop)
        case nil: break
        }
    }

    // MARK: - Polling

    private var context: MeetingDetector.Context {
        let busy: Bool
        switch meetings.status {
        case .idle, .recording: busy = dictating()
        case .transcribing, .recovering: busy = true
        }
        return MeetingDetector.Context(enabled: enabled(), recording: meetings.recordingBundleID, busy: busy)
    }

    private func tick() {
        poll = nil
        guard enabled() else {
            usingMic = []
            return decide()   // no more polls until `refresh` sees it on
        }
        polling = true
        feed.meetingAppsUsingMic { [weak self] apps in
            guard let self else { return }
            polling = false
            // nil: unread (a Core Audio error), not "nobody": skip this poll.
            if let apps {
                usingMic = apps
                decide()
            }
            poll = clock.schedule(after: Self.pollInterval, tolerance: Self.pollTolerance) { [weak self] in self?.tick() }
        }
    }

    private func decide() {
        let context = self.context
        detector.update(usingMic: usingMic, context: context, now: clock.now)
        show(detector.prompt, held: context.enabled && context.busy)
    }

    /// Shows what's asked now everywhere; withdraws what isn't any more.
    /// `held`: a dictation (or another meeting's transcription) holds the
    /// question, so a posted "Record?" stays up.
    private func show(_ prompt: MeetingDetector.Prompt?, held: Bool = false) {
        let notice = prompt ?? (held && posted?.isRecord == true ? posted : nil)
        if notice != posted {
            if let posted { notices.withdraw(posted) }
            if let notice { notices.show(notice) }
            posted = notice
        }
        guard prompt != shown else { return }
        if let prompt {
            Log.info("Meeting detection: \(prompt.app.name) — " + (prompt.isRecord ? "asking to record." : "asking to stop."))
        }
        let wasAsking = shown?.isRecord == true
        shown = prompt
        meetings.prompt = prompt
        if (prompt?.isRecord == true) != wasAsking { onAskingChanged?(prompt?.isRecord == true) }
    }
}

extension MeetingDetector.Prompt {
    var isRecord: Bool {
        if case .record = self { return true }
        return false
    }
}
