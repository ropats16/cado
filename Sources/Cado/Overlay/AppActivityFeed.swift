import Foundation

/// The app-wide `AppActivity`, plus the live mic level and "text landed", for
/// whoever watches (the overlay; maybe the menu later). Flows report their own
/// state in; this combines them into the one value, so observers never learn
/// which flow is behind it.
///
/// Main-thread only: report and observe on main.
final class AppActivityFeed {
    enum Signal: Equatable {
        /// `activity` changed to this; never sent twice in a row.
        case activity(AppActivity)
        /// 0...1 mic level of the running dictation.
        case level(Float)
        /// A dictation's text reached the user (pasted or copied).
        case textLanded
    }

    /// Current value; set before observers hear of it.
    private(set) var activity: AppActivity = .idle

    /// Each flow's own activity; a meeting flow (#30+) adds its input here
    /// and a rule in `combined`.
    private var dictation: AppActivity = .idle

    private var observers: [(Signal) -> Void] = []

    /// Called for every later signal, in order. No replay: read `activity`.
    func observe(_ observer: @escaping (Signal) -> Void) {
        observers.append(observer)
    }

    private var combined: AppActivity { dictation }

    private func update() {
        let next = combined
        guard next != activity else { return }
        activity = next
        publish(.activity(next))
    }

    private func publish(_ signal: Signal) {
        for observer in observers { observer(signal) }
    }
}

extension AppActivityFeed: DictationActivity {
    func dictationPhaseChanged(_ phase: DictationSession.Phase) {
        dictation = Self.activity(of: phase)
        update()
    }

    func dictationLevel(_ level: Float) { publish(.level(level)) }

    func dictationTextLanded() { publish(.textLanded) }

    /// Delivery is the tail of transcribing to the user: no separate state.
    private static func activity(of phase: DictationSession.Phase) -> AppActivity {
        switch phase {
        case .idle: return .idle
        case .recording: return .dictating
        case .transcribing, .delivering: return .transcribing
        }
    }
}
