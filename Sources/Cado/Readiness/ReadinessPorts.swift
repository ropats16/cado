import Foundation

// The seams between `ReadinessMonitor` and the rest of the app: what the
// permissions are (polled), what the engine is doing and whether the hotkey
// tap is up (both pushed in). Tests drive the monitor with fakes of all of
// them. Main thread only.

enum AccessibilityPermission: Equatable { case granted, denied }

enum MicrophonePermission: Equatable { case authorized, denied, restricted, notDetermined }

/// System-audio recording (Core Audio process taps), for meetings only —
/// never part of dictation readiness (`AppReadiness`).
///
/// Only what can be known truthfully: no public API reads or requests the
/// permission. The system asks the first time a tap's device starts, and a
/// tap without the grant delivers silence, not an error. So the one proof of
/// a grant is a capture that delivered sound; silence proves nothing (nothing
/// may have played), and "denied" can't be told apart from "not asked yet".
enum SystemAudioPermission: Equatable {
    /// macOS before 14.2: no process taps.
    case unsupported
    /// Not known: never asked, denied, or granted but nothing heard yet this
    /// run. Recording may still work; the first one shows the system prompt.
    case unconfirmed
    /// A system-audio capture this run delivered sound: granted.
    case confirmed

    init(supported: Bool, heardSound: Bool) {
        self = !supported ? .unsupported : heardSound ? .confirmed : .unconfirmed
    }
}

/// Reads the permissions the app needs. Cheap: polled every few seconds.
protocol PermissionProbe: AnyObject {
    var accessibility: AccessibilityPermission { get }
    var microphone: MicrophonePermission { get }
    var systemAudio: SystemAudioPermission { get }
}

/// What readiness needs to know about the engine: its status, and enough
/// about its model to tell the user how to fix a missing or broken model.
struct EngineReadiness: Equatable {
    var status: TranscriptionStatus
    /// `ModelSpec.path`: a file, a directory, or an OS-managed model's id.
    var modelPath: String
    /// How to get the model, from its engine's descriptor; nil for a custom
    /// file (or an engine with nothing to suggest).
    var download: ModelDownloadHint?
    /// Loading it now is its first load on this Mac (a Core ML compile,
    /// `EngineRegistry.isFirstLoad`), so loading says it'll take a while.
    var isFirstLoad = false
}

/// The global hotkey tap. `HotkeyManager.start()` only says installed or not;
/// a tap the system disables is re-enabled inside the manager, so it never
/// shows up here.
enum HotkeyTapHealth: Equatable {
    /// No tap yet: not attempted, or presumed dead after Accessibility was
    /// revoked.
    case notInstalled
    case installed
    /// The last install attempt failed.
    case failed
}
