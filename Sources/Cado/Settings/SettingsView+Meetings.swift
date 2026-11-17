import SwiftUI

extension SettingsView {
    var meetingsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            meetingDetectionSection
            summariesSection
            SettingsSection(title: "Notes", systemImage: "folder.fill") {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notes folder").fontWeight(.semibold)
                        Text("Point at an Obsidian vault to see notes there.")
                            .font(.system(size: 12)).foregroundStyle(Brand.Palette.inkSecondary)
                    }
                    Spacer(minLength: 0)
                    Text(viewModel.notesFolderPath).lineLimit(1).truncationMode(.middle)
                        .font(.system(size: 12)).foregroundStyle(Brand.Palette.inkSecondary)
                        .help(viewModel.notesFolderPath).textSelection(.enabled)
                    Button("Choose…") { viewModel.chooseNotesFolder() }
                }.padding(.vertical, 12)
            }
            DisclosureGroup("More meeting settings") {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsSection(title: "Audio and files", systemImage: "folder") {
                        SettingsRow("Saved notes") {
                            Button("Show in Finder") { viewModel.showNotesFolder() }
                        }
                        CardDivider()
                        toggleRow("Keep meeting audio", isOn: viewModel.keepMeetingAudio) { viewModel.setKeepMeetingAudio($0) }
                        StatusLine(text: "Off: a meeting's audio is deleted once its note is saved. On: it's kept on this Mac in Cado's Meeting Audio folder, about 115 MB per hour for each side.")
                            .padding(.bottom, 8)
                    }
                    meetingLanguageSection
                    meetingHotkeySection
                    maxMeetingLengthSection
                    calendarSection
                }.padding(.top, 12)
            }
            .foregroundStyle(Brand.Palette.inkSecondary)
        }
    }
}
