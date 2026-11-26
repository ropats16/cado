import XCTest
@testable import Cado

/// Tests for the hardware-based multilingual support tier (#61). Pure.
final class MultilingualTierTests: XCTestCase {

    private func appleSilicon(_ gib: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: true, memoryBytes: gib << 30)
    }

    private func intel(_ gib: UInt64) -> HardwareProfile {
        HardwareProfile(isAppleSilicon: false, memoryBytes: gib << 30)
    }

    func testAppleSiliconTierBoundaries() {
        XCTAssertEqual(MultilingualTier.tier(for: appleSilicon(7)), .limited)
        XCTAssertEqual(MultilingualTier.tier(for: appleSilicon(8)), .basic)
        XCTAssertEqual(MultilingualTier.tier(for: appleSilicon(15)), .basic)
        XCTAssertEqual(MultilingualTier.tier(for: appleSilicon(16)), .full)
        XCTAssertEqual(MultilingualTier.tier(for: appleSilicon(32)), .full)
    }

    func testIntelTierBoundaries() {
        XCTAssertEqual(MultilingualTier.tier(for: intel(8)), .limited)
        XCTAssertEqual(MultilingualTier.tier(for: intel(15)), .limited)
        XCTAssertEqual(MultilingualTier.tier(for: intel(16)), .basic)
    }
}
