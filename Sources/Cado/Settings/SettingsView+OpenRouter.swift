import SwiftUI

extension SettingsView {
    /// Who writes summaries, and for OpenRouter its confirmation, key and
    /// model (#35). Shown inside the Meeting Summaries card.
    @ViewBuilder var summaryProviderRows: some View {
        CardDivider()
        SettingsRow("Written by") {
            Picker("Written by", selection: Binding(
                get: { viewModel.summaryProviderSelection },
                set: { viewModel.chooseSummaryProvider($0) })
            ) {
                ForEach(SummaryProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .pickerWidth()
        }
        if viewModel.showsOpenRouterConsent {
            openRouterConsent
        } else if viewModel.showsOpenRouterSettings {
            openRouterSettings
        } else if viewModel.showsOpenRouterKeyOnly {
            openRouterKeyOnly
        }
    }

    /// The warning and the explicit confirmation: nothing is chosen until
    /// the button is pressed.
    private var openRouterConsent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(OpenRouterCopy.warningTitle).font(.headline).foregroundStyle(Brand.Palette.ink)
            StatusLine(text: OpenRouterCopy.warning, tone: .problem)
            HStack {
                Spacer()
                Button("Cancel") { viewModel.cancelOpenRouter() }
                Button(OpenRouterCopy.confirm) { viewModel.confirmOpenRouter() }
            }
        }
        .settingsRowPadding()
    }

    /// A key is still stored but Apple Intelligence is selected.
    private var openRouterKeyOnly: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardDivider()
            SettingsRow("OpenRouter API key") {
                HStack {
                    Text("Saved in Keychain").foregroundStyle(Brand.Palette.inkSecondary)
                    Button("Remove Key") { viewModel.removeOpenRouterKey() }
                }
            }
            StatusLine(text: OpenRouterCopy.keyUnusedNote, tone: .note).padding(.bottom, 8)
        }
    }

    private var openRouterSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardDivider()
            SettingsRow("OpenRouter API key") {
                if viewModel.openRouterState.hasKey {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(Brand.Palette.inkSecondary)
                        Button("Remove Key") { viewModel.removeOpenRouterKey() }
                    }
                } else {
                    HStack {
                        SecureField("Paste key", text: Binding(
                            get: { viewModel.openRouterState.keyDraft },
                            set: { viewModel.openRouterState.keyDraft = $0 }))
                            .frame(maxWidth: 220)
                            .onSubmit { viewModel.saveOpenRouterKey() }
                        Button("Save Key") { viewModel.saveOpenRouterKey() }
                    }
                }
            }
            StatusLine(text: viewModel.openRouterState.keyError ?? OpenRouterCopy.keyNote,
                       tone: viewModel.openRouterState.keyError == nil ? .note : .problem)
            CardDivider()
            SettingsRow("Model") {
                HStack {
                    Picker("Model", selection: Binding(
                        get: { viewModel.openRouterModelSelection },
                        set: { viewModel.chooseOpenRouterModel($0) })
                    ) {
                        ForEach(viewModel.openRouterModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerWidth()
                    Button(viewModel.openRouterState.refreshing ? "Refreshing…" : "Refresh") {
                        Task { await viewModel.refreshOpenRouterModels() }
                    }
                    .disabled(viewModel.openRouterState.refreshing)
                }
            }
            if viewModel.openRouterState.typingModel {
                SettingsRow("Model name") { OpenRouterModelNameField(viewModel: viewModel) }
                if let error = viewModel.openRouterState.modelError {
                    StatusLine(text: error, tone: .problem)
                }
            }
            StatusLine(text: viewModel.openRouterState.refreshError ?? OpenRouterCopy.modelNote,
                       tone: viewModel.openRouterState.refreshError == nil ? .note : .problem)
                .padding(.bottom, 8)
        }
    }
}

/// The typed model name: a draft, used only on Return or when the field is
/// left, and only if it's shaped like a model id.
private struct OpenRouterModelNameField: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var focused: Bool

    var body: some View {
        TextField("provider/model-name", text: $viewModel.openRouterState.modelDraft)
            .focused($focused)
            .frame(maxWidth: 260)
            .onSubmit { viewModel.commitOpenRouterModelDraft() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { viewModel.commitOpenRouterModelDraft() }
            }
    }
}
