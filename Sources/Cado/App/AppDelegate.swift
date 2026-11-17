import AppKit

/// Menu-bar-only agent: wires the readiness monitor, status menu, transcription
/// engine, hotkeys and dictation session together. Rules live in those
/// modules (`ReadinessMonitor`, `DictationSession`, …); this only connects them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let configStore = ConfigStore()
    private let permissions = Permissions()
    private let loginItem = LoginItem()
    /// Opt-in anonymous launch ping (#26); inert unless the user turned it on.
    private let launchPing = LaunchPing.live()

    /// The engine and model come from the config (the configured engine if it
    /// can run here, else whisper; an explicit pick, else auto-picked for this
    /// Mac); Settings changes are applied live by `applyModelSettings()`.
    private lazy var engine: TranscriptionEngine = .registered(
        model: resolvedModel(),
        options: EngineOptions(threads: configStore.config.threads),
        idleUnloadAfter: idleUnloadAfter()
    )
    /// Reloads Apple Speech once its missing model is installed outside
    /// Settings (the OS, another app); checked by `appleSpeechTimer`, on menu
    /// open and on a dictation press.
    private lazy var appleSpeechWatch = AppleSpeechModelWatch(
        missingModel: { [engine] in
            engine.status == .missing && engine.model.engine == .appleSpeech ? engine.model : nil
        },
        reload: { [weak self] in self?.applyModelSettings() }
    )
    private var appleSpeechTimer: Timer?
    /// Apple Speech's model state per language, for Automatic: asked in the
    /// background, read on main (`engineFacts`).
    private let speechPresence = SpeechModelPresence()
    /// Engines whose model failed to load under Automatic: it skips them until
    /// a Settings change (which retries).
    private var failedAutomaticEngines: Set<EngineKind> = []
    /// What `resolvedModel()` last handed the engine, to know which engine a
    /// `.failed` was about.
    private var requestedModel: ModelSpec?
    /// The last engine-fallback note logged, so a re-resolve doesn't repeat it.
    private var loggedFallback: String?
    /// Mic capture. The mic and max duration are read live, so a Settings change
    /// applies to the next recording.
    private lazy var capture = AudioCapture(
        source: MicSource(configuredUID: { [configStore] in configStore.config.microphoneUID }),
        keepWarm: configStore.config.keepMicWarm,
        maxSeconds: { [configStore] in configStore.config.maxRecordingSeconds }
    )
    private lazy var monitor = ReadinessMonitor(probe: permissions, clock: SystemClock(),
                                                engine: EngineReadiness(engine, history: loadHistory))
    /// Which models have loaded on this OS build, so a Core ML model's first
    /// load says it's being prepared rather than just "Loading".
    private let loadHistory: ModelLoadRecording = ModelLoadHistory.shared
    /// Built at launch, not on the first press, so the first dictation
    /// doesn't pay for the cues, delivery and session setup.
    private var dictation: DictationSession?
    /// The last few dictations, for the menu's copy-again (#28); kept only
    /// while the user's switch is on (read live).
    private lazy var recents = RecentDictationsStore(
        file: Paths.recentDictationsFile,
        isEnabled: { [configStore] in configStore.config.dictationHistory },
        limit: RecentDictations.limit
    )
    /// What the app is doing, for the overlay (#19); the session reports into it.
    private let activity = AppActivityFeed()
    /// The notes library (#29, #30), one for the Library window and meeting
    /// notes. Its folder is resolved from the config on every call, on main
    /// (library reads also run off main).
    private lazy var notesLibrary = NotesLibrary(folder: { [configStore] in
        let resolve = { NotesFolder.resolve(configStore.config) }
        return Thread.isMainThread ? resolve() : DispatchQueue.main.sync(execute: resolve)
    })
    /// Meeting recording from the menu (#30): mic + one app's audio → a note.
    private lazy var meetings = MeetingController(
        engine: engine, activity: activity,
        microphoneUID: { [configStore] in configStore.config.microphoneUID },
        notes: notesLibrary,
        systemAudio: { [permissions] in permissions.systemAudio },
        keepAudio: { [configStore] in configStore.config.keepMeetingAudio })
    private let termination = TerminationGate()
    /// Set once the first `.ready` asked the meetings to recover leftovers.
    private var askedMeetingRecovery = false
    /// The mascot, watching `activity`. Attached at launch; builds its panel
    /// on first show (at launch with "always visible" on).
    private var overlay: MascotOverlay?
    private var menu: StatusMenu!
    private var hotkeys: HotkeyManager?
    private var settingsWindowController: SettingsWindowController?
    /// One for Settings and onboarding (made on first need by either), so a
    /// download started in one window shows in the other.
    private var settingsViewModel: SettingsViewModel?
    private var aboutWindowController: AboutWindowController?
    /// Sparkle auto-update (#24); made and started at launch (it stays off
    /// outside a release .app: `UpdaterAvailability`).
    private var updater: SparkleUpdater?
    private var libraryWindowController: LibraryWindowController?
    /// The Library's state, made on first need and kept (it also follows
    /// the meeting under way for its in-progress row).
    private var libraryViewModel: LibraryViewModel?
    /// The newest meeting note in the folder, for "Open Last Meeting Note";
    /// re-read off main at launch, on menu open and after each meeting.
    private var lastMeetingNote: NoteSummary?
    /// Clicks on our notifications (the saved-meeting one opens its note).
    private let notificationClicks = NotificationClicks()
    private var onboardingWindowController: OnboardingWindowController?
    private var onboardingModel: OnboardingViewModel?
    /// Launch opened onboarding instead of firing the system prompts; what's
    /// still needed fires when it closes (once).
    private var launchPromptsDeferred = false

    private var isMicWarm = false
    /// Logs each config problem once, when it first appears.
    private var configIssueReporter = ConfigIssueReporter()

    // MARK: - Lifecycle

    /// Before launch finishes, so a click that launched the app is delivered.
    func applicationWillFinishLaunching(_ notification: Notification) {
        notificationClicks.onRoute = { [weak self] route in self?.open(route) }
        Notifier.handleClicks(with: notificationClicks)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        MainMenu.install()   // ⌘C/⌘V/⌘W/⌘Q… in Cado's windows
        Paths.ensureDirectories()
        DispatchQueue.global(qos: .utility).async { FolderModelDownloader.removeStalePartFolders(in: Paths.modelsDir) }

        reportConfigIssues()
        // Off (also by a hand-edited config) = nothing kept.
        if !configStore.config.dictationHistory { recents.clear() }
        setupMenu()
        refreshLastMeetingNote()
        startUpdater()
        wireMonitor()
        startEngine()
        overlay = makeOverlay()
        dictation = makeDictationSession()
        // Start before deciding on onboarding: the first poll reads the real
        // permissions (until then the monitor assumes none).
        monitor.start()
        startOnboardingOrPrompt()
        // Off the main thread, last: a slow or failing request can't touch launch.
        let ping = launchPing, optedIn = configStore.config.usagePing
        Task.detached(priority: .utility) { await ping.sendLaunch(enabled: optedIn) }
    }

    /// Returning from System Settings: show a permission change at once.
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard isOnboardingVisible else { return }
            monitor.recheck()
            onboardingModel?.recheckNotifications()   // switched on in System Settings
        }
    }

    /// Quitting mid-meeting stops it and keeps it (audio + a note saying so)
    /// before the app goes; see `MeetingSession.quit`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Always through the session: idle can still mean an audio copy is
        // running, and its quit calls back at once when there's nothing to wait for.
        switch termination.request(quit: meetings.quit, reply: { sender.reply(toApplicationShouldTerminate: true) }) {
        case .now: return .terminateNow
        case .later: return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        hotkeys?.stop()
    }

    // MARK: - Status menu

    private func setupMenu() {
        menu = StatusMenu()
        menu.onAction = { [weak self] action in self?.perform(action) }
        menu.onOpenOnboarding = { [weak self] in
            MainActor.assumeIsolated { self?.openOnboarding(isFirstShow: false) }   // menu actions run on main
        }
        menu.onOpenSettings = { [weak self] in self?.openSettings() }
        menu.onOpenLibrary = { [weak self] in self?.openLibrary() }
        menu.onOpenLastMeetingNote = { [weak self] in
            self?.openLibrary { await $0.showLatestMeetingNote() }
        }
        menu.onOpenAbout = { [weak self] in self?.openAbout() }
        menu.onCheckForUpdates = { [weak self] in
            MainActor.assumeIsolated { self?.updater?.checkForUpdates() }   // menu actions run on main
        }
        menu.onOpenConfig = { [weak self] in self?.openConfig() }
        menu.onCopyAgain = { SystemClipboard().write($0) }
        menu.meeting.onAction = { [weak self] in self?.meetings.perform($0) }
        menu.meeting.onOpenSystemAudioSettings = { [weak self] in self?.permissions.openSystemAudioSettings() }
        meetings.render = { [weak self] in self?.menu.renderMeeting($0) }
        meetings.onStatusChange = { [weak self] in self?.meetingStatusChanged($0) }
        // Re-read permissions on open: a mic change while Accessibility is
        // denied leaves the status alone but changes a row.
        menu.onWillOpen = { [weak self] in
            self?.monitor.recheck()
            self?.refreshMenu()
            self?.meetings.refreshApps()
            self?.appleSpeechWatch.check()
            self?.refreshLastMeetingNote()
        }
        meetings.refreshApps()
    }

    /// Sparkle (#24): a found update re-titles the menu item.
    private func startUpdater() {
        MainActor.assumeIsolated {   // launch runs on main
            let updater = SparkleUpdater()
            updater.onChange = { [weak self] in self?.refreshMenu() }
            updater.start()
            self.updater = updater
        }
    }

    private func refreshMenu() {
        let config = configStore.config
        menu.render(StatusMenuContent(status: monitor.status, inputs: monitor.inputs,
                                      hold: "\(config.hold)", toggle: "\(config.toggle)",
                                      // Re-read: a hotkey fixed in Settings clears its line.
                                      configIssues: reportConfigIssues(),
                                      recentDictations: recents.recent(),
                                      historyEnabled: config.dictationHistory,
                                      update: MainActor.assumeIsolated { updater.flatMap(UpdateMenuRow.init) },
                                      lastMeetingNote: lastMeetingNote))
        // Hotkeys rebound, models downloaded or the language changed.
        MainActor.assumeIsolated {
            if isOnboardingVisible { onboardingModel?.refresh() }
        }
    }

    /// Validates the config, logging each problem once when it first appears
    /// (errors via `Log.error`, warnings via `Log.info`); the menu summarises
    /// them. Reporting only.
    @discardableResult
    private func reportConfigIssues() -> [ConfigIssue] {
        let issues = ConfigValidator.validate(configStore.config)
        for issue in configIssueReporter.fresh(issues) {
            switch issue.severity {
            case .error:   Log.error("Config issue: \(issue.message)")
            case .warning: Log.info("Config issue: \(issue.message)")
            }
        }
        return issues
    }

    // MARK: - Readiness

    private func wireMonitor() {
        monitor.onInputsChange = { [weak self] inputs in
            MainActor.assumeIsolated {   // the monitor runs on main
                if self?.isOnboardingVisible == true { self?.onboardingModel?.inputsChanged(inputs) }
            }
            self?.refreshMenu()
            if inputs.microphone == .authorized { self?.keepMicWarmIfConfigured() }
        }
        monitor.onChange = { status in
            if case .notReady(let issue) = status { Log.info("Not ready: \(issue.title). \(issue.detail)") }
        }
        monitor.onBecameReady = { [weak self] isFirst in
            guard isFirst, let config = self?.configStore.config else { return }
            Log.info("Cado is ready. Hold \(config.hold) or press \(config.toggle) to dictate.")
        }
        monitor.onTapNeeded = { [weak self] in self?.installHotkeys() }
    }

    private func requestPermissionsIfNeeded() {
        permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        if !permissions.isAccessibilityTrusted() {
            Log.info("Accessibility not yet granted; prompting user.")
            permissions.requestAccessibility()
        }
    }

    // MARK: - Onboarding (#22)

    /// Launch: onboarding the first time (instead of the system prompts, so
    /// none fires behind it); an already-set-up install (an upgrade) is
    /// recorded as done without it; otherwise the prompts, as before.
    /// Whether a model is installed never blocks: where Apple Speech could be
    /// the model, its state is asked in the background first.
    private func startOnboardingOrPrompt() {
        let config = configStore.config
        guard !config.onboardingDone else { requestPermissionsIfNeeded(); return }   // before any Apple Speech wait
        let asksAppleSpeech = automaticAsksAppleSpeech || engine.model.engine == .appleSpeech
        if asksAppleSpeech, !speechPresence.isKnown(language: config.language) {
            speechPresence.refresh(language: config.language) { [weak self] _ in self?.startOnboardingOrPrompt() }
            return
        }
        switch OnboardingLaunch.decide(done: config.onboardingDone, inputs: monitor.inputs, modelInstalled: isModelInstalled) {
        case .show:
            launchPromptsDeferred = true
            MainActor.assumeIsolated { openOnboarding(isFirstShow: true) }   // launch and the refresh callback run on main
        case .markDone:
            configStore.update { $0.onboardingDone = true }
            requestPermissionsIfNeeded()
        case .nothing:
            requestPermissionsIfNeeded()
        }
    }

    /// A model the config would load is installed (`engineFacts`: no blocking).
    private var isModelInstalled: Bool {
        let facts = engineFacts
        let spec = ModelSelection.select(configStore.config, presentFilenames: ModelSelection.presentFilenames(),
                                         facts: facts).spec
        return facts.isPresent(spec)
    }

    @MainActor private var isOnboardingVisible: Bool { onboardingWindowController?.isVisible == true }

    /// Opens onboarding, or brings it forward. Reopened (from the menu), it
    /// lands where setup stands.
    @MainActor private func openOnboarding(isFirstShow: Bool) {
        if let model = onboardingModel {
            if !isOnboardingVisible {
                model.refresh()
                model.inputsChanged(monitor.inputs)
                model.reopened()
            }
        } else {
            let model = OnboardingViewModel(
                config: { [configStore] in configStore.config },
                inputs: monitor.inputs,
                downloads: sharedSettingsViewModel(),
                options: { [weak self] in self?.onboardingOptions() ?? [] },
                isFirstShow: isFirstShow,
                perform: { [weak self] in self?.perform($0) },
                onFinish: { [weak self] in self?.finishOnboarding() },
                notifications: Notifier.permission,
                setUsagePing: { [weak self] on in
                    MainActor.assumeIsolated { self?.sharedSettingsViewModel().setUsagePing(on) }
                })
            let controller = OnboardingWindowController(viewModel: model)
            controller.onClose = { [weak self] in self?.onboardingClosed() }
            onboardingModel = model
            onboardingWindowController = controller
        }
        onboardingWindowController?.show()
    }

    private func onboardingOptions() -> [OnboardingModelOption] {
        OnboardingModels.options(configStore.config, environment: .current, engines: .shared,
                                 modelsDir: Paths.modelsDir, presentFilenames: ModelSelection.presentFilenames(),
                                 facts: engineFacts)
    }

    /// Done / Finish later: the user has seen it, so it doesn't open by
    /// itself again — also with something still missing (a microphone an
    /// administrator blocks can never be finished); the menu reopens it.
    /// Only the close button leaves it for the next launch.
    @MainActor private func finishOnboarding() {
        configStore.update { $0.onboardingDone = true }
        if isOnboardingVisible { onboardingWindowController?.close() }
    }

    /// Closed (either way) while launch's prompts waited on it: fire what's
    /// still needed, once — the microphone only if never asked, the
    /// Accessibility prompt only if not already shown this run — so skipping
    /// setup still asks, as launch did before onboarding.
    private func onboardingClosed() {
        guard launchPromptsDeferred else { return }
        launchPromptsDeferred = false
        if permissions.microphone == .notDetermined {
            permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        }
        if !permissions.hasPromptedForAccessibility, !permissions.isAccessibilityTrusted() {
            Log.info("Accessibility not yet granted; prompting user.")
            permissions.requestAccessibility()
        }
    }

    private func perform(_ action: ReadinessAction) {
        switch action {
        case .openAccessibilitySettings:
            permissions.requestAccessibility()
        case .openMicrophoneSettings:
            permissions.openMicrophoneSettings()
        case .requestMicrophone:
            permissions.requestMicrophone { [weak self] _ in self?.monitor.recheck() }
        case .openModelsFolder:
            Paths.ensureDirectories()
            NSWorkspace.shared.open(Paths.modelsDir)
        case .openSettings:
            openSettings()
        }
    }

    /// With `keepMicWarm` (no Settings UI) the mic runs from the moment mic
    /// permission is granted, so every dictation gets pre-roll. Otherwise it
    /// starts on first use. Attempts once.
    private func keepMicWarmIfConfigured() {
        guard configStore.config.keepMicWarm, !isMicWarm else { return }
        isMicWarm = true
        do { try capture.warmUp() } catch {
            Log.error("Could not keep the microphone warm: \(error.localizedDescription)")
        }
    }

    // MARK: - Transcription engine

    private func startEngine() {
        engine.onStatusChange = { [weak self] status in self?.engineStatusChanged(status) }
        Log.info("Engine: \(engine.model.engine.displayName). Model: \(engine.model.path) (language \(engine.model.language)); whisper auto-pick for this Mac: \(ModelCatalog.recommended(for: .current).id).")
        if automaticAsksAppleSpeech, !speechPresence.isKnown(language: configStore.config.language) {
            // Automatic may pick Apple Speech: learn whether its model is
            // installed before loading anything, so launch loads one model.
            speechPresence.refresh(language: configStore.config.language) { [weak self] _ in
                guard let self else { return }
                engine.switchModel(to: resolvedModel())   // before load(): just what it loads
                engine.load()
            }
        } else {
            engine.load()
        }
        appleSpeechTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.appleSpeechWatch.check()
        }
    }

    private func resolvedModel() -> ModelSpec {
        let selected = ModelSelection.select(configStore.config, presentFilenames: ModelSelection.presentFilenames(),
                                             facts: engineFacts)
        if selected.note != loggedFallback, let note = selected.note { Log.info(note) }
        loggedFallback = selected.note
        requestedModel = selected.spec
        return selected.spec
    }

    /// What Automatic knows, without blocking main: Apple Speech from
    /// `speechPresence`, other engines' model folders by their own check.
    private var engineFacts: EngineFacts {
        EngineFacts(isPresent: { [speechPresence] spec in
            spec.engine == .appleSpeech ? speechPresence.isInstalled(language: spec.language)
                : EngineRegistry.shared.isPresent(spec)
        }, failed: failedAutomaticEngines)
    }

    /// Automatic could pick Apple Speech here, so its model state matters.
    private var automaticAsksAppleSpeech: Bool {
        let config = configStore.config
        return config.engineChoice == .automatic && config.language != ModelSpec.autoDetect
            && EngineRegistry.shared.available(in: .current, language: config.language).contains(.appleSpeech)
    }

    private func idleUnloadAfter() -> TimeInterval? {
        ModelSelection.idleUnloadAfter(keepWarm: configStore.config.keepModelWarm,
                                       idleMinutes: configStore.config.modelIdleMinutes,
                                       hardware: .current)
    }

    /// Settings changed the model, language or keep-warm: switch live. Jobs
    /// already submitted finish on the current model.
    /// Under Automatic, Apple Speech's model state is re-asked first when it
    /// isn't known for the language (so a language change loads one model),
    /// else afterwards, switching again only if the answer changed.
    private func applyModelSettings() {
        engine.setIdleUnload(after: idleUnloadAfter())
        guard automaticAsksAppleSpeech else { engine.switchModel(to: resolvedModel()); return }
        let language = configStore.config.language
        let known = speechPresence.isKnown(language: language)
        if known { engine.switchModel(to: resolvedModel()) }
        speechPresence.refresh(language: language) { [weak self] changed in
            guard let self, !known || changed else { return }
            engine.switchModel(to: resolvedModel())
        }
    }

    /// Called on main with each status the engine reports. Under Automatic a
    /// model that fails to load is skipped: the next engine's is loaded.
    private func engineStatusChanged(_ status: TranscriptionStatus) {
        if status == .ready { loadHistory.recordLoad(engine.model) }
        if case .failed = status, configStore.config.engineChoice == .automatic,
           let failed = requestedModel?.engine, failed != .whisper, !failedAutomaticEngines.contains(failed) {
            failedAutomaticEngines.insert(failed)
            Log.info("Automatic: \(failed.shortName) failed to load; picking another engine.")
            engine.switchModel(to: resolvedModel())
        }
        MainActor.assumeIsolated { settingsViewModel?.modelStatusChanged(status) }
        let readiness = EngineReadiness(engine, history: loadHistory)
        if let notice = ModelHints.notice(for: status, engine: readiness) {
            Log.error(notice.log)
            Notifier.notify(title: notice.title, body: notice.body)
        }
        if status == .ready { Log.info("Transcription model loaded: \(readiness.modelPath)") }
        monitor.engineChanged(readiness)
        // A meeting an earlier run didn't finish (crash, force quit) needs the
        // engine: recover it once there is one. Not at launch itself, and
        // the session waits for a meeting the user already started.
        if status == .ready, !askedMeetingRecovery {
            askedMeetingRecovery = true
            meetings.recoverLeftovers()
        }
    }

    // MARK: - Dictation & hotkeys

    /// The dictation flow over the live mic, engine and paste; it reports to
    /// `activity`, which the overlay watches.
    /// Settings are read live, so a change applies to the next recording; a
    /// press only starts one when readiness allows (re-checked per press,
    /// without installing a tap from inside the press). The session holds the
    /// monitor, so the gate can't outlive it and fail open.
    private func makeDictationSession() -> DictationSession {
        DictationSession(
            capture: capture,
            engine: EngineDictationAdapter(engine),
            delivery: TextDelivery(),
            feedback: CueFeedback(soundCues: SoundCues(isEnabled: { [configStore] in
                configStore.config.soundCues
            })),
            activity: activity,
            history: recents,
            settings: { [configStore] in
                DictationSettings(maxSeconds: configStore.config.maxRecordingSeconds,
                                  ceilingSeconds: AudioCapture.ceilingSeconds,
                                  trailingSpace: configStore.config.trailingSpace)
            },
            readiness: monitor.currentStatus,
            busy: { [weak self] in self?.meetings.dictationBusy }
        )
    }

    /// The mascot at its saved spots, with the user's settings; a click on it
    /// is a toggle-hotkey press.
    private func makeOverlay() -> MascotOverlay {
        let placement = MascotPlacement(store: ConfigMascotPositionStore(configStore), displays: OverlayDisplay.current)
        let panel = MascotOverlayPanel(placement: placement)
        // Right-click menu (#45): Hide turns "Always show the mascot" off.
        panel.onHide = { [weak self] in
            MainActor.assumeIsolated { self?.sharedSettingsViewModel().setMascotAlwaysVisible(false) }
        }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        return MascotOverlay(feed: activity, panel: panel,
                             settings: MascotOverlay.Settings(configStore.config),
                             onToggleDictation: { [weak self] in
                                 self?.appleSpeechWatch.check()
                                 self?.dictation?.handle(.toggle)
                             })
    }

    /// (Re)installs the hotkey tap from the current config and reports the
    /// outcome to the monitor, which retries a failure with backoff. Only the
    /// monitor calls this (`onTapNeeded`).
    private func installHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        let config = configStore.config
        let manager = HotkeyManager(hold: config.hold, toggle: config.toggle, cancelKeyCode: config.cancelKeyCode)
        manager.onHoldStart = { [weak self] in self?.appleSpeechWatch.check(); self?.dictation?.handle(.holdDown) }
        manager.onHoldStop = { [weak self] in self?.dictation?.handle(.holdUp) }
        manager.onTogglePress = { [weak self] in self?.appleSpeechWatch.check(); self?.dictation?.handle(.toggle) }
        manager.onCancel = { [weak self] in self?.dictation?.handle(.cancel) }
        let started = manager.start()
        if started { hotkeys = manager }
        monitor.hotkeyTapChanged(started ? .installed : .failed)
    }

    /// The Settings recorder is capturing keys: take the tap down, and keep
    /// the monitor from putting it back until `monitor.resumeHotkeys()`.
    private func pauseHotkeys() {
        hotkeys?.stop()
        hotkeys = nil
        monitor.pauseHotkeys()
    }

    // MARK: - Menu actions

    private func openSettings() {
        // Menu actions are always dispatched on the main thread; assume main
        // actor so we can create @MainActor-isolated types synchronously.
        MainActor.assumeIsolated {
            if settingsWindowController == nil {
                settingsWindowController = SettingsWindowController(viewModel: sharedSettingsViewModel())
            }
            settingsWindowController?.show()
        }
    }

    /// The one `SettingsViewModel`, made on first need.
    @MainActor private func sharedSettingsViewModel() -> SettingsViewModel {
        if let settingsViewModel { return settingsViewModel }
        let vm = SettingsViewModel(
            configStore: configStore,
            loginItem: loginItem,
            availableMics: { AudioDevices.inputDevices() },
            presentModelFilenames: { ModelSelection.presentFilenames() },
            onNeedsMenuRefresh: { [weak self] in self?.refreshMenu() },
            // Suspends the tap during live hotkey capture so it doesn't
            // swallow the chosen key; resuming reinstalls it from the
            // (possibly rebound) config.
            pauseHotkeys: { [weak self] in self?.pauseHotkeys() },
            reloadHotkeys: { [weak self] in self?.monitor.resumeHotkeys() },
            hardware: .current,
            currentModel: { [engine] in engine.model },
            modelStatus: engine.status,
            // Also how a finished download is loaded (it re-resolves the model).
            onModelSettingsChange: { [weak self] in
                self?.failedAutomaticEngines = []   // a settings change retries them
                self?.applyModelSettings()
            },
            onMascotSettingsChange: { [weak self] in
                guard let self else { return }
                overlay?.apply(MascotOverlay.Settings(configStore.config))
            },
            onUsagePingChange: { [launchPing] in launchPing.setEnabled($0) },
            isFirstLoad: { [loadHistory] in EngineRegistry.shared.isFirstLoad($0, history: loadHistory) },
            engineFacts: { [weak self] in self?.engineFacts },
            onDictationHistoryChange: { [weak self] in
                guard let self else { return }
                // Turned off = forgotten, not just hidden.
                if !configStore.config.dictationHistory { recents.clear() }
                refreshMenu()
            },
            updater: updater ?? DisabledUpdater()
        )
        settingsViewModel = vm
        return vm
    }

    /// Shows the Library, then runs `then` on its state (select a note).
    private func openLibrary(then: (@MainActor (LibraryViewModel) async -> Void)? = nil) {
        MainActor.assumeIsolated {   // menu actions and notification clicks run on the main thread
            let viewModel = libraryModel()
            if libraryWindowController == nil {
                libraryWindowController = LibraryWindowController(viewModel: viewModel, dock: DockPresence())
            }
            libraryWindowController?.show()
            if let then { Task { await then(viewModel) } }
        }
    }

    @MainActor private func libraryModel() -> LibraryViewModel {
        if let libraryViewModel { return libraryViewModel }
        let viewModel = LibraryViewModel(library: notesLibrary)
        viewModel.meetingStatusChanged(meetings.status)
        libraryViewModel = viewModel
        return viewModel
    }

    /// A clicked notification (#42).
    private func open(_ route: NotificationRoute) {
        switch route {
        case .openNote(let id): openLibrary { await $0.show(noteID: id) }
        }
    }

    /// The Library's in-progress row follows the meeting; a finished one
    /// may be the new last meeting note.
    private func meetingStatusChanged(_ status: MeetingStatus) {
        MainActor.assumeIsolated { libraryViewModel?.meetingStatusChanged(status) }
        if status == .idle { refreshLastMeetingNote() }
    }

    /// Re-reads the newest meeting note off main; re-renders the menu if it
    /// changed.
    private func refreshLastMeetingNote() {
        let library = notesLibrary
        DispatchQueue.global(qos: .utility).async {
            let latest = library.latestNote(kind: NoteKind.meeting)
            DispatchQueue.main.async { [weak self] in
                guard let self, latest != lastMeetingNote else { return }
                lastMeetingNote = latest
                refreshMenu()
            }
        }
    }

    private func openAbout() {
        MainActor.assumeIsolated {   // menu actions run on the main thread
            if aboutWindowController == nil { aboutWindowController = AboutWindowController() }
            aboutWindowController?.show()
        }
    }

    /// The main menu's "About Cado" and "Settings…" (while the Dock icon
    /// shows) reach these through the responder chain.
    @objc func showAbout(_ sender: Any?) { openAbout() }
    @objc func showSettings(_ sender: Any?) { openSettings() }

    private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) { configStore.save() }
        NSWorkspace.shared.open(Paths.configFile)
    }
}
