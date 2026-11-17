import AVFoundation
import Foundation

/// `Cado --echo-test --wav <speech.wav> [--out <dir>]`
///
/// Measures how much of what the speakers play the mic picks up (speaker
/// bleed, #36), with and without Apple's voice processing (echo
/// cancellation) on the mic. Plays the WAV twice through the default output
/// with `afplay` (another process, as a meeting app would), each time
/// recording the default mic: once plain, once with
/// `AVAudioInputNode.setVoiceProcessingEnabled(true)` (other audio not
/// ducked). Writes `mic-plain.wav` and `mic-voice-processing.wav` to `--out`
/// (default: a fresh temp folder) and prints each one's level: stay quiet
/// while it runs, so all that's heard is bleed. Feed a recording to
/// `--meeting-test --me <it> --them <speech.wav>` to see what the note does
/// with it.
///
/// Diagnostic only: Cado's meetings and dictation never use voice processing.
/// Needs the microphone permission for whatever runs it (the terminal), and
/// plays sound out loud.
///
/// Exit status: 0 both recorded; 1 a recording failed; 2 bad usage.
enum EchoSelfTest {
    static func run(arguments: [String]) -> Int32 {
        guard let wav = CommandLineSupport.value("--wav", in: arguments) else {
            err("usage: Cado --echo-test --wav <speech.wav> [--out <dir>]")
            return 2
        }
        let out = URL(fileURLWithPath: CommandLineSupport.value("--out", in: arguments)
                      ?? NSTemporaryDirectory() + "cado-echo-test-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var levels: [Double] = []
            for voiceProcessing in [false, true] {
                let file = out.appendingPathComponent(voiceProcessing ? "mic-voice-processing.wav" : "mic-plain.wav")
                err("Playing \(wav) and recording the mic\(voiceProcessing ? " with voice processing" : "")…")
                let level = try record(playing: wav, voiceProcessing: voiceProcessing, to: file)
                levels.append(level)
                err(String(format: "%@: %.1f dBFS (%@)", voiceProcessing ? "Voice processing" : "Plain", level, file.path))
            }
            err(String(format: "Voice processing heard %.1f dB less of the speakers.", levels[0] - levels[1]))
            return 0
        } catch {
            err("failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Records the default mic while `afplay` plays `wav`; the recording's
    /// RMS level in dBFS (first channel).
    private static func record(playing wav: String, voiceProcessing: Bool, to url: URL) throws -> Double {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *) {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        }
        _ = engine.mainMixerNode   // voice processing runs input and output together
        let format = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let meter = Meter()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
            meter.add(buffer)
        }
        engine.prepare()
        try engine.start()
        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        Thread.sleep(forTimeInterval: 0.5)   // let voice processing settle
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav]
        try player.run()
        player.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
        return meter.dBFS
    }

    private final class Meter {
        private let lock = NSLock()
        private var sum = 0.0
        private var count = 0
        func add(_ buffer: AVAudioPCMBuffer) {
            guard let channel = buffer.floatChannelData?[0] else { return }
            var s = 0.0
            for i in 0..<Int(buffer.frameLength) { s += Double(channel[i] * channel[i]) }
            lock.withLock {
                sum += s
                count += Int(buffer.frameLength)
            }
        }
        var dBFS: Double { lock.withLock { count == 0 ? -.infinity : 10 * log10(max(sum / Double(count), 1e-12)) } }
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data("[echo-test] \(s)\n".utf8))
    }
}
