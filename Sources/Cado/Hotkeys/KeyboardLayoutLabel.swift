import Carbon.HIToolbox
import Foundation

/// What the current keyboard layout prints on a key (#32): key codes are
/// physical positions, so the key in the M position is "," on AZERTY. Read
/// only; never changes input settings.
enum KeyboardLayoutLabel {
    /// The label for `keyCode` on the current layout, uppercased, or nil when
    /// it prints nothing usable (return, tab, arrows...) or no layout data is
    /// there (some input methods: the ASCII-capable layout is tried then).
    static func current(_ keyCode: Int) -> String? {
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let layout = source?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
            if let label = label(for: keyCode, layoutData: data) { return label }
        }
        return nil
    }

    /// Pure given layout data: no modifiers, dead keys ignored.
    static func label(for keyCode: Int, layoutData: CFData) -> String? {
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                    &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return nil }
        return printable(String(utf16CodeUnits: chars, count: length))
    }

    /// Uppercased, if one visible character.
    static func printable(_ text: String) -> String? {
        guard text.count == 1, let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return text.uppercased()
    }
}
