import SwiftUI
import AppKit

/// Cado's settings window content: the tab `SettingsNavigator` names, in the
/// brand's palette and type (SettingsStyles). Each tab is its own small
/// view in its own file (`SettingsView+<Tab>.swift`), so a feature adds its
/// rows in an extension file plus a one-line hook in its tab.
/// Bound to a `SettingsViewModel` via intent methods (no two-way Binding
/// with didSet) so the view stays simple and initial load never re-persists
/// config values.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    /// The recorder is owned by `SettingsViewModel` so `SettingsWindowController`
    /// can reach it via `viewModel.cancelCapture()` from `windowWillClose(_:)`.
    /// Passed explicitly so SwiftUI observes its `@Published` properties.
    @ObservedObject var recorder: HotkeyRecorder
    @ObservedObject var navigator: SettingsNavigator
    @Environment(\.colorSchemeContrast) var contrast

    /// The window's fixed width; wide enough for the longest model name.
    static let width: CGFloat = 720

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach([SettingsTab.general, .dictation, .meetings, .speechModel, .mascotNotes]) { tab in
                    Button { navigator.tab = tab } label: {
                        Text(tab.title)
                            .font(.system(size: 13, weight: navigator.tab == tab ? .bold : .medium))
                            .foregroundStyle(navigator.tab == tab ? Brand.Palette.accentText : Brand.Palette.inkSecondary)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if navigator.tab == tab { Rectangle().fill(Brand.Palette.accentText).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(navigator.tab == tab ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.top, 8)
            .background(Brand.Palette.windowBar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(navigator.tab.title).font(.system(size: 21.6, weight: .bold))
                            .foregroundStyle(Brand.Palette.ink).accessibilityAddTraits(.isHeader)
                        if navigator.tab == .meetings {
                            Text("Notes are saved as Markdown on this Mac.")
                                .font(.system(size: 12.5)).foregroundStyle(Brand.Palette.inkSecondary)
                        }
                    }
                    switch navigator.tab {
                    case .general: generalTab
                    case .dictation: dictationTab
                    case .speechModel: modelTab
                    case .meetings: meetingsTab
                    case .mascotNotes: mascotNotesTab
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 22).padding(.bottom, 26)
            }
        }
        .font(Brand.Typography.body)
        .toggleStyle(.switch)
        .buttonStyle(SettingsActionStyle())
        .tint(Brand.Palette.accent)
        .background(Brand.Palette.surface)
        .frame(minWidth: Self.width, maxWidth: Self.width, minHeight: 360)
        .onDisappear {
            // Window closed mid-capture: remove the monitor and resume the tap.
            recorder.cancelCapture(vm: viewModel)
        }
    }

    /// A card row with a switch.
    func toggleRow(_ label: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        SettingsRow(label) {
            Toggle(label, isOn: Binding(get: { isOn }, set: set))
        }
    }
}

extension View {
    /// A menu picker's width: its longest item, up to a cap, so names don't truncate.
    func pickerWidth() -> some View { frame(maxWidth: 340, alignment: .trailing) }
}
