import Foundation

/// Per-provider wording and the app's one catalog (#34, prep for #35), kept
/// beside `SummaryProvider` so Settings and error text name whichever
/// provider is selected.
extension SummaryProvider {
    /// What the provider is called to the user.
    var displayName: String {
        switch self {
        case .onDevice: return "Apple Intelligence"
        }
    }

    /// Settings, under the switch, when this provider can run: what it does
    /// and where the transcript goes.
    var settingsNote: String {
        switch self {
        case .onDevice:
            return "After a meeting note is saved, Apple Intelligence adds a summary to it: key points, decisions "
                + "and action items. It runs on this Mac, so nothing is sent anywhere. You can summarize a note "
                + "again from the Library."
        }
    }
}

extension SummarizerUnavailable {
    /// Might clear by itself soon (the Library still offers Summarize, so
    /// it can be run later); the others need the user to change something.
    var isTemporary: Bool { self == .modelNotReady }
}

/// The app's one catalog: reads the config (provider choices now; keys and
/// endpoints for #35) through `config` and hands each provider's
/// availability and summarizer. Made once in `AppDelegate` and given to
/// `MeetingSummaries` and Settings.
final class ConfiguredSummarizerCatalog: SummarizerCatalog {
    private let config: () -> Config
    private let live: SummarizerCatalog

    init(config: @escaping () -> Config, live: SummarizerCatalog = LiveSummarizerCatalog()) {
        self.config = config
        self.live = live
    }

    func availability(of provider: SummaryProvider) -> SummarizerAvailability { live.availability(of: provider) }
    func summarizer(for provider: SummaryProvider) -> MeetingSummarizer? { live.summarizer(for: provider) }
}
