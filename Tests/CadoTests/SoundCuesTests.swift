import XCTest
@testable import Cado

/// Tests for the SoundCues gating layer (Phase 4, Task 1).
/// Uses a spy output to verify the decision logic without touching AppKit audio.
final class SoundCuesTests: XCTestCase {

    // MARK: - Helpers

    /// Spy that records every emitted cue.
    private final class SpyOutput: SoundCueOutput {
        var emitted: [SoundCue] = []
        func emit(_ cue: SoundCue) { emitted.append(cue) }
    }

    // MARK: - Disabled → no output

    func testDisabledEmitsNothingOnStart() {
        let spy = SpyOutput()
        let sut = SoundCues(isEnabled: { false }, output: spy)
        sut.play(.start)
        XCTAssertTrue(spy.emitted.isEmpty, "Disabled SoundCues must not emit .start")
    }

    func testDisabledEmitsNothingOnStop() {
        let spy = SpyOutput()
        let sut = SoundCues(isEnabled: { false }, output: spy)
        sut.play(.stop)
        XCTAssertTrue(spy.emitted.isEmpty, "Disabled SoundCues must not emit .stop")
    }

    // MARK: - Enabled → correct cue forwarded

    func testEnabledEmitsStartCue() {
        let spy = SpyOutput()
        let sut = SoundCues(isEnabled: { true }, output: spy)
        sut.play(.start)
        XCTAssertEqual(spy.emitted, [.start])
    }

    func testEnabledEmitsStopCue() {
        let spy = SpyOutput()
        let sut = SoundCues(isEnabled: { true }, output: spy)
        sut.play(.stop)
        XCTAssertEqual(spy.emitted, [.stop])
    }

    // MARK: - Dynamic gating (flag read at call time, not captured)

    func testFlagFlipFromFalseToTrueIsRespectedImmediately() {
        let spy = SpyOutput()
        var enabled = false
        let sut = SoundCues(isEnabled: { enabled }, output: spy)

        sut.play(.start)                // flag is false — should be suppressed
        XCTAssertTrue(spy.emitted.isEmpty, "Must suppress before flag flip")

        enabled = true
        sut.play(.stop)                 // flag is now true — should pass through
        XCTAssertEqual(spy.emitted, [.stop], "Must emit after flag flip")
    }

    // MARK: - Synthesized output

    /// Audio that can't be loaded is swallowed: emitting is a silent no-op.
    /// (Valid cues aren't emitted here — tests must not make noise.)
    func testUnloadableCueAudioIsSilentlySkipped() {
        let output = SynthSoundCueOutput(audio: { _ in Data("not audio".utf8) })
        output.emit(.start)
        output.emit(.stop)
    }

    func testCueAudioIsRenderedOnceUpFront() {
        var rendered: [SoundCue] = []
        let output = SynthSoundCueOutput(audio: { rendered.append($0); return Data() })
        XCTAssertEqual(rendered.sorted { "\($0)" < "\($1)" }, [.start, .stop])
        output.emit(.start)
        output.emit(.start)
        XCTAssertEqual(rendered.count, 2, "emit must not re-render")
    }
}
