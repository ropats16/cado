import AppKit

/// Which moment in the dictation lifecycle a cue marks.
enum SoundCue { case start, stop }

/// The side-effecting sink that actually plays audio.
/// Production code uses `SynthSoundCueOutput`; tests inject a spy.
protocol SoundCueOutput {
    func emit(_ cue: SoundCue)
}

/// Plays Cado's own start/stop cues, synthesized in code (`CueSound`) so no
/// audio assets are bundled with the app. Each cue is rendered to in-memory WAV
/// and loaded into an `NSSound` once, at init, so `emit` is instant and returns
/// at once. If a cue can't be loaded or played (e.g. no audio output) the
/// failure is silently swallowed — no crash, no log spam.
final class SynthSoundCueOutput: SoundCueOutput {
    private let startSound: NSSound?
    private let stopSound: NSSound?

    init(audio: (SoundCue) -> Data = { WAV.encode(CueSound.for($0).render(), sampleRate: CueSound.sampleRate) }) {
        startSound = NSSound(data: audio(.start))
        stopSound  = NSSound(data: audio(.stop))
    }

    func emit(_ cue: SoundCue) {
        switch cue {
        case .start: startSound?.play()
        case .stop:  stopSound?.play()
        }
    }
}

/// Gates sound-cue playback on a live-read enabled flag.
///
/// `isEnabled` is called on every `play(_:)` invocation so toggling
/// `config.soundCues` at runtime is honoured immediately without
/// recreating the `SoundCues` instance.
final class SoundCues {
    private let isEnabled: () -> Bool
    private let output: SoundCueOutput

    init(isEnabled: @escaping () -> Bool,
         output: SoundCueOutput = SynthSoundCueOutput()) {
        self.isEnabled = isEnabled
        self.output    = output
    }

    /// Plays `cue` through the configured output, but only when enabled.
    func play(_ cue: SoundCue) {
        guard isEnabled() else { return }
        output.emit(cue)
    }
}
