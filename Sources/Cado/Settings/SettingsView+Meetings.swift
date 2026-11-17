import SwiftUI

extension SettingsView {
    /// Meetings (#32): asking to record, and the max meeting length.
    var meetingsSection: some View {
        SettingsSection(title: "Meetings", systemImage: "person.2.wave.2") {
            SettingsRow("Ask to record meetings") {
                Toggle("Ask to record meetings",
                       isOn: Binding(
                           get: { viewModel.meetingDetection },
                           set: { viewModel.setMeetingDetection($0) }
                       ))
                    .disabled(!viewModel.canDetectMeetings)
            }
            StatusLine(text: viewModel.canDetectMeetings ? SettingsViewModel.meetingsNote
                       : SettingsViewModel.meetingsUnsupportedNote)
                .padding(.bottom, 8)
            CardDivider()
            SettingsRow("Max meeting length") {
                Picker("Max meeting length",
                       selection: Binding(
                           get: { viewModel.maxMeetingMinutes },
                           set: { viewModel.setMaxMeetingMinutes($0) }
                       )) {
                    ForEach(viewModel.maxMeetingChoices, id: \.minutes) { choice in
                        Text(choice.label).tag(choice.minutes)
                    }
                }
                .frame(maxWidth: 240, alignment: .trailing)
            }
            StatusLine(text: SettingsViewModel.maxMeetingNote)
                .padding(.bottom, 8)
        }
    }

    /// The meeting hotkey's row in Hotkeys (#32).
    var meetingHotkeyRow: some View {
        HotkeyRow(
            label: ConfigValidator.meeting,
            description: viewModel.meetingHotkeyDescription,
            isCapturing: recorder.captureTarget == .meeting,
            onRecord: { recorder.startCapture(for: .meeting, vm: viewModel) },
            onReset: { viewModel.resetHotkey(.meeting) }
        )
    }
}
