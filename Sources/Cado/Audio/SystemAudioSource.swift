import CAudioRing
import CoreAudio
import Foundation

enum SystemAudioSourceError: LocalizedError, Equatable {
    /// Process taps need macOS 14.2.
    case unsupportedOS
    case startFailed(String, OSStatus)
    /// The tap delivers something other than linear-PCM Float32.
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedOS: return "Recording system audio needs macOS 14.2 or later."
        case .startFailed(let step, let status): return "Could not start recording system audio: \(step) failed (\(status))."
        case .unsupportedFormat(let format): return "System audio arrived in an unsupported format (\(format))."
        }
    }
}

/// Whose audio a `SystemAudioSource` records: only ever one app, never the
/// whole Mac's.
enum SystemAudioTarget: Equatable {
    /// One app — the meeting app — through its own and its helper processes
    /// (`AudioProcessMatcher`), never another running app's. `pid` is its
    /// main process. From `RecordableApp.target`.
    case app(bundleID: String, pid: pid_t)
}

/// System-audio adapter: what an app plays (the other side of a call),
/// through a Core Audio process tap. A mono mixdown of the target app's
/// audio processes, in a private aggregate device whose IOProc
/// (`vt_tap_io_proc`, C) downmixes into the capture's ring — no allocation,
/// locks, Swift or ObjC on the audio thread. The tap's native rate (usually
/// the output device's, e.g. 48 kHz) is returned to the capture, which
/// resamples to 16 kHz as it does for the mic.
///
/// Wrap it in its own `AudioCapture` to record it next to the mic: the two
/// captures are independent streams.
///
/// The app's audio processes change as it runs: a browser or Electron app
/// spawns an audio helper when a call starts and may replace it when the
/// call reconnects. The source watches Core Audio's process list; once it
/// has settled (`settleDelay`) and the app's set differs from the tapped
/// one, it reports a route change and `needsRestart` says yes, so the
/// capture rebuilds the tap around the new set and keeps the recording.
/// What the app plays during the rebuild (well under a second) is lost.
/// (Retargeting the live tap through `kAudioTapPropertyDescription` was
/// refused on hardware, `'!hog'`, so the tap is rebuilt instead.) An app
/// with no audio processes yet gets an empty tap — silence — until its
/// first one appears.
///
/// Permission: there's no public API to read or request it. The system asks
/// the first time a tap's device starts; without the grant (or without
/// `NSAudioCaptureUsageDescription` in the bundle) the tap delivers exact
/// zeros, never an error. So `hasHeardSound` (any non-zero sample) is the only
/// proof of a grant, and silence proves nothing — nothing may have played.
final class SystemAudioSource: AudioSource {
    var onEvent: ((AudioSourceEvent) -> Void)?

    /// Whether this macOS has process taps (14.2+).
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// The live Core Audio boundary, or nil below macOS 14.2.
    static func liveHAL() -> ProcessTapHAL? {
        if #available(macOS 14.2, *) { return CoreAudioProcessTapHAL() }
        return nil
    }

    let target: SystemAudioTarget
    private let hal: ProcessTapHAL?
    private let runningApps: () -> [RunningApp]
    private let observations: SystemAudioObservations
    private let settleDelay: TimeInterval

    // Touched only on the capture's queue.
    private var tap: AudioObjectID?
    private var device: AudioObjectID?
    private var ioProc: IOProcToken?
    private var deviceStarted = false
    private var openedFormat: AudioStreamBasicDescription?
    /// The process objects the running tap mixes.
    private var tappedProcesses: Set<AudioObjectID> = []
    private var listeners: [ListenerToken] = []

    /// Coalesces process-list notifications (a call start spawns several
    /// helpers at once), so the tap is rebuilt once, not per helper — and
    /// the capture's restart-loop guard isn't tripped.
    private let settleLock = NSLock()
    private var settleGeneration = 0

    /// The IOProc's state (`vt_tap *`). Also read by `hasHeardSound` from
    /// any thread, so guarded.
    private let stateLock = NSLock()
    private var state: OpaquePointer?
    private var heardInEarlierRun = false

