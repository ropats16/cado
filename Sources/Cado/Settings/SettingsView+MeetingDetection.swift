import SwiftUI

/// Meetings tab cards for #32, one per slot in `meetingsTab`: asking to
/// record, the meeting hotkey, and the max meeting length.
extension SettingsView {
    /// Asking "Record this meeting?" when a meeting app starts using the mic.
    var meetingDetectionSection: some View {
        SettingsSection(title: "Ask to Record", systemImage: "bell.badge") {
            toggleRow("Ask to record meetings", isOn: viewModel.meetingDetection) { viewModel.setMeetingDetection($0) }
                .disabled(!viewModel.canDetectMeetings)
            StatusLine(text: viewModel.canDetectMeetings ? SettingsViewModel.meetingsNote
                       : SettingsViewModel.meetingsUnsupportedNote)
                .padding(.bottom, 8)
        }
    }

    /// The meeting hotkey, with the same row as the dictation hotkeys.
    var meetingHotkeySection: some View {
        SettingsSection(title: "Hotkey", systemImage: "keyboard") {
            HotkeyRow(
                label: ConfigValidator.meeting,
                description: viewModel.meetingHotkeyDescription,
                isCapturing: recorder.captureTarget == .meeting,
                onChange: { recorder.startCapture(for: .meeting, vm: viewModel) },
                onReset: { viewModel.resetHotkey(.meeting) }
            )
            if let warning = viewModel.meetingHotkeyWarning {
                StatusLine(text: warning, tone: .problem).padding(.bottom, 8)
            }
        }
    }

    /// A meeting stops by itself after this long.
    var maxMeetingLengthSection: some View {
        SettingsSection(title: "Length", systemImage: "timer") {
            SettingsRow("Max meeting length") {
                Picker("Max meeting length",
                       selection: Binding(get: { viewModel.maxMeetingMinutes },
                                          set: { viewModel.setMaxMeetingMinutes($0) })) {
                    ForEach(viewModel.maxMeetingChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .pickerWidth()
            }
            StatusLine(text: SettingsViewModel.maxMeetingNote)
                .padding(.bottom, 8)
        }
    }
}
