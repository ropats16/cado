import Foundation

/// The seam between `TranscriptionEngine` and a concrete speech engine. Only
/// the engine calls it: it guarantees calls are serialized and off the main
/// thread, so adapters need no locking of their own.
protocol TranscriptionAdapter: AnyObject {
    /// Transcribe 16 kHz mono Float32 PCM into timestamped segments. Blocks
    /// until done.
    func transcribe(samples: [Float]) throws -> [Transcript.Segment]
    /// One job decoded in `language` (an ISO code or "auto") instead of the
    /// language the model was loaded with; nil = that one, exactly as
    /// `transcribe(samples:)`. The transcript says which language was
    /// decoded in when the engine tells (`Transcript.language`). Only
    /// engines that take the language per job (`ModelSpec.takesLanguagePerJob`)
    /// honour `language`; the default ignores it.
    func transcribe(samples: [Float], language: String?) throws -> Transcript
}

extension TranscriptionAdapter {
    func transcribe(samples: [Float], language: String?) throws -> Transcript {
        Transcript(segments: try transcribe(samples: samples))
    }
}
