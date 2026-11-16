import XCTest
@testable import Cado

/// `SpeechChunker`: where a long recording's speech is. Synthetic 16 kHz
/// audio: tone bursts for speech over silence or noise.
final class SpeechChunkerTests: XCTestCase {
    private let rate = 16_000.0

    /// `seconds` of audio: `bursts` (start, end, amplitude) of a 200 Hz tone
    /// over `noise` (uniform, ±noise).
    private func audio(seconds: Double, _ bursts: [(Double, Double, Float)], noise: Float = 0) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * rate)).map { i in
            let t = Double(i) / rate
            var s = noise > 0 ? Float.random(in: -noise...noise, using: &generator) : 0
            for (start, end, amplitude) in bursts where t >= start && t < end {
                s += amplitude * Float(sin(2 * .pi * 200 * t))
            }
            return s
        }
    }

    private func seconds(_ chunks: [SpeechChunker.Chunk]) -> [ClosedRange<Double>] {
        chunks.map { (Double($0.start) / rate)...(Double($0.end) / rate) }
    }

    func testSilenceHasNoChunks() {
        XCTAssertEqual(SpeechChunker.chunks([]), [])
        XCTAssertEqual(SpeechChunker.chunks(audio(seconds: 5, [])), [])
    }

    func testEachUtteranceIsAPaddedChunk() {
        let chunks = seconds(SpeechChunker.chunks(audio(seconds: 10, [(1, 2.5, 0.2), (5, 6, 0.2)])))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].lowerBound, 0.8, accuracy: 0.03)
        XCTAssertEqual(chunks[0].upperBound, 2.8, accuracy: 0.03)
        XCTAssertEqual(chunks[1].lowerBound, 4.8, accuracy: 0.03)
        XCTAssertEqual(chunks[1].upperBound, 6.3, accuracy: 0.03)
    }

    func testAShortPauseStaysInOneChunk() {
        let chunks = SpeechChunker.chunks(audio(seconds: 6, [(1, 2, 0.2), (2.4, 3.5, 0.2)]))
        XCTAssertEqual(chunks.count, 1, "0.4 s is a breath, not a pause")
    }

    func testAClickIsDropped() {
        XCTAssertEqual(SpeechChunker.chunks(audio(seconds: 4, [(1, 1.1, 0.5)])), [])
    }

    func testSpeechOverRoomNoiseIsFoundAndTheNoiseIsNot() {
        let chunks = seconds(SpeechChunker.chunks(audio(seconds: 8, [(3, 4, 0.1)], noise: 0.02)))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].lowerBound, 2.8, accuracy: 0.05)
    }

    func testAMonologueIsCutIntoChunksNoLongerThanTheMaximum() {
        // 60 s of talk with a slightly quieter dip every 10 s.
        var bursts: [(Double, Double, Float)] = []
        for i in 0..<6 {
            let t = Double(i) * 10
            bursts.append((t, t + 9.9, 0.2))
            bursts.append((t + 9.9, t + 10, 0.05))
        }
        let samples = audio(seconds: 61, bursts)
        let chunks = SpeechChunker.chunks(samples)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Double(chunk.end - chunk.start) / rate, 25 + 0.3 + 0.01)
        }
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertGreaterThanOrEqual(chunks.last!.end, Int(59.9 * rate))
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "Cut chunks are contiguous: no audio lost, none twice")
        }
    }
}
