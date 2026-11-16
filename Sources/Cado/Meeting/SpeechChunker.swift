import Foundation

/// Splits a long recording (one side of a meeting) into the stretches worth
/// transcribing, by energy: frames loud enough are speech, pauses of
/// `pauseSeconds` or more end a chunk, chunks with too little speech are
/// dropped and long ones are cut at their quietest point. Pure.
///
/// Engine-agnostic on purpose: whisper.cpp's Silero VAD only exists inside
/// the whisper adapter, and the meeting path runs on whatever engine is
/// configured. Skipping silence also keeps whisper from hallucinating text
/// into it, and short chunks keep each engine job — and the queue a
/// dictation waits on — short.
enum SpeechChunker {
    /// A stretch to transcribe: sample indices, `end` exclusive.
    struct Chunk: Equatable {
        let start: Int
        let end: Int
    }

    struct Settings: Equatable {
        var sampleRate: Double = AudioCapture.sampleRate
        /// 20 ms frames.
        var frameSeconds: Double = 0.02
        /// A frame quieter than this (RMS) is never speech (~ -46 dBFS).
        var floorRMS: Float = 0.005
        /// Speech is this many times louder than the noise floor (the
        /// recording's 10th-percentile frame).
        var noiseMultiplier: Float = 3
        /// …but never needs more than this (~ -34 dBFS): in a recording
        /// that's nearly all talk the 10th percentile is speech, not noise.
        var ceilingRMS: Float = 0.02
        /// A quiet gap this long ends a chunk.
        var pauseSeconds: Double = 0.6
        /// A chunk needs this much speech, else it's a click or a cough.
        var minSpeechSeconds: Double = 0.25
        /// Longest chunk; a longer stretch is cut at its quietest frame in
        /// the last `cutWindowSeconds`.
        var maxChunkSeconds: Double = 25
        var cutWindowSeconds: Double = 5
        /// Kept around the speech, so first and last syllables aren't clipped.
        var padBeforeSeconds: Double = 0.2
        var padAfterSeconds: Double = 0.3
    }

    static func chunks(_ samples: [Float], settings s: Settings = Settings()) -> [Chunk] {
        let frame = max(1, Int(s.frameSeconds * s.sampleRate))
        guard !samples.isEmpty else { return [] }
        let rms: [Float] = stride(from: 0, to: samples.count, by: frame).map { start in
            let end = min(start + frame, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(end - start)).squareRoot()
        }
        let noise = rms.sorted()[rms.count / 10]
        let threshold = max(s.floorRMS, min(noise * s.noiseMultiplier, s.ceilingRMS))
        let frames = { (seconds: Double) in max(1, Int((seconds / s.frameSeconds).rounded())) }
        let pause = frames(s.pauseSeconds), minSpeech = frames(s.minSpeechSeconds)
        let maxLength = frames(s.maxChunkSeconds), cutWindow = min(frames(s.cutWindowSeconds), maxLength - 1)

        // Runs of speech frames, gaps shorter than a pause bridged.
        var regions: [(first: Int, last: Int, voiced: Int)] = []
        for (i, level) in rms.enumerated() where level >= threshold {
            if let last = regions.last, i - last.last <= pause {
                regions[regions.count - 1] = (last.first, i, last.voiced + 1)
            } else {
                regions.append((i, i, 1))
            }
        }

        // Frame ranges (end exclusive), long ones cut where it's quietest.
        var ranges: [(start: Int, end: Int)] = []
        for region in regions where region.voiced >= minSpeech {
            var start = region.first
            let end = region.last + 1
            while end - start > maxLength {
                let window = (start + maxLength - cutWindow)..<(start + maxLength)
                let cut = window.min { rms[$0] < rms[$1] }!
                ranges.append((start, cut))
                start = cut
            }
            ranges.append((start, end))
        }

        let before = Int(s.padBeforeSeconds * s.sampleRate), after = Int(s.padAfterSeconds * s.sampleRate)
        var chunks: [Chunk] = []
        for range in ranges {
            let start = max(range.start * frame - before, chunks.last?.end ?? 0)
            let end = min(range.end * frame + after, samples.count)
            guard end > start else { continue }
            chunks.append(Chunk(start: start, end: end))
        }
        return chunks
    }
}
