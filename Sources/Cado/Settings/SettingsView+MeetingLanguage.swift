import SwiftUI

extension SettingsView {
    /// Meeting Language (#47): the language meetings are transcribed in,
    /// which model that takes, and its Download row when it's missing.
    var meetingLanguageSection: some View {
        SettingsSection(title: "Meeting Language", systemImage: "character.bubble.fill") {
            SettingsRow("Language") {
                Picker("Language",
                       selection: Binding(
                           get: { viewModel.meetingLanguageChoice },
                           set: { viewModel.setMeetingLanguage($0) }
                       )) {
                    ForEach(viewModel.meetingLanguageOptions, id: \.choice) { option in
                        Text(option.name).tag(option.choice)
                    }
                }
                .pickerWidth()
            }
            let note = viewModel.meetingLanguageNote
            StatusLine(text: note.text, tone: note.isProblem ? .problem : .note)
                .padding(.bottom, 8)
            if let model = viewModel.meetingModelDownload {
                ModelDownloadRow(model: model, viewModel: viewModel)
                    .padding(.bottom, 4)
            }
        }
    }
}
