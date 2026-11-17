import SwiftUI

extension SettingsView {
    /// Speech Model tab: engine, model, language, how long it stays loaded.
    var modelTab: some View {
        SettingsCard {
            SettingsRow("Engine") {
                Picker("Engine",
                       selection: Binding(
                           get: { viewModel.engineRow },
                           set: { viewModel.selectEngine($0) }
                       )) {
                    ForEach(viewModel.engineChoices, id: \.self) { choice in
                        switch choice {
                        case .automatic: Text(viewModel.automaticEngineLabel).tag(choice)
                        case .engine(let kind): Text(kind.displayName).tag(choice)
                        }
                    }
                }
                .pickerWidth()
            }
            if let note = viewModel.engineNote {
                StatusLine(text: note).padding(.bottom, 8)
            }
            CardDivider()

            let lists = viewModel.modelLists
            SettingsRow("Model") {
                Picker("Model",
                       selection: Binding(
                           get: { viewModel.modelRow },
                           set: { viewModel.selectModel($0) }
                       )) {
                    Text(viewModel.automaticLabel).tag(ModelRow.automatic)
                    if let custom = viewModel.customModelName {
                        Text("Custom file: \(custom)").tag(ModelRow.custom)
                    }
                    ForEach(lists.downloaded) { model in
                        Text(model.label).tag(ModelRow.catalog(model.id))
                    }
                    Section(viewModel.notDownloadedHeading) {
                        ForEach(lists.notDownloaded) { model in
                            Text(model.label).tag(ModelRow.catalog(model.id)).disabled(true)
                        }
                    }
                }
                .pickerWidth()
            }

            // whisper.cpp, WhisperKit, Parakeet: a Download button per model not yet installed.
            let downloadable = viewModel.inAppDownloadableModels
            if !downloadable.isEmpty {
                // Open or closed: the view model decides (it opens for a
                // download, a failure or a missing pick).
                DisclosureGroup(isExpanded: Binding(
                    get: { viewModel.isDownloadListExpanded },
                    set: { viewModel.setDownloadListExpanded($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(downloadable) { model in
                            ModelDownloadRow(model: model, viewModel: viewModel)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 18)   // under the label, past the chevron
                } label: {
                    Text(SettingsViewModel.downloadListTitle).foregroundStyle(Brand.Palette.ink)
                }
                .settingsRowPadding()
            }
            CardDivider()

            SettingsRow("Language") {
                Picker("Language",
                       selection: Binding(
                           get: { viewModel.isLanguageSelectable ? viewModel.language : "en" },
                           set: { viewModel.setLanguage($0) }
                       )) {
                    ForEach(viewModel.languageOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerWidth()
                .disabled(!viewModel.isLanguageSelectable)
            }

            // Apple Speech: the OS-managed model for the language.
            if let state = viewModel.speechAssetLabel {
                CardDivider()
                HStack(spacing: 12) {
                    Text(SettingsViewModel.appleSpeechRow).foregroundStyle(Brand.Palette.ink)
                    Spacer()
                    Text(state).foregroundStyle(Brand.Palette.inkSecondary)
                    if viewModel.canDownloadSpeechModel {
                        Button("Download") { Task { await viewModel.downloadSpeechModel() } }
                    }
                }
                .settingsRowPadding()
                if let error = viewModel.speechAssetError {
                    StatusLine(text: error, tone: .problem).padding(.bottom, 8)
                }
            }
            CardDivider()

            SettingsRow("Keep model loaded") {
                Picker("Keep model loaded",
                       selection: Binding(
                           get: { viewModel.keepWarm },
                           set: { viewModel.setKeepWarm($0) }
                       )) {
                    ForEach(KeepWarmChoice.allCases, id: \.self) { choice in
                        Text(viewModel.label(for: choice)).tag(choice)
                    }
                }
                .pickerWidth()
            }

            if let hint = viewModel.modelStatusHint {
                let pending = [.loading, .verifying].contains(viewModel.modelStatus)
                StatusLine(text: hint, tone: pending ? .note : .problem).padding(.bottom, 8)
            }
        }
        .task(id: "\(viewModel.engine.rawValue)|\(viewModel.language)") {
            await viewModel.refreshSpeechAssets()
        }
    }
}

// MARK: - ModelDownloadRow

/// One not-downloaded model: Download, or its progress and Cancel while it
/// downloads; Discard for what a stopped download left; and why the last
/// try failed. Keyed by the row's engine and model, not the selected engine.
struct ModelDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        let key = model.key
        HStack(spacing: 8) {
            Text(model.label).foregroundStyle(Brand.Palette.ink)
            Spacer(minLength: 8)
            if let progress = viewModel.modelDownloadLabel(key) {
                // The bar says "downloading"; beside it just the percent, so
                // the row fits on one line. VoiceOver reads the full label.
                if case .downloading(let fraction)? = viewModel.modelDownloads[key] {
                    ProgressView(value: fraction)
                        .frame(width: 60)
                        .accessibilityHidden(true)
                    Text("\(Int((fraction * 100).rounded(.down)))%")
                        .foregroundStyle(Brand.Palette.inkSecondary).monospacedDigit()
                        .fixedSize()
                        .accessibilityLabel(progress)
                }
                Button("Cancel") { viewModel.cancelModelDownload(key) }
            } else {
                if viewModel.hasPartialDownload(key) {
                    Button("Discard Partial Download") { viewModel.discardPartialDownload(key) }
                }
                Button(viewModel.hasPartialDownload(key) ? "Resume" : "Download") { viewModel.downloadModel(key) }
                    .disabled(!viewModel.canDownloadModel(key))
            }
        }
        .padding(.vertical, 3)
        if let error = viewModel.modelDownloadError(key) {
            StatusLine(text: error, tone: .problem).padding(.bottom, 4)
        }
    }
}

