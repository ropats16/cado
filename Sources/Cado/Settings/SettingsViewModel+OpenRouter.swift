import Foundation

/// Settings' provider choice, key and model for OpenRouter summaries (#35).
extension SettingsViewModel {
    /// What the picker shows: OpenRouter while its confirmation is open.
    var summaryProviderSelection: SummaryProvider {
        showsOpenRouterConsent ? .openRouter : configStore.config.summaryProviderChoice
    }

    /// The confirmation card is up: the user just picked OpenRouter, or the
    /// config (hand-edited) names OpenRouter without a confirmation.
    var showsOpenRouterConsent: Bool {
        openRouterState.awaitingConsent
            || (configStore.config.summaryProviderChoice == .openRouter && !configStore.config.openRouterConsent)
    }

    /// The full OpenRouter settings (key, model): chosen and confirmed.
    var showsOpenRouterSettings: Bool {
        !showsOpenRouterConsent && configStore.config.summaryProviderChoice == .openRouter
    }

    /// A key is stored but OpenRouter isn't in use: only its removal is offered.
    var showsOpenRouterKeyOnly: Bool {
        !showsOpenRouterConsent && !showsOpenRouterSettings && openRouterState.hasKey
    }

    /// The picker changed. OpenRouter is never selected here without the
    /// confirmation step (`confirmOpenRouter`); going back to Apple
    /// Intelligence also withdraws the confirmation, so choosing OpenRouter
    /// again asks again.
    func chooseSummaryProvider(_ provider: SummaryProvider) {
        switch provider {
        case .onDevice:
            openRouterState.awaitingConsent = false
            openRouterState.keyDraft = ""
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

    /// Cancel: nothing is chosen. A hand-edited OpenRouter choice with no
    /// confirmation goes back to Apple Intelligence.
    func cancelOpenRouter() {
        openRouterState.awaitingConsent = false
        openRouterState.keyDraft = ""
        if configStore.config.summaryProviderChoice == .openRouter, !configStore.config.openRouterConsent {
            configStore.update { $0.summaryProvider = SummaryProvider.onDevice.rawValue }
        }
        refreshSummaryAvailability()
    }

    /// Forget the typed key (Settings closed or switched away): secrets
    /// don't wait in this long-lived object.
    func clearOpenRouterKeyDraft() {
        guard !openRouterState.keyDraft.isEmpty else { return }
        openRouterState.keyDraft = ""
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
        let removed = openRouter.keys.delete()
        openRouterState.keyDraft = ""
        openRouterState.keyError = removed ? nil : "The key couldn't be removed from your Keychain."
        refreshSummaryAvailability()
    }

    // MARK: - Model

    /// The model in use (the default when none is set).
    var openRouterModel: String { OpenRouterModels.effective(configStore.config.openRouterModel) }

    /// What the model picker shows: "Other…" while a name is being typed.
    var openRouterModelSelection: String {
        openRouterState.typingModel ? OpenRouterModelEntry.other : openRouterModel
    }

    /// The picker changed: a listed model is used at once; "Other…" opens
    /// the name field (the model in use stays until a valid name is entered).
    func chooseOpenRouterModel(_ id: String) {
        openRouterState.modelError = nil
        if id == OpenRouterModelEntry.other {
            openRouterState.modelDraft = configStore.config.openRouterModel
            openRouterState.typingModel = true
            return
        }
        openRouterState.typingModel = false
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
        configStore.update { $0.openRouterModel = id }
    }

    /// Sets a listed model (a name from the picker's choices).
    func setOpenRouterModel(_ id: String) { chooseOpenRouterModel(id) }

    /// The typed name was submitted or left: used only if it's shaped like
    /// a model id.
    func commitOpenRouterModelDraft() {
        let id = openRouterState.modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard OpenRouterModelEntry.isValid(id) else {
            openRouterState.modelError = OpenRouterModelEntry.invalidMessage
            return
        }
        openRouterState.modelError = nil
        openRouterState.typingModel = false
        objectWillChange.send()
        configStore.update { $0.openRouterModel = id }
    }

    /// The picker's choices: the curated few, a fetched list if the user
    /// refreshed, and the one in use.
    var openRouterModelChoices: [String] {
        var seen = Set<String>()
        return (OpenRouterModels.curated + openRouterState.fetchedModels + [openRouterModel])
            .filter { seen.insert($0).inserted } + [OpenRouterModelEntry.other]
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
    /// "Other…" is chosen: the name being typed, not yet in use.
    var typingModel = false
    var modelDraft = ""
    var modelError: String?
    var fetchedModels: [String] = []
    var refreshing = false
    var refreshError: String?
}

/// The "Other…" model entry. Pure.
enum OpenRouterModelEntry {
    static let other = "Other…"
    static let invalidMessage = "That doesn't look like a model name. Use the form provider/model-name, like openai/gpt-4o-mini."

    /// `provider/model`: letters, digits and . - _ : only.
    static func isValid(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
    }
}

/// What the OpenRouter card says. Pure.
enum OpenRouterCopy {
    static let warningTitle = "Send meeting text to OpenRouter?"
    static let warning = "If you confirm and save an API key, Cado sends the text of every new meeting to OpenRouter "
        + "automatically, right after the meeting is saved, for as long as Summarize meetings is on. It goes to "
        + "OpenRouter and to the company that runs the model you pick. Cado asks OpenRouter to use only providers that "
        + "don't keep or train on it, but their terms and retention policies apply, not Cado's. Audio is never sent. "
        + "Nothing is sent unless you confirm here. To stop, switch back to Apple Intelligence or choose Remove Key."
    static let confirm = "Send Meeting Text to OpenRouter"
    static let keyNote = "Your key is kept in your Mac's Keychain, not in Cado's settings. Get one at openrouter.ai."
    static let keyUnusedNote = "Saved key, not used while Apple Intelligence writes summaries. Remove it if you no longer want it kept."
    static let modelNote = "Any model name from openrouter.ai/models works. The list is short on purpose; Refresh asks "
        + "OpenRouter for its full list. Because Cado only allows providers that don't keep or train on your text, "
        + "some models may not be available."
    /// Above the card while the confirmation is open: nothing about on-device availability.
    static let pendingNote = "Nothing is sent anywhere unless you confirm below."
}
