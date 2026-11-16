import Foundation

/// What the app as a whole is doing right now: the one value the mascot
/// overlay renders (#19). Flows publish into it; the overlay only observes,
/// nobody commands it.
enum AppActivity: Equatable {
    /// Nothing in flight.
    case idle
    /// A dictation is recording (the mic is live).
    case dictating
    /// A dictation's audio is being turned into text and delivered.
    case transcribing
    /// A meeting is being recorded (#30).
    case meetingLive
}
