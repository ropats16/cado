import SwiftUI

extension SettingsView {
    /// Meetings tab: where notes go and what is kept. Sibling features add
    /// their rows in `SettingsView+<Feature>.swift` and one hook line at
    /// their marked slot in `meetingsTab`.
    var meetingsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: "Notes", systemImage: "folder.fill") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Notes folder").foregroundStyle(Brand.Palette.ink)
                        Spacer(minLength: 8)
                        Button("Choose…") { viewModel.chooseNotesFolder() }
                        Button("Show in Finder") { viewModel.showNotesFolder() }
                    }
                    // Its own line, so the path has the card's full width.
                    Text(viewModel.notesFolderPath)
                        .font(Brand.Typography.caption)
                        .foregroundStyle(Brand.Palette.inkSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.notesFolderPath)
                        .textSelection(.enabled)
                }
                .settingsRowPadding()
                StatusLine(text: "Meeting notes (Record Meeting in the menu) are saved here as plain Markdown, so you can point this at an Obsidian vault.")
                    .padding(.bottom, 8)
                CardDivider()
                toggleRow("Keep meeting audio", isOn: viewModel.keepMeetingAudio) { viewModel.setKeepMeetingAudio($0) }
                StatusLine(text: "Off: a meeting's audio is deleted once its note is saved. On: it's kept on this Mac in Cado's Meeting Audio folder, about 115 MB per hour for each side.")
                    .padding(.bottom, 8)
            }

            // MARK: Sibling hooks
            // Each meeting feature adds ONE line in its own slot below (keep
            // the comment lines between slots, so merges stay clean) and puts
            // its card in SettingsView+<Feature>.swift. Planned slots:

            // Slot: meeting language
            meetingLanguageSection   // SettingsView+MeetingLanguage.swift (#47)

            // Slot: meeting detection on/off
            meetingDetectionSection   // SettingsView+MeetingDetection.swift (#32)

            // Slot: meeting hotkey
            meetingHotkeySection   // SettingsView+MeetingDetection.swift (#32)

            // Slot: max meeting length
            maxMeetingLengthSection   // SettingsView+MeetingDetection.swift (#32)

            // Slot: summaries on/off
            summariesSection   // SettingsView+Summaries.swift (#34)

            // Slot: calendar meeting titles
            calendarSection   // SettingsView+Calendar.swift (#38)
        }
    }
}
