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

/// System-audio adapter: what the Mac plays (the other side of a call),
/// through a Core Audio process tap. A mono global tap of every process
/// except Cado, in a private aggregate device whose IOProc
/// (`vt_tap_io_proc`, C) downmixes into the capture's ring — no allocation,
/// locks, Swift or ObjC on the audio thread. The tap's native rate (usually
/// the output device's, e.g. 48 kHz) is returned to the capture, which
/// resamples to 16 kHz as it does for the mic.
///
/// Wrap it in its own `AudioCapture` to record it next to the mic: the two
/// captures are independent streams.
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

    private let hal: ProcessTapHAL?
    private let observations: SystemAudioObservations

    // Touched only on the capture's queue.
    private var tap: AudioObjectID?
    private var device: AudioObjectID?
    private var ioProc: IOProcToken?
    private var deviceStarted = false
    private var openedFormat: AudioStreamBasicDescription?
    private var listeners: [ListenerToken] = []

    /// The IOProc's state (`vt_tap *`). Also read by `hasHeardSound` from
    /// any thread, so guarded.
    private let stateLock = NSLock()
    private var state: OpaquePointer?
    private var heardInEarlierRun = false

    /// `hal` nil = unsupported OS: `start` throws `.unsupportedOS`.
    init(hal: ProcessTapHAL? = SystemAudioSource.liveHAL(),
         observations: SystemAudioObservations = .shared) {
        self.hal = hal
        self.observations = observations
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

    /// True when the device stopped or the tap's format changed (e.g. the
    /// output switched from 48 kHz speakers to AirPods). Property
    /// notifications also arrive for no-op changes, so the capture asks
    /// before restarting.
    var needsRestart: Bool {
        guard let hal, let tap, let device, deviceStarted else { return false }
        let current = hal.tapFormat(tap)
        return !hal.isRunning(device)
            || current?.mSampleRate != openedFormat?.mSampleRate
            || current?.mChannelsPerFrame != openedFormat?.mChannelsPerFrame
    }

    /// The tap's device keeps calling back with zeros while nothing plays,
    /// so a few seconds of nothing means it died (e.g. under a format change).
    let stallTimeout: TimeInterval? = 3.0

    func start(_ input: CaptureInput) throws -> Double {
        guard let hal else { throw SystemAudioSourceError.unsupportedOS }
        observations.watch(self)
        do { return try open(input, hal) } catch {
            stop()
            throw error
        }
    }

    /// Builds and starts tap → aggregate device → IOProc, leaving whatever it
    /// got to for `stop`.
    private func open(_ input: CaptureInput, _ hal: ProcessTapHAL) throws -> Double {
        let excluded = hal.ownProcessObject().map { [$0] } ?? []
        let created = try step("creating the system-audio tap") { try hal.createTap(excluding: excluded) }
        tap = created.tap

        // Listen before reading the format, so a change during start is caught.
        listen(hal, to: created.tap, kAudioTapPropertyFormat)

        guard let format = hal.tapFormat(created.tap) else {
            throw SystemAudioSourceError.startFailed("reading the tap format", kAudioHardwareUnspecifiedError)
        }
        try Self.validate(format)
        openedFormat = format
        Log.info("System audio: tap delivers \(format.mChannelsPerFrame) ch @ \(Int(format.mSampleRate)) Hz.")

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

    /// Reports any change to the property as a possible route change; the
    /// capture checks `needsRestart`.
    private func listen(_ hal: ProcessTapHAL, to object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        let token = hal.addListener(object, selector) { [weak self] in self?.onEvent?(.routeChanged) }
        if let token { listeners.append(token) }
    }

    private func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as HALStatusError {
            throw SystemAudioSourceError.startFailed(name, error.status)
        }
    }
}

/// What this run has seen of the system-audio permission, for readiness.
/// No public API reads the permission, so the only evidence is a running
/// tap delivering sound. Kept in memory only: the grant is tied to the code
/// signature and can be revoked at any time, so an old observation could lie.
final class SystemAudioObservations {
    static let shared = SystemAudioObservations()

    private let lock = NSLock()
    private var confirmed = false
    private var sources: [ObjectIdentifier: WeakSource] = [:]

    private struct WeakSource { weak var source: SystemAudioSource? }

    /// Whether any system-audio capture this run has delivered sound.
    var hasHeardSound: Bool {
        lock.withLock {
            if !confirmed && sources.values.contains(where: { $0.source?.hasHeardSound == true }) { confirmed = true }
            return confirmed
        }
    }

    /// Records a sound heard outside a `SystemAudioSource` (tests, or a source
    /// already gone).
    func noteHeardSound() {
        lock.withLock { confirmed = true }
    }

    func watch(_ source: SystemAudioSource) {
        lock.withLock { sources[ObjectIdentifier(source)] = WeakSource(source: source) }
    }

    func forget(_ source: SystemAudioSource) {
        lock.withLock { _ = sources.removeValue(forKey: ObjectIdentifier(source)) }
    }
}
