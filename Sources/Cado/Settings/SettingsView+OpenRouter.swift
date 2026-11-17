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
        if viewModel.openRouterState.awaitingConsent {
            openRouterConsent
        } else if viewModel.summaryProviderSelection == .openRouter {
            openRouterSettings
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
                        get: { viewModel.openRouterModel },
                        set: { viewModel.setOpenRouterModel($0) })
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
            SettingsRow("Other model") {
                TextField("provider/model-name", text: Binding(
                    get: { viewModel.openRouterModel },
                    set: { viewModel.setOpenRouterModel($0) }))
                    .frame(maxWidth: 260)
            }
            StatusLine(text: viewModel.openRouterState.refreshError ?? OpenRouterCopy.modelNote,
                       tone: viewModel.openRouterState.refreshError == nil ? .note : .problem)
                .padding(.bottom, 8)
        }
    }
}
