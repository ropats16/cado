import XCTest
import AVFoundation
@testable import Cado

/// `AudioCapture` handing samples over as they're recorded (`onSamples`), and
/// not keeping them (`retainsSamples: false`), for meetings transcribed while
/// they run (#31). Driven like `AudioCaptureTests`: WAV-backed sources pushed
/// by hand, a test clock, no mic, no sleeps.
@MainActor
final class AudioCaptureStreamingTests: XCTestCase {

    // MARK: - Fixtures

    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("capture-stream-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func wav(rate: Double = 48_000, seconds: Double,
                     _ signal: @escaping (Double, Int) -> Float = { t, _ in 0.5 * Float(sin(2 * .pi * 440 * t)) }) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
        try AudioMeasure.writeWav(url, rate: rate, seconds: seconds, signal)
        return url
    }

    /// Everything a capture hands to `onSamples`, and whether it came on main.
    private final class Deliveries {
        private(set) var batches: [[Float]] = []
        private(set) var offMain = 0
        /// Set by the test once `end`'s completion has run.
        var ended = false
        private(set) var afterEnd = 0
        var onBatch: (() -> Void)?

        var all: [Float] { batches.flatMap { $0 } }
        var count: Int { batches.reduce(0) { $0 + $1.count } }

        func attach(to capture: AudioCapture) {
            capture.onSamples = { [self] batch in
                if !Thread.isMainThread { offMain += 1 }
                if ended { afterEnd += 1 }
                batches.append(batch)
                onBatch?()
            }
        }
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 100
        var now: TimeInterval { lock.withLock { time } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private func begin(_ capture: AudioCapture) async {
        let started = expectation(description: "source started")
        capture.begin { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
    }

    /// Ends, pushes `postRoll` s, and returns the result; `deliveries.ended`
    /// is set inside the completion, so anything delivered later is counted.
    private func end(_ capture: AudioCapture, _ source: WavFileSource? = nil, thenPush postRoll: Double = 0,
                     _ deliveries: Deliveries? = nil) async -> [Float] {
        var result: [Float] = []
        let ended = expectation(description: "recording ended")
        capture.end { result = $0; deliveries?.ended = true; ended.fulfill() }
        _ = capture.retainedSampleCount
        if postRoll > 0 { source?.push(seconds: postRoll) }
        await fulfillment(of: [ended], timeout: 5)
        return result
    }

    /// Waits until the capture's queue is idle and everything it sent to main
    /// has run.
    private func settle(_ capture: AudioCapture) async {
        _ = capture.retainedSampleCount
        let done = expectation(description: "main drained")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
    }

    private func play(_ source: WavFileSource, seconds: Double, clock: TestClock) {
        for _ in 0..<Int((seconds * 100).rounded()) {
            clock.advance(0.01)
            source.push(seconds: 0.01)
        }
    }

    /// Bit-exact equality, reported as counts and the first difference
    /// rather than two arrays of tens of thousands of samples.
    private func assertSame(_ a: [Float], _ b: [Float], _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        guard a != b else { return }
        let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTFail("\(message) — counts \(a.count) vs \(b.count), first difference at \(first.map(String.init) ?? "the end")",
                file: file, line: line)
    }

    private static let batch = Int(AudioCapture.streamBatchSeconds * AudioCapture.sampleRate)

    // MARK: - Completeness and order

    func testDeliveriesConcatenateToExactlyWhatEndReturnsPreRollFirst() async throws {
        let source = try WavFileSource(url: try wav(seconds: 4))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        try capture.warmUp()
        source.push(seconds: 1)

        await begin(capture)
        source.push(seconds: 2.1)
        let samples = await end(capture, source, thenPush: 0.5, deliveries)

        XCTAssertEqual(samples.count, 41_600, accuracy: 8, "0.3 s pre-roll + 2.1 s + 0.2 s post-roll")
        assertSame(deliveries.all, samples, "Bit-exact, in order, each sample once")
        XCTAssertGreaterThan(deliveries.batches.count, 4)
        XCTAssertEqual(deliveries.offMain, 0, "Delivered on main")
    }

    func testSamplesArriveWhileRecordingNotOnlyAtTheEnd() async throws {
        let source = try WavFileSource(url: try wav(seconds: 4))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)

        source.push(seconds: 2)
        await settle(capture)

        XCTAssertTrue(capture.isRecording)
        XCTAssertGreaterThan(deliveries.count, 32_000 - Self.batch - 1, "All but the last partial batch is out")
        let samples = await end(capture, source, thenPush: 0.5, deliveries)
        assertSame(deliveries.all, samples)
    }

    func testBatchesAreHalfASecondWhateverSizeTheSourceWritesIn() async throws {
        XCTAssertEqual(Self.batch, 8_000)
        for slices in [false, true] {
            let clock = TestClock()   // never moves 1 s between batches: only full batches
            let source = try WavFileSource(url: try wav(seconds: 4))
            let capture = AudioCapture(source: source, now: { clock.now })
            let deliveries = Deliveries()
            deliveries.attach(to: capture)
            await begin(capture)

            // 4096-frame writes, or 10 ms (480-frame) ones as a live mic does.
            if slices { play(source, seconds: 3, clock: clock) } else { source.push(seconds: 3) }
            let samples = await end(capture, source, thenPush: 0.5, deliveries)

            assertSame(deliveries.all, samples)
            XCTAssertEqual(Set(deliveries.batches.dropLast().map(\.count)), [Self.batch], "slices: \(slices)")
            XCTAssertLessThanOrEqual(deliveries.batches.last?.count ?? 0, Self.batch)
        }
    }

    func testPartialBatchesGoOutAtLeastOnceASecondWhenAudioTrickles() async throws {
        let clock = TestClock()
        let source = try WavFileSource(url: try wav(seconds: 4))
        let capture = AudioCapture(source: source, now: { clock.now })
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)

        source.push(seconds: 0.1)
        await settle(capture)
        XCTAssertEqual(deliveries.count, 0, "Under a batch, under a second: held")

        clock.advance(1)
        source.push(seconds: 0.01)
        await settle(capture)
        XCTAssertGreaterThan(deliveries.count, 1_500, "A second on: what's pending goes out")

        let samples = await end(capture, source, thenPush: 0.5, deliveries)
        assertSame(deliveries.all, samples)
    }

    func testEverythingPendingIsDeliveredBeforeEndCompletes() async throws {
        let source = try WavFileSource(url: try wav(seconds: 4))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)
        source.push(seconds: 1.3)

        var deliveredAtCompletion = -1
        var result: [Float] = []
        let ended = expectation(description: "ended")
        capture.end { result = $0; deliveredAtCompletion = deliveries.count; ended.fulfill() }
        _ = capture.retainedSampleCount
        source.push(seconds: 0.5)
        await fulfillment(of: [ended], timeout: 5)

        XCTAssertEqual(deliveredAtCompletion, result.count, "The partial last batch came first")
        assertSame(deliveries.all, result)
    }

    // MARK: - Without retention

    /// Records `seconds` of a 3 s file from a cold start, with or without
    /// keeping it.
    private func record(_ url: URL, seconds: Double, retains: Bool,
                        maxSeconds: Double = 0) async throws -> (samples: [Float], delivered: [Float]) {
        let source = try WavFileSource(url: url)
        let capture = AudioCapture(source: source, maxSeconds: { maxSeconds }, retainsSamples: retains)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)
        source.push(seconds: seconds)
        let samples = await end(capture, source, thenPush: 0.5, deliveries)
        await settle(capture)
        XCTAssertEqual(deliveries.afterEnd, 0)
        return (samples, deliveries.all)
    }

    func testWithoutRetentionEndGivesNothingAndTheDeliveriesAreTheWholeRecording() async throws {
        let url = try wav(seconds: 3)
        let kept = try await record(url, seconds: 2, retains: true)
        let streamed = try await record(url, seconds: 2, retains: false)

        XCTAssertEqual(kept.samples.count, 35_200, accuracy: 8)
        XCTAssertEqual(streamed.samples.count, 0, "Nothing kept")
        assertSame(streamed.delivered, kept.samples, "…and nothing lost")
    }

    func testWithoutRetentionMemoryStaysFlatOverALongRecording() async throws {
        let source = try WavFileSource(url: try wav(rate: 8_000, seconds: 6 * 60) { _, _ in 0 })
        let capture = AudioCapture(source: source, retainsSamples: false)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)

        source.push(seconds: 60)
        let afterOneMinute = capture.retainedSampleCount
        source.push(seconds: 4 * 60)
        let afterFiveMinutes = capture.retainedSampleCount

        XCTAssertLessThan(afterOneMinute, Self.batch, "At most a partial batch is held")
        XCTAssertLessThan(afterFiveMinutes, Self.batch)
        let samples = await end(capture, source, thenPush: 0.5, deliveries)
        XCTAssertEqual(samples.count, 0)
        XCTAssertEqual(deliveries.count, 5 * 60 * 16_000 + 3_200, accuracy: 64,
                       "Every sample delivered, plus the post-roll (± resampler latency)")
    }

    func testTheCapReachedMidBatchDeliversExactlyTheCap() async throws {
        let url = try wav(seconds: 3)
        let cap = Int((0.7 + AudioCapture.preRollSeconds + AudioCapture.postRollSeconds) * 16_000)
        XCTAssertNotEqual(cap % Self.batch, 0, "The cap falls inside a batch")

        let kept = try await record(url, seconds: 2, retains: true, maxSeconds: 0.7)
        let streamed = try await record(url, seconds: 2, retains: false, maxSeconds: 0.7)

        XCTAssertEqual(kept.samples.count, cap)
        assertSame(kept.delivered, kept.samples)
        assertSame(streamed.delivered, kept.samples, "Without retention the cap still applies by count")
    }

    // MARK: - Keeping time

    /// 1 s of 440 Hz, a restart and 2 s of nothing, then 1 s of 880 Hz.
    private func recordAcrossAGap(retains: Bool) async throws -> (samples: [Float], delivered: [Float]) {
        let clock = TestClock()
        let source = try WavFileSource(url: try wav(seconds: 2))
        let capture = AudioCapture(source: source, idleSeconds: 0, keepsTime: true,
                                   retainsSamples: retains, now: { clock.now })
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)
        play(source, seconds: 1, clock: clock)
        try source.open(try wav(seconds: 2) { t, _ in 0.5 * Float(sin(2 * .pi * 880 * t)) })
        _ = capture.retainedSampleCount   // restarted
        clock.advance(2)
        play(source, seconds: 1, clock: clock)
        let samples = await end(capture, source, thenPush: 0.2, deliveries)
        return (samples, deliveries.all)
    }

    func testARestartGapIsDeliveredAsSilenceWhereItHappened() async throws {
        let kept = try await recordAcrossAGap(retains: true)
        assertSame(kept.delivered, kept.samples)

        let streamed = try await recordAcrossAGap(retains: false).delivered
        XCTAssertEqual(streamed.count, 67_200, accuracy: 160, "1 s + 2 s gap + 1 s + 0.2 s: wall-clock length")
        guard streamed.count > 60_000 else { return }
        XCTAssertGreaterThan(AudioMeasure.rms(streamed[1_000..<15_000]), 0.3)
        XCTAssertLessThan(AudioMeasure.rms(streamed[17_000..<47_000]), 0.001, "The gap is silence")
        let resumed = streamed.indices.dropFirst(20_000).first { abs(streamed[$0]) > 0.1 } ?? 0
        XCTAssertEqual(resumed, 48_000, accuracy: 160, "The 880 Hz tone comes 3 s in")
    }

    // MARK: - Lost, failed, early and repeated ends

    func testALostSourceDeliversUpToTheLossBeforeReportingItThenNothing() async throws {
        let source = try WavFileSource(url: try wav(seconds: 1))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        var deliveredWhenLost = -1
        let lost = expectation(description: "source lost")
        capture.onSourceLost = { deliveredWhenLost = deliveries.count; lost.fulfill() }
        await begin(capture)

        source.push()   // to the file's end
        await fulfillment(of: [lost], timeout: 5)
        let batchesWhenLost = deliveries.batches.count
        let samples = await end(capture, nil, thenPush: 0, deliveries)

        XCTAssertEqual(samples.count, 16_000, accuracy: 1)
        XCTAssertEqual(deliveredWhenLost, samples.count, "Everything up to the loss is out before it's reported")
        XCTAssertEqual(deliveries.batches.count, batchesWhenLost, "Nothing after")
        assertSame(deliveries.all, samples)
    }

    private final class FailingSource: AudioSource {
        var onEvent: ((AudioSourceEvent) -> Void)?
        let needsRestart = false
        let stallTimeout: TimeInterval? = nil
        func start(_ input: CaptureInput) throws -> Double { throw MicSourceError.noInputAvailable }
        func stop() {}
    }

    func testAFailedBeginDeliversNothing() async throws {
        let capture = AudioCapture(source: FailingSource())
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        let started = expectation(description: "start reported")
        capture.begin { XCTAssertNotNil($0); started.fulfill() }
        await fulfillment(of: [started], timeout: 5)

        let samples = await end(capture)
        await settle(capture)

        XCTAssertEqual(samples.count, 0)
        XCTAssertEqual(deliveries.batches.count, 0)
    }

    func testEndRightAfterBeginStillDeliversEverything() async throws {
        let source = try WavFileSource(url: try wav(seconds: 3))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        try capture.warmUp()
        source.push(seconds: 1)

        capture.begin { XCTAssertNil($0) }
        let samples = await end(capture, source, thenPush: 0.5, deliveries)

        XCTAssertEqual(samples.count, 8_000, accuracy: 8, "0.3 s pre-roll + 0.2 s post-roll")
        assertSame(deliveries.all, samples)
    }

    func testNothingIsDeliveredOutsideARecordingOrAfterEnd() async throws {
        let source = try WavFileSource(url: try wav(seconds: 6))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        try capture.warmUp()
        source.push(seconds: 1)   // warm, not recording
        await settle(capture)
        XCTAssertEqual(deliveries.batches.count, 0, "Not begun: nothing")

        await begin(capture)
        source.push(seconds: 1)
        let samples = await end(capture, source, thenPush: 0.5, deliveries)
        let again = await end(capture, source, thenPush: 0, nil)
        source.push(seconds: 1)   // still warm
        await settle(capture)

        XCTAssertEqual(again.count, 0)
        assertSame(deliveries.all, samples)
        XCTAssertEqual(deliveries.afterEnd, 0, "Never after end's completion")
    }

    func testCancelDeliversNothingMore() async throws {
        let source = try WavFileSource(url: try wav(seconds: 4))
        let capture = AudioCapture(source: source)
        let deliveries = Deliveries()
        deliveries.attach(to: capture)
        await begin(capture)
        source.push(seconds: 1.3)
        await settle(capture)
        let before = deliveries.count

        capture.cancel()
        source.push(seconds: 1)
        await settle(capture)

        XCTAssertEqual(deliveries.count, before, "The pending part is discarded with the recording")
        XCTAssertEqual(capture.retainedSampleCount, 4_800, "Only the pre-roll is held")
    }

    // MARK: - Unused (dictation)

    func testWithoutOnSamplesTheRecordingIsUnchanged() async throws {
        let url = try wav(seconds: 4)
        func run(streaming: Bool) async throws -> (atCap: Int, samples: [Float]) {
            let source = try WavFileSource(url: url)
            let capture = AudioCapture(source: source, maxSeconds: { 1 })
            if streaming { Deliveries().attach(to: capture) }
            await begin(capture)
            source.push(seconds: 2)
            let atCap = capture.retainedSampleCount
            return (atCap, await end(capture, source, thenPush: 0.5))
        }
        let plain = try await run(streaming: false)
        let streaming = try await run(streaming: true)

        XCTAssertEqual(plain.atCap, 24_000, "Only the recording is held")
        XCTAssertEqual(plain.samples.count, 24_000)
        assertSame(plain.samples, streaming.samples)
    }
}
