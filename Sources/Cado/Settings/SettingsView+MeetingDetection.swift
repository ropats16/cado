import SwiftUI

/// Meetings tab cards for #32, one per slot in `meetingsTab`: asking to
/// record, the meeting hotkey, and the max meeting length.
extension SettingsView {
    /// Asking "Record this meeting?" when a meeting app starts using the mic.
    var meetingDetectionSection: some View {
        SettingsSection(title: "Detection", systemImage: "bell.badge") {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Offer to record when a meeting starts").fontWeight(.semibold).accessibilityHidden(true)
                    Text(viewModel.canDetectMeetings ? "Cado asks first. It never records on its own." : SettingsViewModel.meetingsUnsupportedNote)
                        .font(.system(size: 12)).foregroundStyle(Brand.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Toggle("Offer to record when a meeting starts", isOn: Binding(
                    get: { viewModel.meetingDetection }, set: { viewModel.setMeetingDetection($0) }))
                    .labelsHidden().disabled(!viewModel.canDetectMeetings)
            }.padding(.vertical, 12)
            CardDivider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Meeting apps").fontWeight(.semibold)
                Text("Zoom, Teams, Slack, Webex, Discord, FaceTime, and browser calls such as Google Meet.")
                    .font(.system(size: 12)).foregroundStyle(Brand.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 12)
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
