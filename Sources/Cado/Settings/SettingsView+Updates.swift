import SwiftUI

extension SettingsView {
    /// Updates (#24): Sparkle's automatic-check switch and a manual check.
    var updatesSection: some View {
        SettingsSection(title: "Updates", systemImage: "arrow.triangle.2.circlepath") {
            SettingsRow("Automatically check for updates") {
                Toggle("Automatically check for updates",
                       isOn: Binding(
                           get: { viewModel.automaticallyChecksForUpdates },
                           set: { viewModel.setAutomaticallyChecksForUpdates($0) }
                       ))
                    .disabled(!viewModel.updatesAvailable)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusLine(text: viewModel.updatesNote)
                Spacer(minLength: 8)
                if viewModel.updatesAvailable {
                    Button("Check Now") { viewModel.checkForUpdates() }
                        .disabled(!viewModel.canCheckForUpdates)
                }
            }
            .padding(.bottom, 8)
        }
    }
}
