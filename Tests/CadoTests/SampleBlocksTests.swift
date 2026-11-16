import XCTest
@testable import Cado

/// A recording's storage: an hour-long meeting must grow without ever
/// copying what it already holds (an array doubles and copies — ~800 MB in
/// flight per stream at 70 minutes).
final class SampleBlocksTests: XCTestCase {
    private func ramp(_ count: Int, from start: Int = 0) -> [Float] {
        (start..<(start + count)).map { Float($0) }
    }

    func testGrowingNeverMovesWhatIsAlreadyStored() {
        var blocks = SampleBlocks(blockSize: 1_000)
        ramp(10).withUnsafeBufferPointer { blocks.append($0) }
        let first = blocks.storageAddress(ofBlock: 0)

        for i in 0..<50 { ramp(97, from: 10 + i * 97).withUnsafeBufferPointer { blocks.append($0) } }

        XCTAssertEqual(blocks.storageAddress(ofBlock: 0), first, "The first block was never copied")
        XCTAssertEqual(blocks.count, 4_860)
        XCTAssertEqual(blocks.blockCount, 5, "Fixed 1 000-sample blocks, filled in order")
    }

    func testTakeReturnsEverySampleInOrderAndEmpties() {
        var blocks = SampleBlocks(blockSize: 64)
        ramp(100).withUnsafeBufferPointer { blocks.append($0) }
        blocks.appendSilence(30)
        ramp(5, from: 100).withUnsafeBufferPointer { blocks.append($0) }

        let samples = blocks.take()

        XCTAssertEqual(samples, ramp(100) + [Float](repeating: 0, count: 30) + ramp(5, from: 100))
        XCTAssertEqual(blocks.count, 0)
        XCTAssertEqual(blocks.blockCount, 0)
    }

    func testAnEmptyRecordingTakesAsEmpty() {
        var blocks = SampleBlocks()
        XCTAssertEqual(blocks.take(), [])
    }
}
