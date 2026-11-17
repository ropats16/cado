import Foundation

/// Settings' "Name meetings from my calendar" card (#38). The switch is the
/// opt-in: turning it on is what asks macOS for Calendar access (never at
/// launch). State is read live (config + the system's setting), like Updates.
extension SettingsViewModel {
    /// The switch as shown: chosen AND allowed. If access is taken away in
    /// System Settings, it is switched off for real (see `refreshCalendarAccess`),
    /// so naming never silently resumes when access comes back.
    var nameMeetingsFromCalendar: Bool {
        configStore.config.nameMeetingsFromCalendar && calendar.access == .granted
    }

    var calendarNote: String { CalendarSettingsCopy.note(calendar.access) }

    /// Show "Open System Settings" under the note.
    var calendarNeedsSystemSettings: Bool { calendar.access == .denied }

    func setNameMeetingsFromCalendar(_ on: Bool) {
        guard on else { return saveNameMeetingsFromCalendar(false) }
        switch calendar.access {
        case .granted:
            saveNameMeetingsFromCalendar(true)
        case .notDetermined:
            // The one place the system prompt can appear: the user just switched this on.
            calendar.requestAccess { [weak self] access in
                self?.saveNameMeetingsFromCalendar(access == .granted)
            }
        case .denied, .restricted, .unavailable:
            clearIfBlocked()   // stays off; the note says why and how to allow it
        }
    }

    func openCalendarSettings() { calendar.openSettings() }

    /// Settings (or the app) is on screen again, maybe back from System
    /// Settings: re-read the system's setting and redraw. If it was taken away
    /// while the choice was on, the choice is cleared, so the switch is
    /// truthful and the user turns it on again after allowing it.
    func refreshCalendarAccess() {
        clearIfBlocked()
        objectWillChange.send()
    }

    private func clearIfBlocked() {
        if configStore.config.nameMeetingsFromCalendar, calendar.access == .denied || calendar.access == .restricted {
            saveNameMeetingsFromCalendar(false)
        }
        objectWillChange.send()
    }

    private func saveNameMeetingsFromCalendar(_ on: Bool) {
        objectWillChange.send()
        configStore.update { $0.nameMeetingsFromCalendar = on }
    }
}

/// What the calendar card says. Plain words, no jargon. Pure.
enum CalendarSettingsCopy {
    static let title = "Name meetings from my calendar"

    static func note(_ access: CalendarAccess) -> String {
        switch access {
        case .notDetermined, .granted:
            return "A meeting that starts around an event in your calendar is named after it, and the note lists the "
                + "other people's names. Otherwise it's named after the app and the time. Cado asks to see your "
                + "calendar when you switch this on and only reads it on this Mac. The event's title and the names of "
                + "the people invited are saved in the note, so they go wherever your notes folder syncs."
        case .denied:
            return "Cado isn't allowed to see your calendar. To allow it, open System Settings › Privacy & Security › "
                + "Calendars, turn Cado on, then switch this on again."
        case .restricted:
            return "This Mac doesn't let Cado see calendars (an administrator has turned that off)."
        case .unavailable:
            return "This copy of Cado can't see your calendar."
        }
    }
}
