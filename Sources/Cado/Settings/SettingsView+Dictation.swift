import SwiftUI

extension SettingsView {
    /// Dictation tab: hotkeys first (the thing people change most), then
    /// input, the mascot, and what dictating plays and keeps.
    var dictationTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Hotkeys", systemImage: "keyboard") {
                HotkeyRow(
                    label: ConfigValidator.hold,
                    description: viewModel.holdDescription,
                    isCapturing: recorder.captureTarget == .hold,
                    onChange: { recorder.startCapture(for: .hold, vm: viewModel) },
                    onReset:  { viewModel.resetHotkey(.hold) }
                )
                CardDivider()
                HotkeyRow(
                    label: ConfigValidator.toggle,
                    description: viewModel.toggleDescription,
                    isCapturing: recorder.captureTarget == .toggle,
                    onChange: { recorder.startCapture(for: .toggle, vm: viewModel) },
                    onReset:  { viewModel.resetHotkey(.toggle) }
                )
                if let warning = viewModel.hotkeyWarning {
                    StatusLine(text: warning, tone: .problem).padding(.bottom, 8)
                }
            }

            SettingsSection(title: "Input", systemImage: "mic.fill") {
                SettingsRow("Microphone") {
                    Picker("Microphone",
                           selection: Binding(get: { viewModel.selectedMicUID }, set: { viewModel.selectMic($0) })) {
                        Text("System Default").tag(String?.none)
                        ForEach(viewModel.micOptions, id: \.uid) { device in
                            Text(device.name).tag(Optional(device.uid))
                        }
                    }
                    .pickerWidth()
                }
                CardDivider()
                SettingsRow("Max dictation length") {
                    Picker("Max dictation length",
                           selection: Binding(get: { viewModel.maxDictationSeconds },
                                              set: { viewModel.setMaxDictationSeconds($0) })) {
                        ForEach(viewModel.maxDictationChoices, id: \.seconds) { choice in
                            Text(choice.label).tag(choice.seconds)
                        }
                    }
                    .pickerWidth()
                }
            }

            SettingsSection(title: "Sounds and History", systemImage: "speaker.wave.2.fill") {
                toggleRow("Play start/stop sounds", isOn: viewModel.soundCues) { viewModel.setSoundCues($0) }
                CardDivider()
                toggleRow("Keep recent dictations", isOn: viewModel.dictationHistory) { viewModel.setDictationHistory($0) }
                StatusLine(text: "Keeps your last \(RecentDictations.limit) dictations on this Mac, so you can copy one again from the menu. They aren't saved to the notes folder.")
                    .padding(.bottom, 8)
            }
        }
    }
    var mascotNotesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "Mascot", systemImage: "face.smiling") {
                toggleRow("Always show the mascot", isOn: viewModel.mascotAlwaysVisible) {
                    viewModel.setMascotAlwaysVisible($0)
                }
                StatusLine(text: "The mascot stays on screen. Click it to start or stop dictating; right-click it to record a meeting or hide it; drag it anywhere.")
                    .padding(.bottom, 8)
                CardDivider()
                toggleRow("Show the mascot in screen shares", isOn: viewModel.mascotInScreenShares) {
                    viewModel.setMascotInScreenShares($0)
                }
                StatusLine(text: "Off: the mascot is hidden from screen shares and recordings.")
                    .padding(.bottom, 8)
            }

            SettingsSection(title: "Notes", systemImage: "folder") {
                SettingsRow("Notes folder") {
                    Text(viewModel.notesFolderPath).lineLimit(1).truncationMode(.middle)
                        .font(Brand.Typography.caption).foregroundStyle(Brand.Palette.inkSecondary)
                    Button("Choose…") { viewModel.chooseNotesFolder() }
                }
                StatusLine(text: "Point at an Obsidian vault to see notes there.").padding(.bottom, 8)
            }
        }
    }

}

// MARK: - HotkeyRow

/// A single row in the Hotkeys section: the current binding, a Change
/// button to capture a new one live, and a Reset-to-default fallback. Not
/// "Record": that word is Record Meeting's.
struct HotkeyRow: View {
    let label: String
    let description: String
    let isCapturing: Bool
    let onChange: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(Brand.Palette.ink)
            Spacer(minLength: 8)
            if isCapturing {
                StatusLine(text: "Press the new keys (Esc to cancel)", tone: .live)
            } else {
                Text(description)
                    .foregroundStyle(Brand.Palette.inkSecondary)
                Button("Change…") { onChange() }
                    .accessibilityLabel("Change \(label) hotkey")
            }
            // Hide Reset while this row is capturing so there is no path that
            // leaves the recorder's monitor active while the VM thinks capture
            // has ended (I2). The OTHER row capturing is handled inside
            // SettingsViewModel.resetHotkey, which calls recorder.cancelCapture first.
            if !isCapturing {
                Button("Reset to Default") { onReset() }
            }
        }
        .settingsRowPadding()
    }
}
