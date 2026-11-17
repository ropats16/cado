import SwiftUI

extension SettingsView {
    /// Meeting Summaries (#34): the switch, with what it does or why it
    /// can't run on this Mac (then the switch shows off and is greyed out;
    /// the stored choice is kept for when it can run).
    var summariesSection: some View {
        SettingsSection(title: "Meeting Summaries", systemImage: "sparkles") {
            SettingsRow(SummarySettingsCopy.title) {
                Toggle(SummarySettingsCopy.title,
                       isOn: Binding(
                           get: { viewModel.meetingSummaries && viewModel.summariesAvailable },
                           set: { viewModel.setMeetingSummaries($0) }
                       ))
                    .disabled(!viewModel.summariesAvailable)
            }
            StatusLine(text: viewModel.summariesNote)
                .padding(.bottom, 8)
        }
    }
}
