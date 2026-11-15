import XCTest
import AppKit
import SwiftUI
import ServiceManagement
@testable import Cado

/// Dev tool, not a test: renders the Settings window offscreen to PNGs (2x,
/// light and dark) for design review and PR screenshots. Skipped unless
/// `CADO_RENDER_SETTINGS=<dir>` is set:
///
///     CADO_RENDER_SETTINGS=/tmp/shots swift test --filter SettingsRenderHarness
///
/// Every state is fake: config and models live in a temp folder, the login
/// item, downloader and speech assets are stubs, so nothing real is touched.
@MainActor
final class SettingsRenderHarness: XCTestCase {

    private final class StubLoginItem: LoginItemService {
        var rawStatus: SMAppService.Status
        let fails: Bool
        init(enabled: Bool, fails: Bool = false) { rawStatus = enabled ? .enabled : .notRegistered; self.fails = fails }
        func register() throws { if fails { throw Denied() } }
        func unregister() throws { if fails { throw Denied() } }
    }
    private struct Denied: LocalizedError { var errorDescription: String? { "Operation not permitted." } }
    private struct NoDownloads: ModelDownloading {
        func download(_ download: ModelDownload, progress: @escaping @Sendable (Int64) -> Void) async throws {}
    }
    private struct StubSpeechAssets: SpeechModelAssets {
        let state: AppleSpeechAssetState
        func state(language: String) async -> AppleSpeechAssetState { state }
        func install(language: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    }

    private var tempDir: URL!
    private var previousOverride: String?

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["CADO_RENDER_SETTINGS"], !dir.isEmpty else {
            throw XCTSkip("set CADO_RENDER_SETTINGS=<dir> to render Settings screenshots")
        }
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cado-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        previousOverride = ProcessInfo.processInfo.environment[Paths.overrideVariable]
        setenv(Paths.overrideVariable, tempDir.path, 1)   // belt and braces: nothing reaches the real folder
    }

    override func tearDown() {
        if let tempDir {
            // Put the override back, so later tests don't inherit a deleted folder.
            if let previousOverride { setenv(Paths.overrideVariable, previousOverride, 1) }
            else { unsetenv(Paths.overrideVariable) }
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testRenderSettings() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CADO_RENDER_SETTINGS"]!)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prefix = ProcessInfo.processInfo.environment["CADO_RENDER_PREFIX"] ?? "settings"

        for (name, make) in [("", overview), ("-issues", issues), ("-apple-speech", appleSpeech)] as [(String, () async -> SettingsViewModel)] {
            for dark in [false, true] {
                let vm = await make()
                let file = out.appendingPathComponent("\(prefix)\(name)-\(dark ? "dark" : "light").png")
                defer { vm.recorder.cancelCapture(vm: vm) }
                try await render(vm, dark: dark, to: file)
            }
        }
    }

    // MARK: - States

    private let environment = EngineEnvironment.mac(26)

    private func makeVM(engine: EngineKind, status: TranscriptionStatus, login: StubLoginItem,
                        speech: AppleSpeechAssetState = .installed, installAutomatic: Bool = true) -> SettingsViewModel {
        let store = ConfigStore(url: tempDir.appendingPathComponent("config-\(UUID().uuidString).json"))
        store.update {
            $0.engine = engine.rawValue
            $0.language = "en"
            $0.soundCues = true
        }
        let modelsDir = tempDir.appendingPathComponent("models", isDirectory: true)
        let descriptor = EngineRegistry.shared.descriptor(for: engine)!
        let context = ModelContext(language: "en", hardware: environment.hardware, modelsDir: modelsDir,
                                   presentFilenames: [], customPath: "")
        let auto = descriptor.resolve(.automatic, in: context)
        if installAutomatic, engine != .appleSpeech {
            try? FileManager.default.createDirectory(atPath: auto.path, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: (auto.path as NSString)
                .appendingPathComponent(ModelVerifier.folderManifestName), contents: Data())
        }
        return SettingsViewModel(
            configStore: store,
            loginItem: LoginItem(service: login),
            availableMics: { [AudioInputDevice(uid: "mbp", name: "MacBook Pro Microphone"),
                              AudioInputDevice(uid: "airpods", name: "AirPods Pro")] },
            presentModelFilenames: { [] },
            onNeedsMenuRefresh: {}, pauseHotkeys: {}, reloadHotkeys: {},
            hardware: environment.hardware,
            currentModel: { auto },
            modelStatus: status,
            onModelSettingsChange: {},
            environment: environment,
            speechAssets: StubSpeechAssets(state: speech),
            modelDownloader: NoDownloads(),
            modelsDir: modelsDir)
    }

    /// Everything fine: the model is ready, the rest downloadable.
    private func overview() async -> SettingsViewModel {
        makeVM(engine: .whisperKit, status: .ready, login: StubLoginItem(enabled: true))
    }

    /// Every warning and error at once, plus a download and a hotkey capture under way.
    private func issues() async -> SettingsViewModel {
        let vm = makeVM(engine: .whisperKit, status: .missing, login: StubLoginItem(enabled: false, fails: true),
                        installAutomatic: false)
        vm.setLaunchAtLogin(true)
        let rows = vm.inAppDownloadableModels
        if rows.count > 1 {
            vm.modelDownloads[rows[0].key] = .downloading(fraction: 0.42)
            vm.modelDownloads[rows[1].key] = .failed("Download failed: The network is offline.")
        }
        vm.commitHotkey(vm.holdBinding, for: .toggle)   // same chord twice → warning
        vm.recorder.startCapture(for: .hold, vm: vm)
        return vm
    }

    /// Apple Speech: the OS-managed model, not yet downloaded, after a failed try.
    private func appleSpeech() async -> SettingsViewModel {
        let vm = makeVM(engine: .appleSpeech, status: .missing, login: StubLoginItem(enabled: true),
                        speech: .notInstalled)
        await vm.refreshSpeechAssets()
        vm.speechAssetError = "Download failed: The network is offline."
        return vm
    }

    // MARK: - Rendering

    /// Hosts the view like `SettingsWindowController` does, grows the window to
    /// fit the whole form (no scrolling), and writes the frame at 2x.
    private func render(_ vm: SettingsViewModel, dark: Bool, to file: URL) async throws {
        _ = NSApplication.shared
        let window = SettingsWindowController.makeWindow(viewModel: vm)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        try await settle()

        // Fit the window to the form's full content height.
        if let scroll = firstScrollView(in: window.contentView!), let doc = scroll.documentView {
            let extra = doc.frame.height - scroll.contentView.bounds.height
            if extra > 0 {
                var frame = window.frame
                frame.size.height += extra
                window.setFrame(frame, display: false)
                try await settle()
            }
        }

        let view = window.contentView!.superview ?? window.contentView!   // the frame view: includes the titlebar
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

    private func settle() async throws {
        // Main-actor sleeps let SwiftUI lay out, run `.task`s and redraw.
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 50_000_000) }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = firstScrollView(in: sub) { return found } }
        return nil
    }
}
