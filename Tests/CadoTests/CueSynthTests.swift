import AppKit
import XCTest
@testable import Cado

/// Properties of the synthesized start/stop cues, checked by analysis since
/// tests can't listen.
final class CueSynthTests: XCTestCase {

    private let rate = Double(CueSound.sampleRate)

    private func samples(_ cue: SoundCue) -> [Float] { CueSound.for(cue).render() }

    func testCuesAreShort() {
        for cue in [SoundCue.start, .stop] {
            let seconds = Double(samples(cue).count) / rate
            XCTAssertGreaterThanOrEqual(seconds, 0.12, "\(cue)")
            XCTAssertLessThanOrEqual(seconds, 0.22, "\(cue)")
        }
    }

    func testCuesAreAudibleButWellBelowFullScale() {
        for cue in [SoundCue.start, .stop] {
            let peak = samples(cue).map(abs).max() ?? 0
            XCTAssertGreaterThan(peak, 0.1, "\(cue)")
            XCTAssertLessThanOrEqual(peak, 0.3, "\(cue)")
        }
    }

    func testStopIsATouchSofterThanStart() {
        XCTAssertLessThan(samples(.stop).map(abs).max()!, samples(.start).map(abs).max()!)
    }

    /// No click: silence at both ends, ramped in over a few ms and faded out.
    func testCuesStartAndEndAtSilence() {
        for cue in [SoundCue.start, .stop] {
            let s = samples(cue)
            let peak = s.map(abs).max()!
            XCTAssertEqual(s.first, 0, "\(cue)")
            XCTAssertEqual(Double(s.last!), 0, accuracy: 1e-4, "\(cue)")
            XCTAssertLessThan(s.prefix(Int(0.001 * rate)).map(abs).max()!, 0.15 * peak, "\(cue) attack clicks")
            XCTAssertLessThan(s.suffix(Int(0.002 * rate)).map(abs).max()!, 0.01 * peak, "\(cue) tail clicks")
        }
    }

    /// Soft, not sluggish: the first note is at full voice within 10 ms.
    func testAttackIsPrompt() {
        for cue in [SoundCue.start, .stop] {
            let s = samples(cue)
            XCTAssertGreaterThan(s.prefix(Int(0.010 * rate)).map(abs).max()!, 0.5 * s.map(abs).max()!, "\(cue)")
        }
    }

    func testCuesHaveNoDCOffset() {
        for cue in [SoundCue.start, .stop] {
            let s = samples(cue)
            let mean = s.reduce(0, +) / Float(s.count)
            XCTAssertLessThan(abs(mean), 0.002, "\(cue)")
        }
    }

    // MARK: - Pitch

    func testStartRisesAndStopFalls() {
        let start = samples(.start), stop = samples(.stop)
        XCTAssertLessThan(dominantFrequency(firstHalf(start)), dominantFrequency(secondHalf(start)))
        XCTAssertGreaterThan(dominantFrequency(firstHalf(stop)), dominantFrequency(secondHalf(stop)))
    }

    func testFundamentalsAreMidHighNotShrill() {
        for cue in [SoundCue.start, .stop] {
            let s = samples(cue)
            for half in [firstHalf(s), secondHalf(s)] {
                let f = dominantFrequency(half)
                XCTAssertGreaterThanOrEqual(f, 500, "\(cue)")
                XCTAssertLessThanOrEqual(f, 1000, "\(cue)")
            }
        }
    }

    // MARK: - WAV container

    func testWAVHeaderDescribesMono16BitPCM() {
        let pcm: [Float] = [0, 0.5, -0.5, 1, -1, 2]
        let wav = WAV.encode(pcm, sampleRate: 44_100)
        XCTAssertEqual(wav.count, 44 + 2 * pcm.count)
        XCTAssertEqual(ascii(wav, 0), "RIFF")
        XCTAssertEqual(u32(wav, 4), UInt32(wav.count - 8))
        XCTAssertEqual(ascii(wav, 8), "WAVE")
        XCTAssertEqual(ascii(wav, 12), "fmt ")
        XCTAssertEqual(u32(wav, 16), 16)
        XCTAssertEqual(u16(wav, 20), 1, "PCM")
        XCTAssertEqual(u16(wav, 22), 1, "mono")
        XCTAssertEqual(u32(wav, 24), 44_100)
        XCTAssertEqual(u32(wav, 28), 88_200, "byte rate")
        XCTAssertEqual(u16(wav, 32), 2, "block align")
        XCTAssertEqual(u16(wav, 34), 16, "bits")
        XCTAssertEqual(ascii(wav, 36), "data")
        XCTAssertEqual(u32(wav, 40), UInt32(2 * pcm.count))
        let ints = (0..<pcm.count).map { Int16(bitPattern: u16(wav, 44 + 2 * $0)) }
        XCTAssertEqual(ints, [0, 16_384, -16_384, 32_767, -32_767, 32_767], "scaled and clamped")
    }

    func testCuesLoadAsSounds() {
        for cue in [SoundCue.start, .stop] {
            let wav = WAV.encode(samples(cue), sampleRate: CueSound.sampleRate)
            XCTAssertNotNil(NSSound(data: wav), "\(cue)")
        }
    }

    // MARK: - Helpers

    private func ascii(_ d: Data, _ at: Int) -> String { String(decoding: d[at..<at + 4], as: UTF8.self) }
    private func u16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) | UInt16(d[at + 1]) << 8 }
    private func u32(_ d: Data, _ at: Int) -> UInt32 { UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16 }

    private func firstHalf(_ s: [Float]) -> ArraySlice<Float> { s[..<(s.count / 2)] }
    private func secondHalf(_ s: [Float]) -> ArraySlice<Float> { s[(s.count / 2)...] }

    /// The strongest frequency between 200 Hz and 4 kHz, to 5 Hz (Goertzel scan).
    private func dominantFrequency(_ s: ArraySlice<Float>) -> Double {
        stride(from: 200.0, through: 4000, by: 5).max { power(s, $0) < power(s, $1) }!
    }

    private func power(_ s: ArraySlice<Float>, _ frequency: Double) -> Double {
        let coeff = 2 * cos(2 * .pi * frequency / rate)
        var prev = 0.0, prev2 = 0.0
        for x in s {
            let next = Double(x) + coeff * prev - prev2
            prev2 = prev
            prev = next
        }
        return prev * prev + prev2 * prev2 - coeff * prev * prev2
    }
}
