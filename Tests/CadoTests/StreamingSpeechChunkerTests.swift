import XCTest
@testable import Cado

/// `StreamingSpeechChunker`: the incremental twin of `SpeechChunker`. Same
/// synthetic 16 kHz audio style: tone bursts over silence or noise.
final class StreamingSpeechChunkerTests: XCTestCase {
    private let rate = 16_000.0
    private typealias Burst = (Double, Double, Float)

    /// Deterministic uniform noise in -1...1.
    private struct Noise {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
    }

    /// `[from, to)` seconds of audio: `bursts` of a 200 Hz tone over uniform
    /// noise whose amplitude is `noise(t)`.
    private func audio(from: Double = 0, to: Double, _ bursts: [Burst], noise: (Double) -> Float = { _ in 0 },
                       generator: inout Noise) -> [Float] {
        (Int(from * rate)..<Int(to * rate)).map { i in
            let t = Double(i) / rate
            var s = noise(t) * generator.next()
            for (start, end, amplitude) in bursts where t >= start && t < end {
                s += amplitude * Float(sin(2 * .pi * 200 * t))
            }
            return s
        }
    }

    private func audio(seconds: Double, _ bursts: [Burst], noise: Float = 0) -> [Float] {
        var g = Noise()
        return audio(to: seconds, bursts, noise: { _ in noise }, generator: &g)
    }

    private func run(_ samples: [Float], batch: Int? = nil,
                     settings: SpeechChunker.Settings = .init()) -> [SpeechChunker.Chunk] {
        var chunker = StreamingSpeechChunker(settings: settings)
        var out: [SpeechChunker.Chunk] = []
        var i = 0
        let size = batch ?? max(1, samples.count)
        while i < samples.count {
            out += chunker.append(Array(samples[i..<min(i + size, samples.count)]))
            i += size
        }
        return out + chunker.finish()
    }

    private func seconds(_ chunks: [SpeechChunker.Chunk]) -> [ClosedRange<Double>] {
        chunks.map { (Double($0.start) / rate)...(Double($0.end) / rate) }
    }

    func testSilenceHasNoChunks() {
        XCTAssertEqual(run([]), [])
        XCTAssertEqual(run(audio(seconds: 5, [])), [])
        var chunker = StreamingSpeechChunker()
        XCTAssertEqual(chunker.append([]), [])
        XCTAssertEqual(chunker.consumed, 0)
    }

