import Foundation

/// One row of the "Max meeting length" picker.
struct MaxMeetingChoice: Hashable {
    let minutes: Double
    let label: String
}

/// Settings › Meetings (#32): asking to record when a call starts, the max
/// meeting length, and the meeting hotkey (in Hotkeys). Read straight from
/// the config, so they need no state of their own; a change publishes.
extension SettingsViewModel {
    var meetingDetection: Bool { configStore.config.meetingDetection }

    /// Off: no "Record this meeting?" or "Stop recording?"; the menu, the
    /// hotkey and the mascot still start and stop meetings.
    func setMeetingDetection(_ on: Bool) {
        objectWillChange.send()
        configStore.update { $0.meetingDetection = on }
        onNeedsMenuRefresh()   // the app re-reads it
    }

    /// The Mac can tell which app uses the mic (macOS 14.4+).
    var canDetectMeetings: Bool { CoreAudioMicUsers.isSupported }

    var maxMeetingMinutes: Double { configStore.config.maxMeetingMinutes > 0 ? configStore.config.maxMeetingMinutes : 0 }

    /// The fixed lengths, plus a hand-edited one as "custom".
    var maxMeetingChoices: [MaxMeetingChoice] {
        var minutes = MeetingLimit.choices
        let current = maxMeetingMinutes
        if !minutes.contains(current) {
            minutes.insert(current, at: minutes.firstIndex { $0 <= 0 || $0 > current } ?? minutes.endIndex)
        }
        return minutes.map { m in
            let label = MeetingLimit.label(m)
            return MaxMeetingChoice(minutes: m, label: MeetingLimit.choices.contains(m) ? label : "\(label) (custom)")
        }
    }

    /// Applies from the next meeting.
    func setMaxMeetingMinutes(_ minutes: Double) {
        objectWillChange.send()
        configStore.update { $0.maxMeetingMinutes = minutes }
    }

    var meetingHotkeyDescription: String { configStore.config.meetingHotkey.description }

    /// Saves the meeting hotkey; `commitHotkey` / `resetHotkey` reload the tap.
    func setMeetingHotkey(_ binding: KeyBinding) {
        objectWillChange.send()
        configStore.update { $0.meetingHotkey = binding }
    }

    static let meetingsNote = "When a meeting app starts using the microphone, Cado asks whether to record, "
        + "and when it stops, whether to stop. It never records by itself."
    static let meetingsUnsupportedNote = "Asking needs macOS 14.4 or later. "
        + "Record Meeting in the menu, the hotkey and the mascot still work."
    static let maxMeetingNote = "A meeting stops by itself after this long, and its note is saved as usual. "
        + "Off still stops after 24 hours."
}
