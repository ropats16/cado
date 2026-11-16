import XCTest
@testable import Cado

/// Whether launch shows onboarding (#22): once, on a Mac that isn't set up;
/// an upgrader that already is never sees it.
final class OnboardingLaunchTests: XCTestCase {

    private func inputs(accessibility: AccessibilityPermission = .granted,
                        microphone: MicrophonePermission = .authorized,
                        engine status: TranscriptionStatus = .notLoaded) -> ReadinessInputs {
        ReadinessInputs(accessibility: accessibility, microphone: microphone,
                        engine: EngineReadiness(status: status, modelPath: "/models/x", download: nil),
                        hotkeyTap: .notInstalled)
    }

    private func decide(done: Bool = false, _ inputs: ReadinessInputs, modelInstalled: Bool = true)
        -> OnboardingLaunch.Decision {
        OnboardingLaunch.decide(done: done, inputs: inputs, modelInstalled: modelInstalled)
    }

    func testDoneShowsNothing() {
        XCTAssertEqual(decide(done: true, inputs(microphone: .notDetermined), modelInstalled: false), .nothing)
        XCTAssertEqual(decide(done: true, inputs()), .nothing)
    }

    func testAnUpgraderAlreadySetUpIsMarkedDone() {
        XCTAssertEqual(decide(inputs()), .markDone)
    }

    func testAnythingMissingShowsIt() {
        XCTAssertEqual(decide(inputs(accessibility: .denied)), .show)
        XCTAssertEqual(decide(inputs(microphone: .notDetermined)), .show)
        XCTAssertEqual(decide(inputs(microphone: .denied)), .show)
        XCTAssertEqual(decide(inputs(), modelInstalled: false), .show)
    }
}
