import Foundation

/// The app a meeting records as "Them": only its audio, never the whole Mac's.
struct MeetingApp: Equatable {
    let name: String
    let bundleID: String
    let target: SystemAudioTarget

    init(name: String, bundleID: String, target: SystemAudioTarget) {
        self.name = name
        self.bundleID = bundleID
        self.target = target
    }

    init(_ app: RecordableApp) {
        self.init(name: app.name, bundleID: app.bundleID, target: app.target)
    }
}

/// Which app "Record Meeting" would record. Pure.
enum MeetingAppChoice: Equatable {
    /// macOS before 14.2: no process taps, so no meeting recording.
    case unsupported
    /// Exactly one known meeting app is running: record it.
    case one(RecordableApp)
    /// Several known meeting apps (e.g. Zoom and a browser): the user picks.
    case several([RecordableApp])
    /// No known meeting app, but these apps could be recorded.
    case noMeetingApp(others: [RecordableApp])
    /// Nothing running could be recorded.
    case nothing

    /// `apps` from `RecordableApps.list` (meeting apps first).
    static func decide(supported: Bool, apps: [RecordableApp]) -> MeetingAppChoice {
        guard supported else { return .unsupported }
        let meetingApps = apps.filter(\.isKnownMeetingApp)
        switch meetingApps.count {
        case 1: return .one(meetingApps[0])
        case 0: return apps.isEmpty ? .nothing : .noMeetingApp(others: apps)
        default: return .several(meetingApps)
        }
    }
}

/// What the meeting session is doing, for the menu and the activity feed.
enum MeetingStatus: Equatable {
    case idle
    /// `startedAt` on the session's clock. `lost` = sides no longer recording
    /// (couldn't start, or stopped by themselves).
    case recording(app: String, startedAt: TimeInterval, lost: Set<MeetingSpeaker>)
    /// Captures finishing, then transcription: `done` of `total` passages.
    case transcribing(app: String, done: Int, total: Int)
}

/// The meeting part of the status menu: one main item (a click, a submenu of
/// apps, or disabled) and an optional detail line. Pure.
struct MeetingMenuContent: Equatable {
    enum Action: Equatable {
        case start(MeetingApp)
        case stop
    }

    /// A submenu row: clickable when it has an action, else a label.
    struct Row: Equatable {
        var title: String
        var action: Action?
    }

    var title: String
    /// What a click does; nil with `choices` (a submenu) or when disabled.
    var action: Action?
    /// A submenu of apps to record.
    var choices: [Row]?
    var detail: String?
    /// The status item shows recording (glyph + `elapsed`).
    var isRecording: Bool
    /// Elapsed time while recording, for the menu bar ("12:34").
    var elapsed: String?

    var isEnabled: Bool { action != nil || choices != nil }

    static let unsupportedDetail = "Recording meetings needs macOS 14.2 or later."
    static let noMeetingAppTitle = "No meeting app found — record another app:"

    init(status: MeetingStatus, choice: MeetingAppChoice, now: TimeInterval) {
        isRecording = false
        elapsed = nil
        action = nil
        choices = nil
        detail = nil
        switch status {
        case .recording(let app, let startedAt, let lost):
            let time = MeetingNote.clock(now - startedAt)
            title = "Stop Recording — \(time)"
            action = .stop
            isRecording = true
            elapsed = time
            switch (lost.contains(.me), lost.contains(.them)) {
            case (false, false): detail = "Recording \(app) and your microphone"
            case (false, true): detail = "\(app)'s audio stopped — recording your microphone only"
            case (true, false): detail = "Microphone stopped — recording \(app) only"
            case (true, true): detail = "Recording stopped"
            }
        case .transcribing(let app, let done, let total):
            title = total > 0 ? "Transcribing Meeting… \(done) of \(total)" : "Finishing Meeting…"
            detail = "Meeting with \(app)"
        case .idle:
            title = "Record Meeting"
            switch choice {
            case .unsupported:
                detail = Self.unsupportedDetail
            case .one(let app):
                title = "Record Meeting (\(app.name))"
                action = .start(MeetingApp(app))
            case .several(let apps):
                choices = apps.map { Row(title: $0.name, action: .start(MeetingApp($0))) }
            case .noMeetingApp(let others):
                choices = [Row(title: Self.noMeetingAppTitle, action: nil)]
                    + others.map { Row(title: $0.name, action: .start(MeetingApp($0))) }
            case .nothing:
                detail = "No meeting app is running"
            }
        }
    }
}
