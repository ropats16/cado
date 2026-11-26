import Foundation

/// How well this Mac can transcribe languages other than English (#61). Pure.
///
/// Maps chip and whole-GiB RAM to the Whisper multilingual tier:
/// - `.full`: Apple Silicon with 16 GiB or more.
/// - `.basic`: Apple Silicon with 8–15 GiB, or Intel with 16 GiB or more.
/// - `.limited`: everything smaller.
enum MultilingualTier: Equatable, CaseIterable {
    case full, basic, limited

    static func tier(for hardware: HardwareProfile) -> MultilingualTier {
        if hardware.isAppleSilicon {
            switch hardware.memoryGiB {
            case 16...: return .full
            case 8...: return .basic
            default: return .limited
            }
        }
        return hardware.memoryGiB >= 16 ? .basic : .limited
    }
}
