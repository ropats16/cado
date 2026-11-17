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
/// mic every `pollInterval` while detection is on, feeds `MeetingDetector`,
/// and shows what it asks everywhere at once (a notification, the menu and
/// menu bar, the asking mascot), so it works with notifications off too. An
/// answer from any of them is the answer. Nothing here records by itself.
///
/// Main-thread only.
final class MeetingAssistant {
    static let pollInterval: TimeInterval = 3

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
    private var shown: MeetingDetector.Prompt?
    private var poll: ClockTimer?
    private var polling = false

    /// `enabled`: Settings › Meetings › Ask to record meetings (and a Mac
    /// that can tell), read on every poll.
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

    /// Starts polling; once.
    func start() {
        guard poll == nil, !polling else { return }
        tick()
    }

    /// Something the detector reads changed (a meeting's status, a
    /// dictation, the setting): re-decide now, not at the next poll.
    func refresh() {
        decide()
    }

    /// The meeting hotkey, or a right-click on an idle mascot.
    func toggle() {
        switch MeetingToggle.decide(status: meetings.status, prompt: detector.prompt, usingMic: usingMic,
                                    choice: meetings.status == .idle ? meetings.currentChoice() : .nothing) {
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

    /// A click on the asking mascot: Record.
    func recordAsked() {
        guard let prompt = detector.prompt, case .record = prompt else { return }
        answer(prompt, yes: true)
    }

    /// An answer from the menu, a notification or the mascot.
    func answer(_ prompt: MeetingDetector.Prompt, yes: Bool) {
        let effect = detector.answer(prompt, yes: yes, context: context, now: clock.now)
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
            decide()
            return schedule()
        }
        polling = true
        feed.meetingAppsUsingMic { [weak self] apps in
            guard let self else { return }
            polling = false
            usingMic = apps
            decide()
            schedule()
        }
    }

    private func schedule() {
        poll = clock.schedule(after: Self.pollInterval) { [weak self] in self?.tick() }
    }

    private func decide() {
        detector.update(usingMic: usingMic, context: context, now: clock.now)
        show(detector.prompt)
    }

    /// Shows what's asked now everywhere; withdraws what isn't any more.
    private func show(_ prompt: MeetingDetector.Prompt?) {
        guard prompt != shown else { return }
        if let shown { notices.withdraw(shown) }
        if let prompt {
            Log.info("Meeting detection: \(prompt.app.name) — " + (prompt.isRecord ? "asking to record." : "asking to stop."))
            notices.show(prompt)
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
