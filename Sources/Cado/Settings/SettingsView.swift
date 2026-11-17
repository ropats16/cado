import SwiftUI
import AppKit

/// Cado's settings window, in the brand's palette and type (SettingsStyles).
/// Bound to a `SettingsViewModel` via
/// intent methods (no two-way Binding with didSet) so the view stays simple
/// and initial load never re-persists config values.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The recorder is now owned by `SettingsViewModel` so `SettingsWindowController`
    /// can reach it via `viewModel.cancelCapture()` from `windowWillClose(_:)`.
    /// Passed explicitly so SwiftUI observes its `@Published` properties.
    @ObservedObject var recorder: HotkeyRecorder
    @Environment(\.colorSchemeContrast) private var contrast
    /// Room for the longest model and engine names before they truncate.
    private static let pickerWidth: CGFloat = 240

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // MARK: Dictation Sounds
                SettingsSection(title: "Dictation Sounds", systemImage: "speaker.wave.2.fill") {
                    SettingsRow("Play start/stop sounds") {
                        Toggle("Play start/stop sounds",
                               isOn: Binding(
                                   get: { viewModel.soundCues },
                                   set: { viewModel.setSoundCues($0) }
                               ))
                    }
                }

                // MARK: Mascot (#20)
                SettingsSection(title: "Mascot", systemImage: "face.smiling") {
                    SettingsRow("Always show the mascot") {
                        Toggle("Always show the mascot",
                               isOn: Binding(
                                   get: { viewModel.mascotAlwaysVisible },
                                   set: { viewModel.setMascotAlwaysVisible($0) }
                               ))
                    }
                    StatusLine(text: "The mascot stays on screen. Click it to start or stop dictating; drag it anywhere.")
                        .padding(.bottom, 8)
                    CardDivider()
                    SettingsRow("Show the mascot in screen shares") {
                        Toggle("Show the mascot in screen shares",
                               isOn: Binding(
                                   get: { viewModel.mascotInScreenShares },
                                   set: { viewModel.setMascotInScreenShares($0) }
                               ))
                    }
                    StatusLine(text: "Off: the mascot is hidden from screen shares and recordings.")
                        .padding(.bottom, 8)
                }

                // MARK: Usage count (#26)
                SettingsSection(title: "Usage Count", systemImage: "chart.bar") {
                    SettingsRow(UsagePingCopy.title) {
                        Toggle(UsagePingCopy.title,
                               isOn: Binding(
                                   get: { viewModel.usagePing },
                                   set: { viewModel.setUsagePing($0) }
                               ))
                    }
                    StatusLine(text: UsagePingCopy.settingsNote)
                        .padding(.bottom, 8)
                }

                // MARK: Startup
                SettingsSection(title: "Startup", systemImage: "power") {
                    SettingsRow("Launch Cado at login") {
                        Toggle("Launch Cado at login",
                               isOn: Binding(
                                   get: { viewModel.launchAtLogin },
                                   set: { viewModel.setLaunchAtLogin($0) }
                               ))
                    }
                    if let err = viewModel.loginError {
                        StatusLine(text: err, tone: .problem).padding(.bottom, 8)
                    }
                }

                updatesSection   // SettingsView+Updates.swift (#24)

                // MARK: Dictation
                SettingsSection(title: "Dictation", systemImage: "timer") {
                    SettingsRow("Max dictation length") {
                        Picker("Max dictation length",
                               selection: Binding(
                                   get: { viewModel.maxDictationSeconds },
                                   set: { viewModel.setMaxDictationSeconds($0) }
                               )) {
                            ForEach(viewModel.maxDictationChoices, id: \.seconds) { choice in
                                Text(choice.label).tag(choice.seconds)
                            }
                        }
                        .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
                    }
                }

                // MARK: Notes (#28)
                SettingsSection(title: "Notes", systemImage: "folder.fill") {
                    HStack(spacing: 8) {
                        Text("Notes folder").foregroundStyle(Brand.Palette.ink)
                        Spacer(minLength: 8)
                        Text(viewModel.notesFolderPath)
                            .foregroundStyle(Brand.Palette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { viewModel.chooseNotesFolder() }
                        Button("Show in Finder") { viewModel.showNotesFolder() }
                    }
                    .settingsRowPadding()
                    StatusLine(text: "Meeting notes (Record Meeting in the menu) are saved here as plain Markdown, so you can point this at an Obsidian vault.")
                        .padding(.bottom, 8)
                    CardDivider()
                    SettingsRow("Keep recent dictations") {
                        Toggle("Keep recent dictations",
                               isOn: Binding(
                                   get: { viewModel.dictationHistory },
                                   set: { viewModel.setDictationHistory($0) }
                               ))
                    }
                    StatusLine(text: "Keeps your last \(RecentDictations.limit) dictations on this Mac, so you can copy one again from the menu. They aren't saved to the notes folder.")
                        .padding(.bottom, 8)
                }

                // MARK: Microphone
                SettingsSection(title: "Microphone", systemImage: "mic.fill") {
                    SettingsRow("Microphone") {
                        Picker("Microphone",
                               selection: Binding(
                                   get: { viewModel.selectedMicUID },
                                   set: { viewModel.selectMic($0) }
                               )) {
                            Text("System Default").tag(String?.none)
                            ForEach(viewModel.micOptions, id: \.uid) { device in
                                Text(device.name).tag(Optional(device.uid))
                            }
                        }
                        .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
                    }
                }

                modelSection

                // MARK: Hotkeys
                SettingsSection(title: "Hotkeys", systemImage: "keyboard") {
                    HotkeyRow(
                        label: ConfigValidator.hold,
                        description: viewModel.holdDescription,
                        isCapturing: recorder.captureTarget == .hold,
                        onRecord: { recorder.startCapture(for: .hold, vm: viewModel) },
                        onReset:  { viewModel.resetHotkey(.hold) }
                    )
                    CardDivider()
                    HotkeyRow(
                        label: ConfigValidator.toggle,
                        description: viewModel.toggleDescription,
                        isCapturing: recorder.captureTarget == .toggle,
                        onRecord: { recorder.startCapture(for: .toggle, vm: viewModel) },
                        onReset:  { viewModel.resetHotkey(.toggle) }
                    )
                    if let warning = viewModel.hotkeyWarning {
                        StatusLine(text: warning, tone: .problem).padding(.bottom, 8)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .font(Brand.Typography.body)
        .toggleStyle(.switch)
        .tint(Brand.Palette.accent)
        .background(Brand.Palette.background)
        .frame(minWidth: 400, idealWidth: 460, minHeight: 380)
        .onDisappear {
            // Window closed mid-capture: remove the monitor and resume the tap.
            recorder.cancelCapture(vm: viewModel)
        }
    }

    // MARK: Header

    /// Parsed once: `Brand.Art.mascot` builds a new image from the SVG per call.
    private static let mascot = Brand.Art.mascot(.idle)

    /// The mascot, the name, and how to dictate with the configured hotkey.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: Self.mascot)
                .resizable()
                .frame(width: 60, height: 60)
                .frame(width: 72, height: 72)
                .background(Brand.Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Brand.Palette.outline(contrast)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cado")
                    .font(Brand.Typography.font(.title, weight: .bold))
                    .foregroundStyle(Brand.Palette.ink)
                Text("Hold \(viewModel.holdDescription) and talk. Let go, and Cado types it for you.")
                    .font(Brand.Typography.font(.callout))
                    .foregroundStyle(Brand.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Model

    private var modelSection: some View {
        SettingsSection(title: "Speech Model", systemImage: "waveform") {
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
                .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
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
                .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
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
                .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
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
                .frame(maxWidth: Self.pickerWidth, alignment: .trailing)
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
private struct ModelDownloadRow: View {
    let model: DownloadableModel
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        let key = model.key
        HStack(spacing: 8) {
            Text(model.label).foregroundStyle(Brand.Palette.ink)
            Spacer(minLength: 8)
            if let progress = viewModel.modelDownloadLabel(key) {
                if case .downloading(let fraction)? = viewModel.modelDownloads[key] {
                    ProgressView(value: fraction)
                        .frame(width: 60)
                        .accessibilityHidden(true)   // the label says it
                }
                Text(progress).foregroundStyle(Brand.Palette.inkSecondary).monospacedDigit()
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

// MARK: - HotkeyRow

/// A single row in the Hotkeys section: shows the current binding, a Record
/// button to start live capture, and a Reset-to-default fallback button.
private struct HotkeyRow: View {
    let label: String
    let description: String
    let isCapturing: Bool
    let onRecord: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Brand.Palette.ink)
            Spacer(minLength: 8)
            if isCapturing {
                StatusLine(text: "Recording… press keys (Esc to cancel)", tone: .live)
            } else {
                Text(description)
                    .foregroundStyle(Brand.Palette.inkSecondary)
                Button("Record") { onRecord() }
            }
            // Hide Reset while this row is in "Recording…" mode so there is no
            // path that leaves the recorder's monitor active while the VM thinks
            // capture has ended (I2). The edge case of the OTHER row capturing is
            // handled inside SettingsViewModel.resetHotkey, which calls
            // recorder.cancelCapture first.
            if !isCapturing {
                Button("Reset to Default") { onReset() }
            }
        }
        .settingsRowPadding()
    }
}
