import AVFoundation
import Foundation

// The live adapters behind `MeetingSession`'s ports. Thin on purpose: every
// rule lives in the session.

extension AudioCapture: MeetingStream {}

/// The live streams: the configured mic and the app's audio through a
/// process tap, each in its own capture that stops its source as soon as the
/// meeting ends (no warm mic or lingering capture indicator).
final class LiveMeetingRecorder: MeetingRecorder {
    private let microphoneUID: () -> String?

    init(microphoneUID: @escaping () -> String?) { self.microphoneUID = microphoneUID }

    func streams(for app: MeetingApp, maxSeconds: Double) -> (me: MeetingStream, them: MeetingStream) {
        let me = AudioCapture(source: MicSource(configuredUID: microphoneUID), idleSeconds: 0,
                              maxSeconds: { maxSeconds })
        let them = AudioCapture(source: SystemAudioSource(target: app.target), idleSeconds: 0,
                                maxSeconds: { maxSeconds })
        return (me, them)
    }
}

/// The shared transcription engine; hands the transcript back on main.
final class EngineMeetingAdapter: MeetingEngine {
    private let engine: TranscriptionEngine

    init(_ engine: TranscriptionEngine) { self.engine = engine }

    func prewarm() { engine.prewarm() }
    func endPrewarm() { engine.endPrewarm() }

    func transcribe(_ samples: [Float], completion: @escaping (Result<Transcript, Error>) -> Void) {
        engine.transcribe(samples) { result in
            DispatchQueue.main.async { completion(result) }
        }
    }
}

extension NotesLibrary: MeetingNoteStore {
    func save(_ draft: NoteDraft) throws -> URL { try create(draft).summary.url }
}

/// Keeps a meeting's audio as 16 kHz mono 16-bit WAVs (`Me.wav`,
/// `Them.wav`), plus `Note.md` if given, in `<root>/<name>/` — by default
/// Cado's support folder's `Meeting Audio`, not the notes folder (no
/// 100 MB files in someone's vault).
final class FolderMeetingArchive: MeetingArchive {
    private let root: URL

    init(root: URL = Paths.appSupportDir.appendingPathComponent("Meeting Audio", isDirectory: true)) {
        self.root = root
    }

    func keep(_ audio: [MeetingAudio], note: String?, name: String) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for track in audio {
            try Self.writeWAV(track.samples, to: folder.appendingPathComponent("\(track.speaker.rawValue).wav"))
        }
        if let note {
            try Data(note.utf8).write(to: folder.appendingPathComponent("Note.md"))
        }
        return folder
    }

    static func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioCapture.sampleRate,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let chunk = 1 << 16
        var offset = 0
        while offset < samples.count {
            let count = min(chunk, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}

/// Notification banners.
final class NotifierMeetingFeedback: MeetingFeedback {
    func notify(title: String, body: String) { Notifier.notify(title: title, body: body) }
}
