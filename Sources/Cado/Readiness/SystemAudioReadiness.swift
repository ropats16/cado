import Foundation

/// Why a meeting's "Others" track (system audio) might not record, and how to
/// explain it. Meeting-only: dictation readiness (`AppReadiness`) never looks
/// at system audio.
enum SystemAudioIssue: Equatable {
    /// macOS before 14.2: no process taps. Blocks system-audio recording.
    case unsupportedOS
    /// The permission can't be read (`SystemAudioPermission.unconfirmed`).
    /// Doesn't block: the first recording shows the system prompt.
    case permissionUnconfirmed
    /// A capture ran and delivered only silence while the permission was
    /// unconfirmed: nothing played, or recording isn't allowed.
    case heardOnlySilence

    /// Whether system audio can't be recorded at all.
    var blocksRecording: Bool { self == .unsupportedOS }

    /// Whether the fix is in Privacy & Security › Screen & System Audio
    /// Recording (`Permissions.openSystemAudioSettings()`).
    var opensSettings: Bool { self != .unsupportedOS }

    var title: String {
        switch self {
        case .unsupportedOS: return "System audio unavailable"
        case .permissionUnconfirmed: return "System audio not yet confirmed"
        case .heardOnlySilence: return "No system audio captured"
        }
    }

    /// One quiet line for the meeting menu while idle.
    var menuLine: String {
        switch self {
        case .unsupportedOS: return "Recording meetings needs macOS 14.2 or later."
        case .permissionUnconfirmed: return "macOS will ask to allow system audio recording the first time."
        case .heardOnlySilence: return "No sound came from the app in the last meeting."
        }
    }

    var detail: String {
        switch self {
        case .unsupportedOS:
            return "Recording other participants needs macOS 14.2 or later. Only your microphone will be recorded."
        case .permissionUnconfirmed:
            return "macOS asks to allow system audio recording when your first meeting starts. "
                + "If it isn't allowed, turn Cado on in System Settings › Privacy & Security › Screen & System Audio Recording."
        case .heardOnlySilence:
            return "If others were talking, allow Cado in System Settings › Privacy & Security › "
                + "Screen & System Audio Recording, then start the meeting again."
        }
    }
}

/// Pure: what the system-audio permission means for a meeting.
enum SystemAudioReadiness {
    /// Whether a meeting can try to record system audio.
    static func canRecord(_ permission: SystemAudioPermission) -> Bool {
        permission != .unsupported
    }

    /// Before a meeting: what to tell the user, if anything.
    static func issue(for permission: SystemAudioPermission) -> SystemAudioIssue? {
        switch permission {
        case .unsupported: return .unsupportedOS
        case .unconfirmed: return .permissionUnconfirmed
        case .confirmed: return nil
        }
    }

    /// For the meeting menu: `issue(for:)`, except that after a meeting
    /// whose Them was silent (`MeetingSession.lastThemWasSilent`) an
    /// unconfirmed permission is `heardOnlySilence`, which offers Settings.
    static func issue(for permission: SystemAudioPermission, lastMeetingThemSilent: Bool) -> SystemAudioIssue? {
        let issue = issue(for: permission)
        return issue == .permissionUnconfirmed && lastMeetingThemSilent ? .heardOnlySilence : issue
    }

    /// After a system-audio capture (`SystemAudioSource.hasHeardSound`):
    /// silence is worth a hint only while no capture has ever proved the
    /// grant — once confirmed, silence just means nobody else spoke.
    static func issue(afterCaptureHeardSound heardSound: Bool,
                      permission: SystemAudioPermission) -> SystemAudioIssue? {
        guard !heardSound else { return nil }
        switch permission {
        case .unsupported: return .unsupportedOS
        case .unconfirmed: return .heardOnlySilence
        case .confirmed: return nil
        }
    }
}