    /// `hal` nil = unsupported OS: `start` throws `.unsupportedOS`.
    /// `runningApps`: the other apps whose processes must never be tapped
    /// (read on the capture's queue). `settleDelay`: how long the app's
    /// process list must be quiet before the tap is rebuilt around it.
    init(target: SystemAudioTarget, hal: ProcessTapHAL? = SystemAudioSource.liveHAL(),
         runningApps: @escaping () -> [RunningApp] = RecordableApps.runningApps,
         observations: SystemAudioObservations = .shared, settleDelay: TimeInterval = 1.0) {
        self.target = target
        self.hal = hal
        self.runningApps = runningApps
        self.observations = observations
        self.settleDelay = settleDelay
    }

    /// Nothing else holds the source by now, so stopping here (off the
    /// capture's queue) can't race it; `AudioCapture` normally stopped it.
    deinit {
        stop()
        if hasHeardSound { observations.noteHeardSound() }
        observations.forget(self)
    }

    /// Whether any non-zero sample has arrived since this source was made
    /// (across restarts). True proves the system-audio permission is granted.
    var hasHeardSound: Bool {
        stateLock.withLock { heardInEarlierRun || (state.map { vt_tap_heard_sound($0) != 0 } ?? false) }
    }

    /// True when the device stopped, the tap's format changed (e.g. the
    /// output switched from 48 kHz speakers to AirPods), or the app's audio
    /// processes are no longer the tapped ones. Property notifications also
    /// arrive for no-op changes, so the capture asks before restarting.
    var needsRestart: Bool {
        guard let hal, let tap, let device, deviceStarted else { return false }
        let current = hal.tapFormat(tap)
        return !hal.isRunning(device)
            || current?.mSampleRate != openedFormat?.mSampleRate
            || current?.mChannelsPerFrame != openedFormat?.mChannelsPerFrame
            || Set(targetProcesses(hal)) != tappedProcesses
    }

    /// The tap's device keeps calling back with zeros while nothing plays
    /// (even with no processes tapped), so a few seconds of nothing means it
    /// died (e.g. under a format change).
    let stallTimeout: TimeInterval? = 3.0

    func start(_ input: CaptureInput) throws -> Double {
        guard let hal else { throw SystemAudioSourceError.unsupportedOS }
        observations.watch(self)
        do { return try open(input, hal) } catch {
            stop()
            throw error
        }
    }

    /// The target app's process objects now.
    private func targetProcesses(_ hal: ProcessTapHAL) -> [AudioObjectID] {
        switch target {
        case .app(let bundleID, let pid):
            return AudioProcessMatcher.processes(of: bundleID, pid: pid, in: hal.audioProcesses(),
                                                 otherApps: runningApps(), parentPID: hal.parentPID(of:)).map(\.object)
        }
    }

    /// Builds and starts tap → aggregate device → IOProc, leaving whatever it
    /// got to for `stop`.
    private func open(_ input: CaptureInput, _ hal: ProcessTapHAL) throws -> Double {
        // Listen first, so a helper appearing during start is caught.
        listen(hal, to: AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
               settling: true)
        let processes = targetProcesses(hal)
        tappedProcesses = Set(processes)
        let scope = TapScope.processes(processes)
        let created = try step("creating the system-audio tap") { try hal.createTap(scope) }
        tap = created.tap
        listen(hal, to: created.tap, kAudioTapPropertyFormat)

        guard let format = hal.tapFormat(created.tap) else {
            throw SystemAudioSourceError.startFailed("reading the tap format", kAudioHardwareUnspecifiedError)
        }
        try Self.validate(format)
        openedFormat = format
        Log.info("System audio: tapping \(describe(scope)); \(format.mChannelsPerFrame) ch @ \(Int(format.mSampleRate)) Hz.")

        let device = try step("creating the system-audio device") { try hal.createAggregateDevice(tapUID: created.uid) }
        self.device = device
        listen(hal, to: device, kAudioDevicePropertyDeviceIsAlive)
        listen(hal, to: device, kAudioDevicePropertyNominalSampleRate)

        guard let state = vt_tap_create(input.ring) else {
            throw SystemAudioSourceError.startFailed("allocating the callback", kAudioHardwareUnspecifiedError)
        }
        stateLock.withLock { self.state = state }
        let ioProc = try step("installing the callback") { try hal.createIOProc(on: device, state: state) }
        self.ioProc = ioProc
        try step("starting the system-audio device") { try hal.startDevice(ioProc) }
        deviceStarted = true
        return format.mSampleRate
    }

