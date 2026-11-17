import XCTest
import AppKit
import Combine
@testable import Cado

/// Dev tool, not a test: renders the onboarding window offscreen to PNGs
/// (2x, light and dark), a file per step and state, for design review and
/// PR screenshots. Skipped unless `CADO_RENDER_ONBOARDING=<dir>` is set:
///
///     CADO_RENDER_ONBOARDING=/tmp/shots swift test --filter OnboardingRenderHarness
///
/// Every state is fake (readiness inputs, models, downloads): nothing real
/// is asked or touched.
@MainActor
final class OnboardingRenderHarness: XCTestCase {

    private final class StubDownloads: ModelDownloadControl {
        @Published var modelDownloads: [ModelDownloadKey: ModelDownloadState] = [:]
        var modelDownloadsPublisher: AnyPublisher<[ModelDownloadKey: ModelDownloadState], Never> {
            $modelDownloads.eraseToAnyPublisher()
        }
        var partial: Set<ModelDownloadKey> = []
        func canDownloadModel(_ key: ModelDownloadKey) -> Bool { true }
        func downloadModel(_ key: ModelDownloadKey) -> Task<Void, Never>? { nil }
        func cancelModelDownload(_ key: ModelDownloadKey) {}
        func hasPartialDownload(_ key: ModelDownloadKey) -> Bool { partial.contains(key) }
    }

    nonisolated private static let turbo = OnboardingModelOption(
        key: ModelDownloadKey(engine: .parakeet, id: "parakeet-tdt-0.6b-v3"), title: "Turbo (English/EU)",
        detail: "parakeet-tdt-0.6b-v3 (483 MB)", isRecommended: true, isInstalled: false, fetch: .inApp)
    nonisolated private static let small = OnboardingModelOption(
        key: ModelDownloadKey(engine: .whisper, id: "small.en-q5_1"), title: "Whisper small",
        detail: "English only · 181 MB", isRecommended: false, isInstalled: false, fetch: .inApp)
    nonisolated private static let base = OnboardingModelOption(
        key: ModelDownloadKey(engine: .whisper, id: "base.en-q5_1"), title: "Whisper base",
        detail: "English only · 57 MB", isRecommended: false, isInstalled: true, fetch: .inApp)

    private struct Scene {
        var name: String
        var step: OnboardingStepID
        var accessibility: AccessibilityPermission = .granted
        var microphone: MicrophonePermission = .authorized
        var engine: TranscriptionStatus = .missing
        var firstLoad = false
        var tap: HotkeyTapHealth = .installed
        var options: [OnboardingModelOption] = [turbo, small, base]
        var downloads: [ModelDownloadKey: ModelDownloadState] = [:]
        var partial: Set<ModelDownloadKey> = []
        var notifications: NotificationPermission = .authorized
    }

    private let scenes: [Scene] = [
        Scene(name: "1-welcome", step: .welcome, accessibility: .denied, microphone: .notDetermined),
        Scene(name: "2-microphone", step: .microphone, accessibility: .denied, microphone: .notDetermined),
        Scene(name: "2-microphone-denied", step: .microphone, accessibility: .denied, microphone: .denied),
        Scene(name: "2-microphone-done", step: .microphone, accessibility: .denied),
        Scene(name: "3-accessibility", step: .accessibility, accessibility: .denied),
        Scene(name: "3-accessibility-stale", step: .accessibility, tap: .failed),
        Scene(name: "4-model", step: .model),
        Scene(name: "4-model-downloading", step: .model, downloads: [turbo.key: .downloading(fraction: 0.42)]),
        Scene(name: "4-model-failed", step: .model,
              downloads: [turbo.key: .failed("Download failed: The Internet connection appears to be offline.")],
              partial: [turbo.key]),
        Scene(name: "4-model-preparing", step: .model, engine: .loading, firstLoad: true),
        Scene(name: "5-notifications", step: .notifications, engine: .ready, notifications: .notDetermined),
        Scene(name: "5-notifications-off", step: .notifications, engine: .ready, notifications: .denied),
        Scene(name: "6-ready", step: .ready, engine: .ready),
        Scene(name: "6-almost-there", step: .ready, accessibility: .denied),
        Scene(name: "6-almost-there-all", step: .ready, accessibility: .denied, microphone: .denied),
    ]

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["CADO_RENDER_ONBOARDING"], !dir.isEmpty else {
            throw XCTSkip("set CADO_RENDER_ONBOARDING=<dir> to render onboarding screenshots")
        }
    }

    func testRenderOnboarding() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CADO_RENDER_ONBOARDING"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for scene in scenes {
            for dark in [false, true] {
                let file = out.appendingPathComponent("onboarding-\(scene.name)-\(dark ? "dark" : "light").png")
                try await render(makeVM(scene), dark: dark, to: file)
            }
        }
    }

    private func makeVM(_ scene: Scene) -> OnboardingViewModel {
        let downloads = StubDownloads()
        downloads.modelDownloads = scene.downloads
        downloads.partial = scene.partial
        let inputs = ReadinessInputs(
            accessibility: scene.accessibility, microphone: scene.microphone,
            engine: EngineReadiness(status: scene.engine, modelPath: "/models/x", download: nil,
                                    isFirstLoad: scene.firstLoad),
            hotkeyTap: scene.tap)
        let vm = OnboardingViewModel(config: { .defaults }, inputs: inputs, downloads: downloads,
                                     options: { scene.options }, isFirstShow: true, perform: { _ in },
                                     onFinish: {}, notifications: FakeNotificationPermission(scene.notifications))
        while vm.current < scene.step { vm.forward() }
        return vm
    }

    // MARK: - Rendering

    /// Hosts the view like `OnboardingWindowController` does and writes the
    /// frame (titlebar included) at 2x.
    private func render(_ vm: OnboardingViewModel, dark: Bool, to file: URL) async throws {
        _ = NSApplication.shared
        let window = OnboardingWindowController.makeWindow(viewModel: vm)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        for _ in 0..<6 { try await Task.sleep(nanoseconds: 50_000_000) }   // let SwiftUI lay out

        let view = window.contentView!.superview ?? window.contentView!
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        window.close()
    }
}
