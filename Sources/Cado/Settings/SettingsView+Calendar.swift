import SwiftUI

extension SettingsView {
    /// Calendar meeting titles (#38): the opt-in switch and, if macOS said no,
    /// how to allow it (the user does that in System Settings themselves).
    var calendarSection: some View {
        SettingsSection(title: "Calendar", systemImage: "calendar") {
            SettingsRow(CalendarSettingsCopy.title) {
                Toggle(CalendarSettingsCopy.title,
                       isOn: Binding(
                           get: { viewModel.nameMeetingsFromCalendar },
                           set: { viewModel.setNameMeetingsFromCalendar($0) }
                       ))
            }
            StatusLine(text: viewModel.calendarNote,
                       tone: viewModel.calendarNeedsSystemSettings ? .problem : .note)
                .padding(.bottom, viewModel.calendarNeedsSystemSettings ? 0 : 8)
            if viewModel.calendarNeedsSystemSettings {
                HStack {
                    Button("Open System Settings") { viewModel.openCalendarSettings() }
                    Spacer(minLength: 0)
                }
                .settingsRowPadding()
                .padding(.bottom, 8)
            }
        }
        .onAppear { viewModel.refreshCalendarAccess() }
    }
}
