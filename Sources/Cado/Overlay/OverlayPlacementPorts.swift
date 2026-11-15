import Foundation

// The seam between mascot placement and persistence. `OverlayPlacement` owns
// every geometry rule; the store only keeps one spot per display. Live:
// `ConfigMascotPositionStore` (config.json); tests: an in-memory fake.
//
// Called on main.

/// Saved mascot spots, one per display id (`OverlayDisplay.id`).
protocol MascotPositionStore: AnyObject {
    func position(forDisplay id: String) -> MascotPosition?
    /// Replaces that display's spot; others are untouched.
    func save(_ position: MascotPosition, forDisplay id: String)
}
