import Foundation

/// Incremental `SpeechChunker`: fed a stream's samples as they are recorded,
/// it hands back each stretch worth transcribing as soon as it is complete.
///
/// Same rules as the batch chunker (20 ms RMS frames, pauses end a chunk,
/// short bursts dropped, long stretches cut at their quietest frame, pads
/// around each chunk) except the noise floor: the batch one is the 10th
/// percentile of the whole recording, which isn't known yet. Here it is the
/// 10th percentile of the last `noiseWindowSeconds` of frames (30 s),
/// including the current frame. In the first seconds the window holds only
/// what has been heard so far, so the floor is that audio's percentile: the
/// same as the batch value for a recording that short, but with less to go on.
/// Re-clamped like the batch one via `Settings.threshold(noise:)`.
///
/// A chunk is emitted once a pause has followed it, or once a stretch passes
/// `maxChunkSeconds` and is cut (the cut piece waits only for its end pad).
/// Memory is bounded: the noise window, the energies of the open region
/// (at most about `maxChunkSeconds` + a pause) and a couple of pending
/// ranges. Samples are never kept. Pure, value semantics.
struct StreamingSpeechChunker {
    private let settings: SpeechChunker.Settings
    private let frame: Int
    private let pauseFrames: Int
    private let minSpeechFrames: Int
    private let maxLengthFrames: Int
    private let cutWindowFrames: Int
    private let before: Int
    private let after: Int
    private let noiseFrames: Int

    private(set) var consumed = 0
    private var finished = false

    // The frame being filled.
    private var framesProcessed = 0
    private var partialSum: Float = 0
    private var partialCount = 0

    // Noise window: arrival-order ring plus the same values sorted.
    private var ring: [Float] = []
    private var ringHead = 0
    private var sortedWindow: [Float] = []

    // The open region (speech, with sub-pause gaps bridged); energies run
    // from `regionStart` to the latest frame.
    private var regionOpen = false
    private var regionStart = 0
    private var regionLast = 0
    private var regionVoiced = 0
    private var energies: [Float] = []

    /// Decided frame ranges (end exclusive) waiting for their end pad.
    private var pending: [(start: Int, end: Int)] = []
    private var lastEnd = 0

    init(settings: SpeechChunker.Settings = SpeechChunker.Settings()) {
        self.settings = settings
        frame = max(1, Int(settings.frameSeconds * settings.sampleRate))
        let frames = { (seconds: Double) in max(1, Int((seconds / settings.frameSeconds).rounded())) }
        pauseFrames = frames(settings.pauseSeconds)
        minSpeechFrames = frames(settings.minSpeechSeconds)
        maxLengthFrames = frames(settings.maxChunkSeconds)
        cutWindowFrames = min(frames(settings.cutWindowSeconds), maxLengthFrames - 1)
        before = Int(settings.padBeforeSeconds * settings.sampleRate)
        after = Int(settings.padAfterSeconds * settings.sampleRate)
        noiseFrames = frames(settings.noiseWindowSeconds)
    }

    /// Number of stored values (noise window, open region, pending ranges):
    /// bounded regardless of how much audio went through.
    var storedStateCount: Int { ring.count + sortedWindow.count + energies.count + pending.count }

    /// No future chunk will start before this sample index: the caller may
    /// forget audio before it. Monotonic, `<= consumed`.
    var settledThrough: Int {
        if finished { return consumed }
        var earliest = framesProcessed * frame - before
        if let first = pending.first { earliest = min(earliest, first.start * frame - before) }
        if regionOpen { earliest = min(earliest, regionStart * frame - before) }
        return min(consumed, max(earliest, lastEnd, 0))
    }

    /// The next samples of the stream (contiguous with everything appended
    /// before; any batch size). Returns the chunks this audio completed:
    /// absolute sample indices, in order, never overlapping, `end <= consumed`.
    mutating func append(_ samples: [Float]) -> [SpeechChunker.Chunk] {
        guard !finished, !samples.isEmpty else { return [] }
        samples.withUnsafeBufferPointer { buffer in
            var i = 0
            while i < buffer.count {
                let take = min(frame - partialCount, buffer.count - i)
                var sum = partialSum
                for j in i..<(i + take) { sum += buffer[j] * buffer[j] }
                partialSum = sum
                partialCount += take
                i += take
                if partialCount == frame { completeFrame() }
            }
        }
        consumed += samples.count
        return drain(final: false)
    }

    /// No more audio is coming: returns the still-open chunk, if it has
    /// enough speech. After this the chunker is finished.
    mutating func finish() -> [SpeechChunker.Chunk] {
        guard !finished else { return [] }
        if partialCount > 0 { completeFrame() }
        if regionOpen { closeRegion() }
        finished = true
        return drain(final: true)
    }

    // MARK: - Frames

    private mutating func completeFrame() {
        let level = (partialSum / Float(partialCount)).squareRoot()
        partialSum = 0
        partialCount = 0
        let index = framesProcessed
        framesProcessed += 1

        let threshold = settings.threshold(noise: noiseFloor(adding: level))
        if level >= threshold {
            if regionOpen {
                regionVoiced += 1
                regionLast = index
                energies.append(level)
            } else {
                regionOpen = true
                regionStart = index
                regionLast = index
                regionVoiced = 1
                energies = [level]
            }
            while regionLast + 1 - regionStart > maxLengthFrames { cutRegion() }
        } else if regionOpen {
            energies.append(level)
            if index - regionLast > pauseFrames { closeRegion() }
        }
    }

    /// 10th percentile of the recent window, which now includes `level`.
    private mutating func noiseFloor(adding level: Float) -> Float {
        if ring.count == noiseFrames {
            let old = ring[ringHead]
            ring[ringHead] = level
            ringHead = (ringHead + 1) % noiseFrames
            sortedWindow.remove(at: lowerBound(old))
        } else {
            ring.append(level)
        }
        sortedWindow.insert(level, at: lowerBound(level))
        return sortedWindow[sortedWindow.count / 10]
    }

    private func lowerBound(_ value: Float) -> Int {
        var low = 0, high = sortedWindow.count
        while low < high {
            let mid = (low + high) / 2
            if sortedWindow[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The open region is longer than the maximum: cut at its quietest frame
    /// in the last `cutWindowFrames` before the maximum; the rest carries on.
    private mutating func cutRegion() {
        let from = maxLengthFrames - cutWindowFrames
        var cut = from
        for k in from..<maxLengthFrames where energies[k] < energies[cut] { cut = k }
        pending.append((regionStart, regionStart + cut))
        energies.removeFirst(cut)
        regionStart += cut
    }

    private mutating func closeRegion() {
        if regionVoiced >= minSpeechFrames { pending.append((regionStart, regionLast + 1)) }
        regionOpen = false
        energies.removeAll(keepingCapacity: true)
    }

    /// Ranges whose end pad has arrived (or all of them when finishing,
    /// clipped to the audio received), as padded chunks.
    private mutating func drain(final: Bool) -> [SpeechChunker.Chunk] {
        var chunks: [SpeechChunker.Chunk] = []
        while let range = pending.first {
            let paddedEnd = range.end * frame + after
            if !final && consumed < paddedEnd { break }
            pending.removeFirst()
            let start = max(range.start * frame - before, lastEnd)
            let end = min(paddedEnd, consumed)
            guard end > start else { continue }
            chunks.append(SpeechChunker.Chunk(start: start, end: end))
            lastEnd = end
        }
        return chunks
    }
}
