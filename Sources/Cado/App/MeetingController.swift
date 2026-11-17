import Foundation

/// Wires the meeting session (#30, #31) to the live pieces and the menu:
/// builds the session over the mic, the process tap, the shared engine, the
/// notes library and the on-disk spool (`FolderMeetingSpool`); works out which app "Record Meeting" would record when the menu
/// opens; and re-renders the meeting rows each second while recording, for
/// the elapsed time. Rules live in `MeetingSession` and `MeetingMenuContent`.
///
/// Main-thread only.
final class MeetingController: MeetingActivity {
    /// Receives the meeting rows to show.
    var render: ((MeetingMenuContent) -> Void)?
    /// Each status change (the Library's in-progress row, #42).
    var onStatusChange: ((MeetingStatus) -> Void)?

    private let activity: MeetingActivity
    private let clock: Clock
    private var choice: MeetingAppChoice = .nothing
    private var ticker: Timer?
    private lazy var session = MeetingSession(
        recorder: recorder, engine: engine, notes: notes, archive: FolderMeetingArchive(),
        spool: FolderMeetingSpool(), feedback: NotifierMeetingFeedback(), activity: self, clock: clock,
        systemAudioPermission: systemAudio, keepAudio: keepAudio)
    private let recorder: MeetingRecorder
    private let engine: MeetingEngine
    private let notes: MeetingNoteStore
    private let systemAudio: () -> SystemAudioPermission
    private let keepAudio: () -> Bool

    /// `activity`: the app-wide feed (the overlay). `notes`: the notes
    /// library meeting notes are saved to. `systemAudio`: the permission as
    /// observed (`Permissions.systemAudio`), read when the menu renders and
    /// when a meeting ends. `keepAudio`: Settings › Meetings › Keep meeting
    /// audio, read when a meeting ends.
    init(engine: TranscriptionEngine, activity: MeetingActivity, microphoneUID: @escaping () -> String?,
         notes: MeetingNoteStore, systemAudio: @escaping () -> SystemAudioPermission,
         keepAudio: @escaping () -> Bool, clock: Clock = SystemClock()) {
        self.activity = activity
        self.clock = clock
        recorder = LiveMeetingRecorder(microphoneUID: microphoneUID)
        self.engine = EngineMeetingAdapter(engine)
        self.notes = notes
        self.systemAudio = systemAudio
        self.keepAudio = keepAudio
    }

    /// For `DictationSession`'s `busy`.
    var dictationBusy: DictationBusyNotice? { session.dictationBusy }

    var isIdle: Bool { session.status == .idle }

    var status: MeetingStatus { session.status }

    /// The menu is opening: which apps could be recorded right now (also
    /// during a recovery, which recording holds, #48).
    func refreshApps() {
        if session.status == .idle || session.status.isRecovering {
            choice = MeetingAppChoice.decide(supported: SystemAudioReadiness.canRecord(systemAudio()),
                                             apps: RecordableApps.current())
        }
        renderNow()
    }

    func perform(_ action: MeetingMenuContent.Action) {
        switch action {
        case .start(let app): session.start(app)
        case .stop: session.stop()
        }
    }

    /// Cado can transcribe: recover meetings an earlier run didn't finish
    /// (`MeetingSession.recoverLeftovers`). Once per launch.
    func recoverLeftovers() {
        session.recoverLeftovers()
    }

    /// The app is quitting: `done` once the meeting (if any) is stopped and
    /// written down (`MeetingSession.quit`).
    func quit(_ done: @escaping () -> Void) {
        session.quit(done)
    }

    // MARK: - MeetingActivity

    func meetingStatusChanged(_ status: MeetingStatus) {
        activity.meetingStatusChanged(status)
        onStatusChange?(status)
        if case .recording = status {
            if ticker == nil {
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.renderNow() }
                RunLoop.main.add(timer, forMode: .common)   // ticks while the menu is open, too
                ticker = timer
            }
        } else {
            ticker?.invalidate()
            ticker = nil
        }
        renderNow()
    }

    private func renderNow() {
        let issue = SystemAudioReadiness.issue(for: systemAudio(), lastMeetingThemSilent: session.lastThemWasSilent)
        render?(MeetingMenuContent(status: session.status, choice: choice, now: clock.now, systemAudio: issue))
    }
}

/// Answers "may the app quit now?": asks the session to wrap up (which calls
/// back at once if there's nothing to wait for) and says `.later` only if it
/// didn't. The reply fires once, even if quit is requested again meanwhile.
final class TerminationGate {
    enum Decision: Equatable { case now, later }

    private var waiting = false

    func request(quit: (@escaping () -> Void) -> Void, reply: @escaping () -> Void) -> Decision {
        if waiting { return .later }
        waiting = true
        var startedReturned = false
        var finishedEarly = false
        quit { [weak self] in
            if !startedReturned { finishedEarly = true; return }
            guard let self, self.waiting else { return }
            self.waiting = false
            reply()
        }
        startedReturned = true
        if finishedEarly { waiting = false; return .now }
        return .later
    }
}