    func testOneBurstIsOnePaddedChunk() {
        let chunks = seconds(run(audio(seconds: 6, [(1, 2.5, 0.2)])))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].lowerBound, 0.8, accuracy: 0.03)
        XCTAssertEqual(chunks[0].upperBound, 2.8, accuracy: 0.03)
    }

    func testAChunkIsEmittedDuringAppendOnceAPauseFollowsIt() {
        let samples = audio(seconds: 10, [(1, 2.5, 0.2), (5, 6, 0.2)])
        var chunker = StreamingSpeechChunker()
        let upToSecondBurst = Int(4.9 * rate)
        let first = chunker.append(Array(samples[..<upToSecondBurst]))
        XCTAssertEqual(first.count, 1, "First utterance is out before the second one starts")
        XCTAssertLessThanOrEqual(first[0].end, chunker.consumed)
        let rest = chunker.append(Array(samples[upToSecondBurst...])) + chunker.finish()
        XCTAssertEqual(rest.count, 1)
        XCTAssertEqual(Double(rest[0].start) / rate, 4.8, accuracy: 0.03)
        XCTAssertEqual(Double(rest[0].end) / rate, 6.3, accuracy: 0.03)
    }

    func testAShortPauseIsBridged() {
        XCTAssertEqual(run(audio(seconds: 6, [(1, 2, 0.2), (2.4, 3.5, 0.2)])).count, 1)
    }

    func testAClickIsDropped() {
        XCTAssertEqual(run(audio(seconds: 4, [(1, 1.1, 0.5)])), [])
    }

    func testAMonologueIsCutAtTheMaximumWithoutWaitingForAPause() {
        var bursts: [Burst] = []
        for i in 0..<6 {
            let t = Double(i) * 10
            bursts.append((t, t + 9.9, 0.2))
            bursts.append((t + 9.9, t + 10, 0.05))
        }
        let samples = audio(seconds: 61, bursts)
        // Feed 40 s of unbroken talk: the first piece must already be out.
        var chunker = StreamingSpeechChunker()
        let early = chunker.append(Array(samples[..<Int(40 * rate)]))
        XCTAssertFalse(early.isEmpty, "A cut chunk is emitted without a pause")
        let chunks = run(samples)
        XCTAssertGreaterThan(chunks.count, 2)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(Double(chunk.end - chunk.start) / rate, 25 + 0.3 + 0.01)
        }
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertGreaterThanOrEqual(chunks.last!.end, Int(59.9 * rate))
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "Cut chunks are contiguous: no audio lost, none twice")
        }
        // The cut lands on one of the quiet dips, not mid-word.
        let cut = Double(chunks[0].end) / rate - 0.3
        XCTAssertEqual((cut + 0.1).truncatingRemainder(dividingBy: 10), 0, accuracy: 0.15)
    }

    func testChunksDoNotDependOnBatchSize() {
        let samples = audio(seconds: 50, [(1, 3, 0.2), (3.2, 6, 0.2), (12, 12.1, 0.4), (15, 45, 0.15)], noise: 0.01)
        let whole = run(samples)
        XCTAssertGreaterThanOrEqual(whole.count, 3)
        for batch in [1, 160, 317, 16_000] {
            XCTAssertEqual(run(samples, batch: batch), whole, "batch \(batch)")
        }
    }

    func testChunksAreOrderedBoundedAndSettledThroughIsSafe() {
        let samples = audio(seconds: 90,
                            [(2, 4, 0.2), (8, 9, 0.2), (30, 70, 0.2), (80, 81, 0.2)], noise: 0.004)
        var chunker = StreamingSpeechChunker()
        var all: [SpeechChunker.Chunk] = []
        var settledHistory: [(settled: Int, emittedAfter: Int)] = []
        var previousSettled = 0
        var settledDuringSilence = 0
        var i = 0
        while i < samples.count {
            let batch = Array(samples[i..<min(i + 4_000, samples.count)])
            i += batch.count
            let out = chunker.append(batch)
            for chunk in out {
                XCTAssertLessThanOrEqual(chunk.end, chunker.consumed)
                XCTAssertLessThan(chunk.start, chunk.end)
            }
            all += out
            XCTAssertGreaterThanOrEqual(chunker.settledThrough, previousSettled, "monotonic")
            XCTAssertLessThanOrEqual(chunker.settledThrough, chunker.consumed)
            previousSettled = chunker.settledThrough
            settledHistory.append((chunker.settledThrough, all.count))
            if i == Int(20 * rate) { settledDuringSilence = chunker.settledThrough }
        }
        all += chunker.finish()
        XCTAssertEqual(all.count, 5, "the 40 s monologue is cut in two")
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
        for (settled, emitted) in settledHistory {
            for later in all.dropFirst(emitted) {
                XCTAssertLessThanOrEqual(settled, later.start, "No chunk starts before settledThrough")
            }
        }
        XCTAssertGreaterThan(settledDuringSilence, Int(19 * rate), "Silence settles, so the caller can drop audio")
    }

    func testAgreesWithTheBatchChunkerOnNoisySpeech() {
        // Steady noise (rms ~ 0.006) with clear bursts. The first burst is 4 s in
        // so the rolling floor has seen noise. Differences can only come from the
        // rolling noise estimate vs the whole-recording percentile; with bursts
        // 10x the noise both put the threshold in the same gap, so boundaries
        // match to within one 20 ms frame (tolerance 40 ms, i.e. 2 frames).
        let bursts: [Burst] = [(4, 6.5, 0.3), (9, 9.8, 0.25), (9.9, 12, 0.25), (20, 52, 0.2), (60, 61, 0.3), (70, 72, 0.3)]
        let samples = audio(seconds: 80, bursts, noise: 0.01)
        let batch = SpeechChunker.chunks(samples)
        let streamed = run(samples, batch: 1_234)
        XCTAssertGreaterThanOrEqual(batch.count, 5)
        XCTAssertEqual(streamed.count, batch.count)
        for (s, b) in zip(streamed, batch) {
            XCTAssertEqual(Double(s.start) / rate, Double(b.start) / rate, accuracy: 0.04)
            XCTAssertEqual(Double(s.end) / rate, Double(b.end) / rate, accuracy: 0.04)
        }
    }

    func testSpeechIsFoundAfterTheNoiseFloorRisesAndTheWindowAdapts() {
        var g = Noise()
        // Quiet room for 20 s, then a fan: noise amplitude 0.005 -> 0.03.
        let samples = audio(to: 130, [(10, 11, 0.2), (110, 112, 0.3)],
                            noise: { $0 < 20 ? 0.005 : 0.03 }, generator: &g)
        let chunks = seconds(run(samples))
        XCTAssertTrue(chunks.contains { $0.lowerBound < 10.5 && $0.upperBound > 10.5 })
        let late = chunks.filter { $0.lowerBound > 60 }
        XCTAssertEqual(late.count, 1, "Only the real speech after adapting, no noise chunks")
        XCTAssertEqual(late[0].lowerBound, 109.8, accuracy: 0.05)
        XCTAssertEqual(late[0].upperBound, 112.3, accuracy: 0.05)
    }

    func testStateStaysBoundedOverTwoHours() {
        // 7200 s as 720 repeats of a 10 s block (talk, a pause, a click, a long
        // stretch). Run at a 1.6 kHz rate (same 20 ms frames, 32 samples each)
        // so the test stays fast; the frame logic is rate independent.
        var settings = SpeechChunker.Settings()
        settings.sampleRate = 1_600
        var g = Noise()
        let bursts: [Burst] = [(1, 3, 0.2), (3.2, 4, 0.2), (6, 6.05, 0.4), (6.5, 9.9, 0.15)]
        let block: [Float] = (0..<16_000).map { i in
            let t = Double(i) / 1_600
            var s = 0.004 * g.next()
            for (start, end, amplitude) in bursts where t >= start && t < end {
                s += amplitude * Float(sin(2 * .pi * 20 * t))
            }
            return s
        }
        var chunker = StreamingSpeechChunker(settings: settings)
        var count = 0
        var peak = 0
        var lastEnd = 0
        for _ in 0..<720 {
            for chunk in chunker.append(block) {
                XCTAssertGreaterThanOrEqual(chunk.start, lastEnd)
                lastEnd = chunk.end
                count += 1
            }
            peak = max(peak, chunker.storedStateCount)
        }
        count += chunker.finish().count
        XCTAssertEqual(chunker.consumed, 720 * block.count)
        XCTAssertGreaterThanOrEqual(count, 1_400)
        // 30 s noise window (1500 frames, twice: ring + sorted) + one open region (<= ~1300 frames).
        XCTAssertLessThan(peak, 6_000)
    }
}
