import Foundation

/// Settings' provider choice, key and model for OpenRouter summaries (#35).
extension SettingsViewModel {
    /// What the picker shows: OpenRouter while its confirmation is open.
    var summaryProviderSelection: SummaryProvider {
        openRouterState.awaitingConsent ? .openRouter : configStore.config.summaryProviderChoice
    }

    /// The picker changed. OpenRouter is never selected here without the
    /// confirmation step (`confirmOpenRouter`); going back to Apple
    /// Intelligence also withdraws the confirmation, so choosing OpenRouter
    /// again asks again.
    func chooseSummaryProvider(_ provider: SummaryProvider) {
        switch provider {
        case .onDevice:
            openRouterState.awaitingConsent = false
            configStore.update { $0.summaryProvider = provider.rawValue; $0.openRouterConsent = false }
        case .openRouter:
            if configStore.config.openRouterConsent {
                configStore.update { $0.summaryProvider = provider.rawValue }
            } else {
                openRouterState.awaitingConsent = true
            }
        }
        refreshSummaryAvailability()
    }

    /// "Send meeting text to OpenRouter" was confirmed.
    func confirmOpenRouter() {
        openRouterState.awaitingConsent = false
        configStore.update {
            $0.openRouterConsent = true
            $0.summaryProvider = SummaryProvider.openRouter.rawValue
        }
        refreshSummaryAvailability()
    }

    func cancelOpenRouter() {
        openRouterState.awaitingConsent = false
        refreshSummaryAvailability()
    }

    // MARK: - Key

    /// Puts the typed key in the Keychain and forgets the typed copy.
    func saveOpenRouterKey() {
        let key = openRouterState.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { openRouterState.keyError = "Paste your OpenRouter API key first."; return }
        guard openRouter.keys.save(key) else {
            openRouterState.keyError = "The key couldn't be saved to your Keychain."
            return
        }
        openRouterState.keyDraft = ""
        openRouterState.keyError = nil
        refreshSummaryAvailability()
    }

    func removeOpenRouterKey() {
        openRouter.keys.delete()
        openRouterState.keyDraft = ""
        openRouterState.keyError = nil
        refreshSummaryAvailability()
    }

    // MARK: - Model

    /// The model in use (the default when none is set).
    var openRouterModel: String { OpenRouterModels.effective(configStore.config.openRouterModel) }

    func setOpenRouterModel(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
        configStore.update { $0.openRouterModel = id }
    }

    /// The picker's choices: the curated few, a fetched list if the user
    /// refreshed, and the one in use.
    var openRouterModelChoices: [String] {
        var seen = Set<String>()
        return (OpenRouterModels.curated + openRouterState.fetchedModels + [openRouterModel])
            .filter { seen.insert($0).inserted }
    }

    /// Asks OpenRouter's public list; only from the Refresh button.
    func refreshOpenRouterModels() async {
        openRouterState.refreshing = true
        openRouterState.refreshError = nil
        do {
            openRouterState.fetchedModels = try await OpenRouterModels.fetch(using: openRouter.transport)
        } catch {
            openRouterState.refreshError = "Couldn't get OpenRouter's model list. You can still type a model name."
        }
        openRouterState.refreshing = false
    }
}

/// The OpenRouter card's own state. The typed key lives here only until it
/// is saved to the Keychain.
struct OpenRouterCardState: Equatable {
    var awaitingConsent = false
    var hasKey = false
    var keyDraft = ""
    var keyError: String?
    var fetchedModels: [String] = []
    var refreshing = false
    var refreshError: String?
}

/// What the OpenRouter card says. Pure.
enum OpenRouterCopy {
    static let warningTitle = "Send meeting text to OpenRouter?"
    static let warning = "To write a summary, Cado sends the meeting's text (what was said, as text) over the internet "
        + "to OpenRouter, which passes it on to the company that runs the model you choose. It leaves this Mac and is "
        + "handled under their terms, not Cado's. Audio is never sent. Cado sends nothing unless you confirm here and "
        + "add an API key, and you can switch back to Apple Intelligence at any time."
    static let confirm = "Send Meeting Text to OpenRouter"
    static let keyNote = "Your key is kept in your Mac's Keychain, not in Cado's settings. Get one at openrouter.ai."
    static let modelNote = "Any model name from openrouter.ai/models works. The list is short on purpose; Refresh asks "
        + "OpenRouter for its full list."
}
