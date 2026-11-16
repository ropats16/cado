import XCTest
import AVFoundation
import CAudioRing
import CoreAudio
@testable import Cado

/// Stands in for Core Audio: process objects, taps, aggregate devices and
/// IOProcs are counters; audio is delivered through the real C IOProc
/// (`vt_tap_io_proc`), so the realtime path into the ring is the shipped one.
final class FakeTapHAL: ProcessTapHAL {
    enum Step { case createTap, tapFormat, createDevice, createIOProc, startDevice }

    var failAt: Step?
    var failure: OSStatus = -50
    var format = FakeTapHAL.float32(rate: 48_000, channels: 2)
    var processes: [AudioProcess] = []
    var parents: [pid_t: pid_t] = [:]
    var deviceRunning = true

    private let lock = NSLock()
    private var nextID: AudioObjectID = 500
    private(set) var log: [String] = []
    private(set) var scopes: [TapScope] = []
    private(set) var liveTaps: Set<AudioObjectID> = []
    private(set) var liveDevices: Set<AudioObjectID> = []
    private(set) var liveIOProcs = 0
    private(set) var runningDevices = 0
    private var listeners: [Int: (object: AudioObjectID, selector: AudioObjectPropertySelector, onChange: () -> Void)] = [:]
    private var nextListener = 0
    private var state: OpaquePointer?

    var liveListeners: Int { lock.withLock { listeners.count } }
    var tapsCreated: Int { lock.withLock { scopes.count } }
    var isEmpty: Bool {
        lock.withLock { liveTaps.isEmpty && liveDevices.isEmpty && liveIOProcs == 0 && runningDevices == 0 && listeners.isEmpty }
    }

    static func float32(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        let bytes = 4 * channels
        return AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
    }

    private func record(_ entry: String) { lock.withLock { log.append(entry) } }
    private func fail(_ step: Step) throws { if failAt == step { throw HALStatusError(status: failure) } }
    private func newID() -> AudioObjectID { lock.withLock { nextID += 1; return nextID } }

    func audioProcesses() -> [AudioProcess] { lock.withLock { processes } }
    func parentPID(of pid: pid_t) -> pid_t? { lock.withLock { parents[pid] } }

    func createTap(_ scope: TapScope) throws -> (tap: AudioObjectID, uid: String) {
        record("createTap")
        try fail(.createTap)
        let id = newID()
        lock.withLock { scopes.append(scope); _ = liveTaps.insert(id) }
        return (id, "tap-\(id)")
    }
    func destroyTap(_ tap: AudioObjectID) { record("destroyTap"); lock.withLock { _ = liveTaps.remove(tap) } }
    func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        failAt == .tapFormat ? nil : lock.withLock { format }
    }
    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        record("createDevice(\(tapUID))")
        try fail(.createDevice)
        let id = newID()
        lock.withLock { _ = liveDevices.insert(id) }
        return id
    }
    func destroyAggregateDevice(_ device: AudioObjectID) { record("destroyDevice"); lock.withLock { _ = liveDevices.remove(device) } }
    func createIOProc(on device: AudioObjectID, state: OpaquePointer) throws -> IOProcToken {
        record("createIOProc")
        try fail(.createIOProc)
        lock.withLock { liveIOProcs += 1; self.state = state }
        return IOProcToken(device: device, id: nil)
    }
    func destroyIOProc(_ token: IOProcToken) { record("destroyIOProc"); lock.withLock { liveIOProcs -= 1; state = nil } }
    func startDevice(_ token: IOProcToken) throws {
        record("startDevice")
        try fail(.startDevice)
        lock.withLock { runningDevices += 1 }
    }
    func stopDevice(_ token: IOProcToken) { record("stopDevice"); lock.withLock { runningDevices -= 1 } }
    func isRunning(_ device: AudioObjectID) -> Bool { lock.withLock { deviceRunning && runningDevices > 0 } }
    func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     onChange: @escaping () -> Void) -> ListenerToken? {
        lock.withLock {
            nextListener += 1
            listeners[nextListener] = (object, selector, onChange)
            let id = nextListener
            return ListenerToken(object: object, address: AudioObjectPropertyAddress(
                mSelector: selector, mScope: AudioObjectPropertyScope(id), mElement: 0), block: { _, _ in })
        }
    }
    func removeListener(_ token: ListenerToken) {
        lock.withLock { _ = listeners.removeValue(forKey: Int(token.address.mScope)) }
    }

    /// Notifies every listener on `selector`, as Core Audio would.
    func fire(_ selector: AudioObjectPropertySelector) {
        let matching = lock.withLock { listeners.values.filter { $0.selector == selector }.map(\.onChange) }
        matching.forEach { $0() }
    }

    /// Plays `seconds` of interleaved Float32 at the tap's format through the
    /// real IOProc, `signal(t, channel)` per sample, in 512-frame slices.
    func deliver(seconds: Double, _ signal: (Double, Int) -> Float) {
        let (rate, channels) = lock.withLock { (format.mSampleRate, Int(format.mChannelsPerFrame)) }
        let total = Int((seconds * rate).rounded())
        var frame = 0
        var timestamp = AudioTimeStamp()
        var output = AudioBufferList()
        while frame < total {
            let n = min(512, total - frame)
            var samples = [Float](repeating: 0, count: n * channels)
            for i in 0..<n { for c in 0..<channels { samples[i * channels + c] = signal(Double(frame + i) / rate, c) } }
            samples.withUnsafeMutableBufferPointer { buffer in
                var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(buffer.count * 4), mData: buffer.baseAddress))
                let state = lock.withLock { self.state }
                _ = vt_tap_io_proc(0, &timestamp, &input, &timestamp, &output, &timestamp, state.map(UnsafeMutableRawPointer.init))
            }
            frame += n
        }
    }
}

