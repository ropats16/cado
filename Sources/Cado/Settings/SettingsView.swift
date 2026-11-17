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
    static let width: CGFloat = 560

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch navigator.tab {
                case .general: generalTab
                case .dictation: dictationTab
                case .speechModel: modelTab
                case .meetings: meetingsTab
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .font(Brand.Typography.body)
        .toggleStyle(.switch)
        .tint(Brand.Palette.accent)
        .background(Brand.Palette.background)
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
