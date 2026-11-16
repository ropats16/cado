import AVFoundation
import Foundation

/// `Cado --system-audio-test [--list] [--app <bundle id>] [--seconds <n>] [--out <file.wav>]`
///
/// `--list` prints the apps a meeting could record (`RecordableApps`) and
/// the Core Audio processes each one's tap would mix, then exits.
///
/// Otherwise records `n` seconds (default 5) of one app's audio (`--app`;
/// without it, the one running known meeting app) — never everything the
/// Mac plays — through the same capture path a meeting uses (`SystemAudioSource` in an `AudioCapture`), writes it
/// as a 16 kHz mono WAV (default: the temp folder's
/// `cado-system-audio-test.wav`), and reports whether any sound arrived.
/// Play something in that app while it runs.
///
/// The system-audio permission belongs to the app the process is attributed
/// to. To exercise Cado's own grant and usage string, launch the packaged app
/// through LaunchServices, so it's responsible for itself:
/// `open -W --stderr /tmp/cado-sat.log dist/Cado.app --args --system-audio-test --out /tmp/cado-sat.wav`.
/// Run straight from a terminal (`swift run`, or the bundle's binary), the
/// terminal app is asked instead.
///
/// Exit status: 0 sound captured; 3 only silence (permission not granted, or
/// nothing played); 1 the capture failed; 2 bad usage or macOS < 14.2.
enum SystemAudioSelfTest {
    static func run(arguments: [String]) -> Int32 {
        let seconds = CommandLineSupport.value("--seconds", in: arguments).flatMap(Double.init) ?? 5
        let out = URL(fileURLWithPath: CommandLineSupport.value("--out", in: arguments)
                      ?? NSTemporaryDirectory() + "cado-system-audio-test.wav")
        guard seconds > 0 else {
            err("usage: Cado --system-audio-test [--list] [--app <bundle id>] [--seconds <n>] [--out <file.wav>]")
            return 2
        }
        guard SystemAudioSource.isSupported, let hal = SystemAudioSource.liveHAL() else {
            err("failed: \(SystemAudioSourceError.unsupportedOS.localizedDescription)")
            return 2
        }
        let apps = RecordableApps.current(hal: hal)
        if arguments.contains("--list") {
            list(apps, hal)
            return 0
        }

        let target: SystemAudioTarget
        if let bundleID = CommandLineSupport.value("--app", in: arguments) {
            guard let app = RecordableApps.runningApps().first(where: {
                $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
            }) else {
                err("failed: \(bundleID) isn't running")
                return 2
            }
            target = .app(bundleID: app.bundleID, pid: app.pid)
        } else {
            let meetingApps = apps.filter(\.isKnownMeetingApp)
            guard meetingApps.count == 1 else {
                err("\(meetingApps.count) known meeting apps are running: pass --app <bundle id>.")
                list(apps, hal)
                return 2
            }
            target = meetingApps[0].target
        }

        let source = SystemAudioSource(target: target, hal: hal)
        let capture = AudioCapture(source: source, maxSeconds: { seconds + 1 }, keepsTime: true)
        var startError: Error?
        var started = false
        capture.begin { error in startError = error; started = true }
        spin(until: { started }, timeout: 10)
        if let startError {
            err("failed: \(startError.localizedDescription)")
            return 1
        }
        guard started else {
            err("failed: the system-audio device didn't start within 10 s")
            return 1
        }
        err("Recording \(seconds.formatted()) s of system audio — play something now…")
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))

        var samples: [Float]?
        capture.end { samples = $0 }
        spin(until: { samples != nil }, timeout: 5)
        let recorded = samples ?? []

        let peak = recorded.map(abs).max() ?? 0
        let rms = recorded.isEmpty ? 0 : (recorded.reduce(0) { $0 + $1 * $1 } / Float(recorded.count)).squareRoot()
        err("Captured \(recorded.count) samples (\(String(format: "%.2f", Double(recorded.count) / AudioCapture.sampleRate)) s @ 16 kHz), peak \(String(format: "%.4f", peak)), RMS \(String(format: "%.4f", rms))")
        do {
            try write(recorded, to: out)
            err("Wrote \(out.path)")
        } catch {
            err("Could not write \(out.path): \(error.localizedDescription)")
        }

        if source.hasHeardSound {
            err("Sound captured: the system-audio permission is granted.")
            return 0
        }
        err("Only silence. Either nothing played, or system-audio recording isn't allowed: "
            + "check System Settings › Privacy & Security › Screen & System Audio Recording.")
        return 3
    }

    private static func list(_ apps: [RecordableApp], _ hal: ProcessTapHAL) {
        let processes = hal.audioProcesses()
        let running = RecordableApps.runningApps()
        for app in apps {
            print("\(app.name) [\(app.bundleID)] pid \(app.pid)\(app.isKnownMeetingApp ? " (meeting app)" : "")")
            for process in AudioProcessMatcher.processes(of: app.bundleID, pid: app.pid, in: processes,
                                                         otherApps: running, parentPID: hal.parentPID(of:)) {
                print("    process object \(process.object): pid \(process.pid) \(process.bundleID ?? "(no bundle ID)")")
            }
        }
    }

    private static func spin(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func write(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("[system-audio-test] \(s)\n".utf8))
    }
}
