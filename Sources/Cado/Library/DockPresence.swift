import AppKit

/// Decides the app's activation policy: a Dock icon (`.regular`) only while
/// a window that wants one (the Library) is open, else the menu-bar-only
/// `.accessory`. Windows that don't want the icon (Settings, onboarding)
/// never register, so they neither show it nor hide it. Main thread only.
@MainActor
final class DockPresence {
    private var owners: Set<String> = []
    private var current: NSApplication.ActivationPolicy
    private let apply: (NSApplication.ActivationPolicy) -> Void

    init(initial: NSApplication.ActivationPolicy = .accessory,
         apply: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        current = initial
        self.apply = apply
    }

    /// `owner`'s window opened. Idempotent.
    func opened(_ owner: String) {
        owners.insert(owner)
        update()
    }

    /// `owner`'s window closed. Idempotent.
    func closed(_ owner: String) {
        owners.remove(owner)
        update()
    }

    private func update() {
        let wanted: NSApplication.ActivationPolicy = owners.isEmpty ? .accessory : .regular
        guard wanted != current else { return }
        current = wanted
        apply(wanted)
    }
}
