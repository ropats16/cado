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
            let card = viewModel.meetingLanguageCard   // one model choice per render
            if let problem = card.languageProblem {
                StatusLine(text: problem, tone: .problem)
                    .padding(.bottom, 4)
            }
            StatusLine(text: card.note.text, tone: card.note.isProblem ? .problem : .note)
                .padding(.bottom, 8)
            if let model = card.download {
                ModelDownloadRow(model: model, viewModel: viewModel)
                    .padding(.bottom, 4)
            }
        }
    }
}
