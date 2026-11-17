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

    var summariesNote: String {
        SummarySettingsCopy.note(summaryAvailability, provider: configStore.config.summaryProviderChoice)
    }

    /// Re-reads availability (Apple Intelligence may have been switched on,
    /// or finished getting ready, since Settings was last looked at).
    func refreshSummaryAvailability() {
        openRouterState.hasKey = openRouter.keys.hasKey()
        objectWillChange.send()
    }

    private var summaryAvailability: SummarizerAvailability {
        summaryCatalog.availability(of: configStore.config.summaryProviderChoice)
    }
}

/// What the Meeting Summaries card says. Pure.
enum SummarySettingsCopy {
    static let title = "Summarize meetings"

    /// Under the switch: what it does, or why it can't here.
    static func note(_ availability: SummarizerAvailability, provider: SummaryProvider) -> String {
        switch availability {
        case .available:
            return provider.settingsNote
        case .unavailable(let reason):
            return reason.explanation
        }
    }
}
