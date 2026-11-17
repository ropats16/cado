import Foundation

/// Per-provider wording and the app's one catalog (#34, prep for #35), kept
/// beside `SummaryProvider` so Settings and error text name whichever
/// provider is selected.
extension SummaryProvider {
    /// What the provider is called to the user.
    var displayName: String {
        switch self {
        case .onDevice: return "Apple Intelligence"
        case .openRouter: return "OpenRouter"
        }
    }

    /// Settings, under the switch, when this provider can run: what it does
    /// and where the transcript goes.
    var settingsNote: String {
        switch self {
        case .onDevice:
            return "Key points, decisions and action items in English, written on this Mac by Apple Intelligence."
        case .openRouter:
            return "After a meeting note is saved, its text is sent over the internet to OpenRouter and the company "
                + "that runs the model you chose, and the summary they write is added to the note. Only the "
                + "meeting's text is sent, never audio. Turn this off or switch back to Apple Intelligence to stop."
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
    private let openRouter: OpenRouterSetup

    init(config: @escaping () -> Config, live: SummarizerCatalog = LiveSummarizerCatalog(),
         openRouter: OpenRouterSetup = .inert) {
        self.config = config
        self.live = live
        self.openRouter = openRouter
    }

    /// OpenRouter needs the user's confirmation and a key; without either,
    /// it is unavailable and nothing is ever sent.
    func availability(of provider: SummaryProvider) -> SummarizerAvailability {
        guard provider == .openRouter else { return live.availability(of: provider) }
        guard readConfig().openRouterConsent else { return .unavailable(.notSetUp(OpenRouterSetup.noConsentSentence)) }
        guard openRouter.keys.hasKey() else { return .unavailable(.notSetUp(OpenRouterSetup.noKeySentence)) }
        return .available
    }

    /// Called off the main actor (the key is read from the Keychain here).
    func summarizer(for provider: SummaryProvider) -> MeetingSummarizer? {
        guard provider == .openRouter else { return live.summarizer(for: provider) }
        guard availability(of: provider).isAvailable, let key = openRouter.keys.load(), !key.isEmpty else { return nil }
        let keys = openRouter.keys
        let read = readConfig
        // Read live before every send: consent withdrawn, the key removed or
        // another provider chosen stops a run in progress.
        return OpenRouterSummarizer(model: OpenRouterModels.effective(read().openRouterModel), apiKey: key,
                                    transport: openRouter.transport,
                                    allowed: {
                                        let config = read()
                                        return config.openRouterConsent && config.summaryProviderChoice == .openRouter && keys.hasKey()
                                    })
    }

    /// The config, read on the main thread (it is only ever changed there);
    /// callable from any thread.
    private var readConfig: @Sendable () -> Config {
        nonisolated(unsafe) let config = config
        return {
            if Thread.isMainThread { return config() }
            return DispatchQueue.main.sync { config() }
        }
    }
}

/// The note's attribution names the model this summarizer used.
extension OpenRouterSummarizer {
    var attributionModel: String? { model }
}
