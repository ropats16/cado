import SwiftUI

extension SettingsView {
    /// General tab: what the app is, startup, privacy, updates.
    var generalTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            SettingsCard {
                toggleRow("Launch Cado at login", isOn: viewModel.launchAtLogin) { viewModel.setLaunchAtLogin($0) }
                if let err = viewModel.loginError {
                    StatusLine(text: err, tone: .problem).padding(.bottom, 8)
                }
                CardDivider()
                toggleRow(UsagePingCopy.title, isOn: viewModel.usagePing) { viewModel.setUsagePing($0) }
                StatusLine(text: UsagePingCopy.settingsNote).padding(.bottom, 8)
            }
            updatesSection   // SettingsView+Updates.swift (#24)
        }
    }

    /// Parsed once: `Brand.Art.mascot` builds a new image from the SVG per call.
    private static let mascotArt = Brand.Art.mascot(.idle)

    /// The mascot, the name, and how to dictate with the configured hotkey.
    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: Self.mascotArt)
                .resizable()
                .frame(width: 60, height: 60)
                .frame(width: 72, height: 72)
                .background(Brand.Palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(Brand.Palette.outline(contrast)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Cado")
                    .font(Brand.Typography.font(.title, weight: .bold))
                    .foregroundStyle(Brand.Palette.ink)
                Text("Hold \(viewModel.holdDescription) and talk. Let go, and Cado types it for you.")
                    .font(Brand.Typography.font(.callout))
                    .foregroundStyle(Brand.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }
}
