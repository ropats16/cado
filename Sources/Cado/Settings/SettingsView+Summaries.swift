import AppKit
import SwiftUI

extension SettingsView {
    /// The switch shows the saved preference; the status explains whether
    /// the selected provider is ready to generate summaries.
    var summariesSection: some View {
        SettingsSection(title: "Summaries", systemImage: "sparkles") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Write a summary after each meeting")
                        .fontWeight(.semibold).foregroundStyle(Brand.Palette.ink)
                    Text(viewModel.summariesNote)
                        .font(.system(size: 12)).foregroundStyle(Brand.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(SummarySettingsCopy.title,
                       isOn: Binding(
                           get: { viewModel.meetingSummaries },
                           set: { viewModel.setMeetingSummaries($0) }
                       ))
                    .labelsHidden()
                    .disabled(!viewModel.canChangeMeetingSummaries)
            }
            .settingsRowPadding()
            summaryProviderRows   // SettingsView+OpenRouter.swift (#35)
        }
        .onAppear { viewModel.refreshSummaryAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            viewModel.refreshSummaryAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            viewModel.refreshSummaryAvailability()
        }
        // A typed key isn't kept once Settings goes away.
        .onDisappear { viewModel.clearOpenRouterKeyDraft() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            viewModel.clearOpenRouterKeyDraft()
        }
    }
}