    /// Tears down in reverse: stop IO, then the IOProc, device and tap, and
    /// only then the state the IOProc wrote through. Safe after any partial
    /// start, and twice.
    func stop() {
        guard let hal else { return }
        for listener in listeners { hal.removeListener(listener) }
        listeners = []
        settleLock.withLock { settleGeneration += 1 }   // drops a pending settled notice
        if let ioProc {
            if deviceStarted { hal.stopDevice(ioProc) }
            hal.destroyIOProc(ioProc)
        }
        ioProc = nil
        deviceStarted = false
        if let device { hal.destroyAggregateDevice(device) }
        device = nil
        if let tap { hal.destroyTap(tap) }
        tap = nil
        openedFormat = nil
        tappedProcesses = []
        stateLock.withLock {
            if let state {
                if vt_tap_heard_sound(state) != 0 { heardInEarlierRun = true }
                vt_tap_destroy(state)
            }
            state = nil
        }
    }

    // MARK: - Helpers

    /// The ring downmixes Float32 of any channel layout; anything else isn't
    /// something a tap is known to deliver.
    static func validate(_ format: AudioStreamBasicDescription) throws {
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        guard isFloat32, format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw SystemAudioSourceError.unsupportedFormat(
                "\(fourCC(format.mFormatID)), \(format.mBitsPerChannel)-bit, flags \(format.mFormatFlags), "
                + "\(format.mChannelsPerFrame) ch @ \(format.mSampleRate) Hz")
        }
    }

    private static func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    private func describe(_ scope: TapScope) -> String {
        switch (target, scope) {
        case (.app(let bundleID, _), .processes(let processes)): return "\(bundleID) (\(processes.count) process(es))"
        }
    }

    /// Reports any change to the property as a possible route change; the
    /// capture checks `needsRestart`. `settling` waits for `settleDelay` of
    /// quiet first.
    private func listen(_ hal: ProcessTapHAL, to object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        settling: Bool = false) {
        let token = hal.addListener(object, selector) { [weak self] in
            guard let self else { return }
            if settling { settleThenReport() } else { onEvent?(.routeChanged) }
        }
        if let token { listeners.append(token) }
    }

    private func settleThenReport() {
        let generation = settleLock.withLock {
            settleGeneration += 1
            return settleGeneration
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self, settleLock.withLock({ generation == self.settleGeneration }) else { return }
            onEvent?(.routeChanged)
        }
    }

    private func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as HALStatusError {
            throw SystemAudioSourceError.startFailed(name, error.status)
        }
    }
}

/// A live source of permission evidence (`SystemAudioSource`).
protocol HeardSoundEvidence: AnyObject {
    var hasHeardSound: Bool { get }
}

extension SystemAudioSource: HeardSoundEvidence {}

/// What this run has seen of the system-audio permission, for readiness.
/// No public API reads the permission, so the only evidence is a running
/// tap delivering sound. Kept in memory only: the grant is tied to the code
/// signature and can be revoked at any time, so an old observation could lie.
///
/// A watched source is only ever made strong outside `lock`: its last
/// release can run its deinit, which calls `forget` and takes the lock.
final class SystemAudioObservations {
    static let shared = SystemAudioObservations()

    private let lock = NSLock()
    private var confirmed = false
    private var sources: [ObjectIdentifier: WeakSource] = [:]

    private struct WeakSource { weak var source: HeardSoundEvidence? }

    /// Whether any system-audio capture this run has delivered sound.
    var hasHeardSound: Bool {
        // Copying the weak references takes no strong ones.
        let (known, watched) = lock.withLock { (confirmed, Array(sources.values)) }
        if known { return true }
        guard watched.contains(where: { $0.source?.hasHeardSound == true }) else { return false }
        noteHeardSound()
        return true
    }

    /// Records a sound heard by a source that's going away.
    func noteHeardSound() {
        lock.withLock { confirmed = true }
    }

    func watch(_ source: HeardSoundEvidence) {
        lock.withLock { sources[ObjectIdentifier(source)] = WeakSource(source: source) }
    }

    func forget(_ source: HeardSoundEvidence) {
        lock.withLock { _ = sources.removeValue(forKey: ObjectIdentifier(source)) }
    }
}
