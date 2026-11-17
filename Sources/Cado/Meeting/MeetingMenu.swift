import Foundation

/// The app a meeting records as "Others": only its audio, never the whole Mac's.
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
    /// Finishing a meeting an earlier run didn't (#31): reading it back
    /// (`total` 0), then `done` of `total` passages.
    case recovering(app: String, done: Int, total: Int)
}

/// The meeting part of the status menu: one main item (a click, a submenu of
/// apps, or disabled) and an optional detail line. Pure.
struct MeetingMenuContent: Equatable {
    enum Action: Equatable {
        case start(MeetingApp)
        case stop
        /// An answer to "Record this meeting?" / "Stop recording?" (#32).
        case answer(MeetingDetector.Prompt, yes: Bool)
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
    /// Title of an item that opens Privacy & Security › Screen & System
    /// Audio Recording; nil = no such item.
    var systemAudioSettings: String?
    /// The status item shows recording (glyph + `elapsed`).
    var isRecording: Bool
    /// Elapsed time while recording, for the menu bar ("12:34").
    var elapsed: String?
    /// The menu bar's text by the avocado: the elapsed time, and "Record?"
    /// or "Stop?" while one is asked (#32).
    var barTitle: String?
    /// The other answer to what's asked: "Not Now" or "Keep Recording" (#32).
    var promptRow: Row?
    /// A second detail line while Cado asks (#32), since `detail` holds the
    /// question: the system-audio issue, or a side that stopped recording.
    var note: String?

    var isEnabled: Bool { action != nil || choices != nil }

    static let unsupportedDetail = SystemAudioIssue.unsupportedOS.menuLine
    static let noMeetingAppTitle = "No meeting app found — record another app:"
    static let systemAudioSettingsTitle = "Open System Audio Recording Settings…"

    /// `systemAudio`: the readiness module's issue for the meeting menu
    /// (`SystemAudioReadiness.issue(for:lastMeetingThemSilent:)`), shown
    /// while idle. `prompt`: what `MeetingDetector` asks (#32).
    init(status: MeetingStatus, choice: MeetingAppChoice, now: TimeInterval, systemAudio: SystemAudioIssue? = nil,
         prompt: MeetingDetector.Prompt? = nil) {
        isRecording = false
        elapsed = nil
        action = nil
        choices = nil
        detail = nil
        systemAudioSettings = nil
        barTitle = nil
        promptRow = nil
        note = nil
        defer { barTitle = Self.barTitle(elapsed: elapsed, prompt: promptRow == nil ? nil : prompt) }
        switch (status, prompt) {
        case (.idle, .record(let app, _)?):
            title = "Record Meeting (\(app.name))"
            action = .start(app)
            detail = MeetingPromptCopy.recordBody(app.name)
            promptRow = Row(title: MeetingPromptCopy.notNow, action: .answer(prompt!, yes: false))
            if choice != .unsupported, let systemAudio, systemAudio != .unsupportedOS {
                note = systemAudio.menuLine
                if systemAudio == .heardOnlySilence { systemAudioSettings = Self.systemAudioSettingsTitle }
            }
            return
        case (.recording(let recorded, let startedAt, let lost), .stop(let app, _)?):
            let time = MeetingNote.clock(now - startedAt)
            title = "Stop Recording — \(time)"
            action = .stop
            isRecording = true
            elapsed = time
            detail = MeetingPromptCopy.stopBody(app.name)
            promptRow = Row(title: MeetingPromptCopy.keepRecording, action: .answer(prompt!, yes: false))
            note = Self.stoppedLine(app: recorded, lost: lost)
            return
        default:
            break
        }
        switch status {
        case .recording(let app, let startedAt, let lost):
            let time = MeetingNote.clock(now - startedAt)
            title = "Stop Recording — \(time)"
            action = .stop
            isRecording = true
            elapsed = time
            detail = Self.stoppedLine(app: app, lost: lost) ?? "Recording \(app) and your microphone"
        case .transcribing(let app, let done, let total):
            title = total > 0 ? "Transcribing Meeting… \(done) of \(total)" : "Finishing Meeting…"
            detail = "Meeting with \(app)"
        case .recovering(let app, let done, let total):
            title = total > 0 ? "Recovering Meeting… \(done) of \(total)" : "Recovering Meeting…"
            detail = "A meeting with \(app) that wasn't finished. Record Meeting is back once it's done."
        case .idle:
            title = "Record Meeting"
            if choice != .unsupported, let systemAudio, systemAudio != .unsupportedOS {
                detail = systemAudio.menuLine
                if systemAudio == .heardOnlySilence { systemAudioSettings = Self.systemAudioSettingsTitle }
            }
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

    /// What stopped recording; nil when both sides record.
    private static func stoppedLine(app: String, lost: Set<MeetingSpeaker>) -> String? {
        switch (lost.contains(.me), lost.contains(.them)) {
        case (false, false): return nil
        case (false, true): return "\(app)'s audio stopped — recording your microphone only"
        case (true, false): return "Microphone stopped — recording \(app) only"
        case (true, true): return "Recording stopped"
        }
    }
}
