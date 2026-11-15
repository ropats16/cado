import AppKit

/// Mascot spots in `Config.mascotPositions`, written through on every save.
/// No pruning: one small entry per display ever dragged on.
final class ConfigMascotPositionStore: MascotPositionStore {
    private let configStore: ConfigStore

    init(_ configStore: ConfigStore) {
        self.configStore = configStore
    }

    func position(forDisplay id: String) -> MascotPosition? {
        configStore.config.mascotPositions[id]
    }

    func save(_ position: MascotPosition, forDisplay id: String) {
        guard configStore.config.mascotPositions[id] != position else { return }   // a click isn't a write
        configStore.update { $0.mascotPositions[id] = position }
    }
}

extension OverlayDisplay {
    /// `screen` as placement sees it. The id is the display's UUID, which,
    /// unlike its `CGDirectDisplayID`, survives reboots and reconnects; failing
    /// that, the display number, then the screen's name.
    init(_ screen: NSScreen) {
        self.init(id: Self.stableID(screen), frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// Every screen now, in `NSScreen.screens` order (main first).
    static func current() -> [OverlayDisplay] {
        NSScreen.screens.map(OverlayDisplay.init)
    }

    private static func stableID(_ screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else {
            return "name:\(screen.localizedName)"
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue(),
           let string = CFUUIDCreateString(nil, uuid) as String? {
            return string
        }
        return "display:\(displayID)"
    }
}
