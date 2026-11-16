import Foundation

/// Wires the meeting session (#30) to the live pieces and the menu: builds
/// the session over the mic, the process tap, the shared engine and the notes
/// library; works out which app "Record Meeting" would record when the menu
/// opens; and re-renders the meeting rows each second while recording, for
/// the elapsed time. Rules live in `MeetingSession` and `MeetingMenuContent`.
///
/// Main-thread only.
final class MeetingController: MeetingActivity {
    /// Receives the meeting rows to show.
    var render: ((MeetingMenuContent) -> Void)?

    private let activity: MeetingActivity
    private let clock: Clock
    private var choice: MeetingAppChoice = .nothing
    private var ticker: Timer?
    private lazy var session = MeetingSession(
        recorder: recorder, engine: engine, notes: notes, archive: FolderMeetingArchive(),
        feedback: NotifierMeetingFeedback(), activity: self, clock: clock,
        systemAudioPermission: {
            SystemAudioPermission(supported: SystemAudioSource.isSupported,
                                  heardSound: SystemAudioObservations.shared.hasHeardSound)
        })
    private let recorder: MeetingRecorder
    private let engine: MeetingEngine
    private let notes: MeetingNoteStore

    /// `activity`: the app-wide feed (the overlay). `notesFolder` is read at
    /// each save, on main.
    init(engine: TranscriptionEngine, activity: MeetingActivity, microphoneUID: @escaping () -> String?,
         notesFolder: @escaping () -> URL, clock: Clock = SystemClock()) {
        self.activity = activity
        self.clock = clock
        recorder = LiveMeetingRecorder(microphoneUID: microphoneUID)
        self.engine = EngineMeetingAdapter(engine)
        notes = NotesLibrary(folder: notesFolder)
    }

    /// For `DictationSession`'s `busy`.
    var dictationBusy: DictationBusyNotice? { session.dictationBusy }

    var isIdle: Bool { session.status == .idle }

    /// The menu is opening: which apps could be recorded right now.
    func refreshApps() {
        if session.status == .idle {
            choice = MeetingAppChoice.decide(supported: SystemAudioSource.isSupported, apps: RecordableApps.current())
        }
        renderNow()
    }

    func perform(_ action: MeetingMenuContent.Action) {
        switch action {
        case .start(let app): session.start(app)
        case .stop: session.stop()
        }
    }

    /// The app is quitting: `done` once the meeting (if any) is stopped and
    /// written down (`MeetingSession.quit`).
    func quit(_ done: @escaping () -> Void) {
        session.quit(done)
    }

    // MARK: - MeetingActivity

    func meetingStatusChanged(_ status: MeetingStatus) {
        activity.meetingStatusChanged(status)
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
        render?(MeetingMenuContent(status: session.status, choice: choice, now: clock.now))
    }
}
