import Foundation

/// One soft, plucked note of a cue: a sine with a touch of 2nd and 3rd
/// harmonic, a short rounded attack, an exponential decay and a "bloop" — a
/// quick upward pitch settle, like a water drop.
struct CueNote {
    var frequency: Double   // Hz
    var onset: Double       // seconds from the start of the cue
    var length: Double      // seconds, ending in a fade to silence
}

/// A cue described as notes, rendered in code so the app ships no audio files.
struct CueSound {
    static let sampleRate = 44_100

    var notes: [CueNote]
    /// Loudest sample, as a fraction of full scale.
    var peak: Double
    /// Time constant of each note's exponential decay, in seconds.
    var decay: Double = 0.028
    /// Level of the 2nd harmonic (the 3rd gets a third of it); 0 is a pure sine.
    var warmth: Double = 0.22

    // Both cues: ~165 ms, mostly decayed by ~110 ms; peaks -12 / -14 dBFS.

    /// Ready, listening: a rising fourth, E5 → A5.
    static let start = CueSound(notes: [
        CueNote(frequency: 659.26, onset: 0, length: 0.090),
        CueNote(frequency: 880.00, onset: 0.055, length: 0.110),
    ], peak: 0.25)

    /// Done: the same figure falling, A5 → E5, a touch softer.
    static let stop = CueSound(notes: [
        CueNote(frequency: 880.00, onset: 0, length: 0.090),
        CueNote(frequency: 659.26, onset: 0.055, length: 0.110),
    ], peak: 0.20)

    static func `for`(_ cue: SoundCue) -> CueSound {
        switch cue {
        case .start: return start
        case .stop: return stop
        }
    }

    /// Mono samples in -1...1 at `sampleRate`, starting and ending at silence.
    func render() -> [Float] {
        let rate = Double(Self.sampleRate)
        let total = notes.map { $0.onset + $0.length }.max() ?? 0
        var out = [Double](repeating: 0, count: Int((total * rate).rounded()))
        let attack = 0.005, fade = 0.015
        let glide = 0.05, glideTime = 0.010   // starts 5% flat, settles in ~10 ms

        for note in notes {
            let first = Int((note.onset * rate).rounded())
            let count = min(Int((note.length * rate).rounded()), out.count - first)
            var phase = 0.0
            for i in 0..<count {
                let t = Double(i) / rate
                let attackGain = t < attack ? 0.5 - 0.5 * cos(.pi * t / attack) : 1
                let left = note.length - t
                let fadeGain = left < fade ? 0.5 - 0.5 * cos(.pi * max(left, 0) / fade) : 1
                let decayGain = exp(-t / decay)
                // Upper partials die away faster, so the tail is a round sine.
                let tone = sin(phase)
                    + warmth * decayGain * sin(2 * phase)
                    + warmth / 3 * decayGain * decayGain * sin(3 * phase)
                out[first + i] += attackGain * fadeGain * decayGain * tone
                phase += 2 * .pi * note.frequency * (1 - glide * exp(-t / glideTime)) / rate
            }
        }

        let loudest = out.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak / loudest : 0
        return out.map { Float($0 * scale) }
    }
}

/// A minimal RIFF/WAVE container: mono, 16-bit PCM, little-endian.
enum WAV {
    /// Wraps `samples` (clamped to -1...1) so `NSSound(data:)` can play them.
    static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func put(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        let bytes = UInt32(2 * samples.count)
        put("RIFF"); put32(36 + bytes); put("WAVE")
        put("fmt "); put32(16)
        put16(1)                               // PCM
        put16(1)                               // mono
        put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * 2))          // byte rate
        put16(2)                               // block align
        put16(16)                              // bits per sample
        put("data"); put32(bytes)
        for s in samples {
            put16(UInt16(bitPattern: Int16((max(-1, min(1, s)) * 32_767).rounded())))
        }
        return data
    }
}