/// `SystemAudioSource` against the fake: what it builds for which app, that
/// every start failure and every stop leaves nothing behind, the tap's native
/// format arriving as 16 kHz mono through `AudioCapture`, rebuilding when the
/// app's audio processes change, and running beside the mic.
@MainActor
final class SystemAudioSourceTests: XCTestCase {
    private var hal: FakeTapHAL!
    private var ring: OpaquePointer!
    private let zoom = SystemAudioTarget.app(bundleID: "us.zoom.xos", pid: 100)

    override func setUp() {
        super.setUp()
        hal = FakeTapHAL()
        hal.processes = [
            AudioProcess(object: 10, pid: 100, bundleID: "us.zoom.xos"),
            AudioProcess(object: 11, pid: 101, bundleID: "us.zoom.xos.helper"),
            AudioProcess(object: 20, pid: 200, bundleID: "com.spotify.client"),
            AudioProcess(object: 30, pid: getpid(), bundleID: "com.ropats16.Cado"),
        ]
        ring = vt_ring_create(1 << 16)
    }

    override func tearDown() {
        vt_ring_destroy(ring)
        super.tearDown()
    }

    /// The running apps the source sees (read on the capture's queue).
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var apps = [RunningApp(name: "zoom.us", bundleID: "us.zoom.xos", pid: 100),
                            RunningApp(name: "Spotify", bundleID: "com.spotify.client", pid: 200)]
        var list: [RunningApp] { lock.withLock { apps } }
        func launch(_ app: RunningApp) { lock.withLock { apps.append(app) } }
    }
    private let running = Running()

    private func source(_ target: SystemAudioTarget? = nil, observations: SystemAudioObservations = SystemAudioObservations(),
                        settle: TimeInterval = 0.05) -> SystemAudioSource {
        SystemAudioSource(target: target ?? zoom, hal: hal, runningApps: { [running] in running.list },
                          observations: observations, settleDelay: settle)
    }

    private var input: CaptureInput { CaptureInput(ring: ring, flush: {}) }

    // MARK: - Lifecycle

    func testStartTapsOnlyTheAppsProcessesThenBuildsItsDeviceAndCallback() throws {
        let source = source()

        XCTAssertEqual(try source.start(input), 48_000, "The tap's native rate goes to the capture")
        XCTAssertEqual(hal.scopes, [.processes([10, 11])], "Zoom and its helper; not Spotify, not Cado")
        XCTAssertEqual(hal.log, ["createTap", "createDevice(tap-501)", "createIOProc", "startDevice"])
        XCTAssertFalse(source.needsRestart)
        source.stop()
    }

    func testAnAppWithNoAudioProcessesYetGetsAnEmptyTap() throws {
        let source = source(.app(bundleID: "com.apple.Safari", pid: 300))
        _ = try source.start(input)
        XCTAssertEqual(hal.scopes, [.processes([])], "Silence until its first audio process appears")
        source.stop()
    }

    func testStopTearsDownInReverseAndLeavesNothing() throws {
        let source = source()
        _ = try source.start(input)
        source.stop()
        source.stop()   // harmless

        XCTAssertEqual(Array(hal.log.suffix(4)), ["stopDevice", "destroyIOProc", "destroyDevice", "destroyTap"])
        XCTAssertEqual(hal.log.filter { $0 == "destroyTap" }.count, 1, "Nothing is destroyed twice")
        XCTAssertTrue(hal.isEmpty, "No tap, device, IOProc or listener left")
    }

    func testAFailureAtAnyStepIsReportedAndLeavesNothingBehind() {
        let cases: [(FakeTapHAL.Step, SystemAudioSourceError)] = [
            (.createTap, .startFailed("creating the system-audio tap", -50)),
            (.tapFormat, .startFailed("reading the tap format", kAudioHardwareUnspecifiedError)),
            (.createDevice, .startFailed("creating the system-audio device", -50)),
            (.createIOProc, .startFailed("installing the callback", -50)),
            (.startDevice, .startFailed("starting the system-audio device", -50)),
        ]
        for (step, expected) in cases {
            hal = FakeTapHAL()
            hal.failAt = step
            let source = source()
            XCTAssertThrowsError(try source.start(input), "\(step)") { error in
                XCTAssertEqual(error as? SystemAudioSourceError, expected, "\(step)")
            }
            XCTAssertTrue(hal.isEmpty, "\(step): everything built before the failure is torn down")
            XCTAssertFalse(hal.log.contains("stopDevice"), "\(step): a device that never started isn't stopped")
        }
    }

    func testANonFloatTapFormatIsRefused() {
        hal.format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        hal.format.mBitsPerChannel = 16
        let source = source()

        XCTAssertThrowsError(try source.start(input)) { error in
            guard case .unsupportedFormat? = error as? SystemAudioSourceError else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
        XCTAssertTrue(hal.isEmpty)
    }

    func testBelowMacOS14_2StartReportsUnsupportedThroughTheCapture() async {
        let capture = AudioCapture(source: SystemAudioSource(target: zoom, hal: nil))
        let started = expectation(description: "start reported")
        var reported: Error?
        capture.begin { reported = $0; started.fulfill() }
        await fulfillment(of: [started], timeout: 5)

        XCTAssertEqual(reported as? SystemAudioSourceError, .unsupportedOS)
        XCTAssertEqual(reported?.localizedDescription, "Recording system audio needs macOS 14.2 or later.")
        XCTAssertFalse(capture.isRecording)
    }

    // MARK: - Restarts

    func testAFormatChangeOrStoppedDeviceNeedsARestartANoOpNoticeDoesnt() throws {
        let source = source()
        _ = try source.start(input)
        XCTAssertFalse(source.needsRestart, "A notice with nothing changed")

        hal.format = FakeTapHAL.float32(rate: 44_100, channels: 2)
        XCTAssertTrue(source.needsRestart, "Output moved to a 44.1 kHz device")
        hal.format = FakeTapHAL.float32(rate: 48_000, channels: 2)

        hal.deviceRunning = false
        XCTAssertTrue(source.needsRestart)
        source.stop()
    }

    func testTheAppsAudioProcessesChangingNeedsARestartOtherAppsDont() throws {
        let source = source()
        _ = try source.start(input)

        hal.processes.append(AudioProcess(object: 21, pid: 201, bundleID: "com.spotify.client.helper"))
        XCTAssertFalse(source.needsRestart, "Another app's helper isn't Zoom's business")

        running.launch(RunningApp(name: "Zoom Beta", bundleID: "us.zoom.xos.beta", pid: 300))
        hal.processes.append(AudioProcess(object: 31, pid: 300, bundleID: "us.zoom.xos.beta"))
        XCTAssertFalse(source.needsRestart, "Another app whose id starts with Zoom's isn't Zoom")

        hal.processes.append(AudioProcess(object: 12, pid: 102, bundleID: "us.zoom.CptHost"))
        hal.parents[102] = 100
        XCTAssertTrue(source.needsRestart, "Zoom spawned an audio helper")
        source.stop()
    }

    // MARK: - Through the capture

    private func begin(_ capture: AudioCapture) async {
        let started = expectation(description: "source started")
        capture.begin { error in
            XCTAssertNil(error)
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
    }

    /// Ends the recording, then plays `postRoll` seconds (the audio after the
    /// end), and waits for the result.
    private func end(_ capture: AudioCapture, thenPlay postRoll: () -> Void) async -> [Float] {
        var result: [Float] = []
        let ended = expectation(description: "recording ended")
        capture.end { result = $0; ended.fulfill() }
        _ = capture.retainedSampleCount   // the end is registered
        postRoll()
        await fulfillment(of: [ended], timeout: 5)
        return result
    }

    private func tone(_ hz: Double, amplitude: Float = 0.5) -> (Double, Int) -> Float {
        { t, _ in amplitude * Float(sin(2 * .pi * hz * t)) }
    }

    func testNative48kStereoArrivesAs16kMono() async {
        let capture = AudioCapture(source: source())
        await begin(capture)
        // Left carries the tone, right is silent: averaged, not one channel.
        hal.deliver(seconds: 1) { t, channel in channel == 0 ? 0.5 * Float(sin(2 * .pi * 440 * t)) : 0 }
        let samples = await end(capture) { hal.deliver(seconds: 0.3, tone(440)) }

        XCTAssertEqual(samples.count, 19_200, accuracy: 8, "1 s + 0.2 s post-roll at 16 kHz")
        XCTAssertEqual(AudioMeasure.frequency(Array(samples[0..<16_000])), 440, accuracy: 2)
        XCTAssertEqual(AudioMeasure.rms(samples[1_000..<15_000]), 0.25 / Float(2).squareRoot(), accuracy: 0.01)
    }

    func testAFormatChangeMidRecordingKeepsTheRecordingAtTheNewRate() async {
        let capture = AudioCapture(source: source())
        await begin(capture)
        hal.deliver(seconds: 0.5, tone(440))

        hal.format = FakeTapHAL.float32(rate: 44_100, channels: 1)   // e.g. AirPods connected
        hal.fire(kAudioTapPropertyFormat)
        _ = capture.retainedSampleCount
        XCTAssertEqual(hal.tapsCreated, 2, "The tap was rebuilt")
        hal.deliver(seconds: 0.5, tone(880))
        let samples = await end(capture) { hal.deliver(seconds: 0.3, tone(880)) }

        XCTAssertEqual(samples.count, 19_200, accuracy: 16, "0.5 s at 48 kHz + 0.5 s at 44.1 kHz + post-roll")
        XCTAssertEqual(AudioMeasure.frequency(Array(samples[10_000..<18_000])), 880, accuracy: 3)
    }

    func testAHelperBurstRebuildsTheTapOnceAroundTheNewSet() async throws {
        let capture = AudioCapture(source: source(settle: 0.1))
        await begin(capture)

        // A call starts: several helpers spawn, each a process-list notice.
        for (index, pid) in [102, 103, 104, 105, 106].enumerated() {
            hal.processes.append(AudioProcess(object: AudioObjectID(40 + index), pid: pid_t(pid), bundleID: "us.zoom.xos.helper"))
            hal.fire(kAudioHardwarePropertyProcessObjectList)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = capture.retainedSampleCount

        XCTAssertEqual(hal.scopes, [.processes([10, 11]), .processes([10, 11, 40, 41, 42, 43, 44])],
                       "One rebuild once the list settled — five would trip the capture's restart-loop guard")
        XCTAssertTrue(capture.isRecording, "The recording carries on")
        hal.deliver(seconds: 0.5, tone(440))
        let samples = await end(capture) { hal.deliver(seconds: 0.3, tone(440)) }
        XCTAssertGreaterThan(AudioMeasure.rms(samples.suffix(8_000)), 0.3, "Audio after the rebuild is recorded")
    }

    func testMicAndSystemAudioRecordAsTwoIndependentStreams() async throws {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try AudioMeasure.writeWav(wav, rate: 48_000, seconds: 2, tone(300))
        let mic = try WavFileSource(url: wav)
        let me = AudioCapture(source: mic)
        let them = AudioCapture(source: source(), idleSeconds: 0)

        await begin(me)
        await begin(them)
        mic.push(seconds: 1)
        hal.deliver(seconds: 1, tone(1_000))
        let meSamples = await end(me) { mic.push(seconds: 0.3) }
        let themSamples = await end(them) { hal.deliver(seconds: 0.3, tone(1_000)) }

        XCTAssertEqual(meSamples.count, 19_200, accuracy: 8)
        XCTAssertEqual(themSamples.count, 19_200, accuracy: 8)
        XCTAssertEqual(AudioMeasure.frequency(meSamples), 300, accuracy: 2, "Me is only the mic")
        XCTAssertEqual(AudioMeasure.frequency(themSamples), 1_000, accuracy: 3, "Them is only the app")
    }

    func testIdleSecondsZeroStopsTheTapAsSoonAsTheRecordingEnds() async throws {
        let them = AudioCapture(source: source(), idleSeconds: 0)
        await begin(them)
        hal.deliver(seconds: 0.5, tone(440))
        _ = await end(them) { hal.deliver(seconds: 0.3, tone(440)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = them.retainedSampleCount

        XCTAssertTrue(hal.isEmpty, "No lingering tap (or capture indicator) after the meeting")
    }

    // MARK: - Permission evidence

    func testOnlySoundProvesTheGrantAndItOutlivesTheSource() throws {
        let observations = SystemAudioObservations()
        var source: SystemAudioSource? = self.source(observations: observations)
        _ = try source!.start(input)

        hal.deliver(seconds: 0.1) { _, _ in 0 }
        XCTAssertFalse(source!.hasHeardSound, "Exact zeros: denied, or nothing played")
        XCTAssertFalse(observations.hasHeardSound)

        hal.deliver(seconds: 0.1, tone(440, amplitude: 0.01))
        XCTAssertTrue(source!.hasHeardSound)
        XCTAssertTrue(observations.hasHeardSound, "Readiness sees it while recording")

        source!.stop()
        XCTAssertTrue(source!.hasHeardSound, "Kept across stop/restart")
        source = nil
        XCTAssertTrue(observations.hasHeardSound, "Kept after the source is gone")
    }

    /// Stands in for a source whose last strong reference goes while its
    /// evidence is being read.
    private final class VanishingEvidence: HeardSoundEvidence {
        static var holder: VanishingEvidence?
        let observations: SystemAudioObservations
        init(_ observations: SystemAudioObservations) { self.observations = observations }
        deinit { observations.forget(self) }
        var hasHeardSound: Bool {
            Self.holder = nil   // e.g. the capture released on another thread
            return true
        }
    }

    func testReadingTheEvidenceWhileASourceGoesAwayDoesntDeadlock() {
        let observations = SystemAudioObservations()
        var evidence: VanishingEvidence? = VanishingEvidence(observations)
        VanishingEvidence.holder = evidence
        observations.watch(evidence!)
        evidence = nil   // only `holder` keeps it now

        let done = DispatchSemaphore(value: 0)
        var heard = false
        Thread.detachNewThread {
            heard = observations.hasHeardSound
            done.signal()
        }

        XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "The source's deinit took the lock the read held")
        XCTAssertTrue(heard)
    }

    func testTheCallbackDropsWhatTheRingCantHoldAndCountsWhatItWrote() {
        let small = vt_ring_create(1_024)!
        defer { vt_ring_destroy(small) }
        let state = vt_tap_create(small)!
        defer { vt_tap_destroy(state) }
        var samples = [Float](repeating: 0.25, count: 2_048 * 2)
        var timestamp = AudioTimeStamp()
        var output = AudioBufferList()

        samples.withUnsafeMutableBufferPointer { buffer in
            var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4), mData: buffer.baseAddress))
            _ = vt_tap_io_proc(0, &timestamp, &input, &timestamp, &output, &timestamp, UnsafeMutableRawPointer(state))
        }

        XCTAssertEqual(vt_tap_frames(state), 1_024, "2 048 stereo frames, room for 1 024: the rest is dropped, not blocked on")
        XCTAssertEqual(vt_tap_heard_sound(state), 1)
    }
}

/// Signal measurements and fixtures shared by the system-audio tests.
enum AudioMeasure {
    /// Frequency from positive-going zero crossings, ignoring the edges.
    static func frequency(_ samples: [Float], rate: Double = 16_000) -> Double {
        let body = samples.dropFirst(samples.count / 10).dropLast(samples.count / 10)
        var crossings = 0
        var previous = body.first ?? 0
        for s in body.dropFirst() {
            if previous < 0 && s >= 0 { crossings += 1 }
            previous = s
        }
        return Double(crossings) / (Double(body.count) / rate)
    }

    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func writeWav(_ url: URL, rate: Double, seconds: Double, _ signal: (Double, Int) -> Float) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let total = Int((seconds * rate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(total))!
        for i in 0..<total { buffer.floatChannelData![0][i] = signal(Double(i) / rate, 0) }
        buffer.frameLength = AVAudioFrameCount(total)
        try file.write(from: buffer)
    }
}
