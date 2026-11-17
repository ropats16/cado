import Foundation

/// Settings' Meeting Summaries card (#34). Read live from the config (no
/// stored state), like the Updates card.
extension SettingsViewModel {
    /// Summarize each meeting note after it's saved.
    var meetingSummaries: Bool { configStore.config.meetingSummaries }

    func setMeetingSummaries(_ on: Bool) {
        objectWillChange.send()
        configStore.update { $0.meetingSummaries = on }
    }

    /// The chosen provider can run on this Mac now.
    var summariesAvailable: Bool { summaryAvailability.isAvailable }

    var summariesNote: String { SummarySettingsCopy.note(summaryAvailability) }

    private var summaryAvailability: SummarizerAvailability {
        SummarySettingsCopy.catalog.availability(of: configStore.config.summaryProviderChoice)
    }
}

/// What the Meeting Summaries card says. Pure, apart from `catalog`.
enum SummarySettingsCopy {
    /// Where the card reads availability (a seam for tests).
    static var catalog: SummarizerCatalog = LiveSummarizerCatalog()

    static let title = "Summarize meetings"

    /// Under the switch: what it does, or why it can't here.
    static func note(_ availability: SummarizerAvailability) -> String {
        switch availability {
        case .available:
            return "After a meeting note is saved, Apple Intelligence adds a summary to it: key points, decisions "
                + "and action items. It runs on this Mac, so nothing is sent anywhere. You can summarize a note "
                + "again from the Library."
        case .unavailable(let reason):
            return reason.explanation
        }
    }
}
