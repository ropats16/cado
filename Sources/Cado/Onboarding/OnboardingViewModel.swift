import Foundation
import Combine

/// Drives the onboarding window (#22): which step shows, and carrying out
/// its buttons. Everything shown comes from `OnboardingContent`, rebuilt
/// from live readiness (`inputsChanged`), the config and models
/// (`refresh`) and the shared downloads (`ModelDownloadControl`), so a
/// permission granted in System Settings or a download started in Settings
/// shows here by itself.
@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var content: OnboardingContent
    @Published private(set) var current: OnboardingStepID
    /// The optional launch-ping choice on Ready (#26); off until the user turns it on.
    @Published private(set) var usagePing: Bool
    private let onUsagePing: (Bool) -> Void

    private let config: () -> Config
    private let downloads: ModelDownloadControl
    private let options: () -> [OnboardingModelOption]
    private let performReadiness: (ReadinessAction) -> Void
    private let onFinish: () -> Void
    /// Read, asked and opened through this (#44); nil until first read.
    private let notifications: NotificationPermissionPort
    private var notificationPermission: NotificationPermission?
    /// The calendar step (#38): read live, asked only when the user presses its button.
    private let calendar: CalendarPort
    private let setCalendarNaming: (Bool) -> Void
    private var inputs: ReadinessInputs
    private var facts: OnboardingModelFacts
    private var subscription: AnyCancellable?
    /// A refresh of the options and partial downloads is queued.
    private var isFactsRefreshPending = false

    init(config: @escaping () -> Config, inputs: ReadinessInputs, downloads: ModelDownloadControl,
         options: @escaping () -> [OnboardingModelOption], isFirstShow: Bool,
         perform: @escaping (ReadinessAction) -> Void, onFinish: @escaping () -> Void,
         notifications: NotificationPermissionPort, setUsagePing: @escaping (Bool) -> Void = { _ in },
         calendar: CalendarPort = UnavailableCalendar(), setCalendarNaming: @escaping (Bool) -> Void = { _ in }) {
        self.calendar = calendar
        self.setCalendarNaming = setCalendarNaming
        self.config = config
        self.usagePing = config().usagePing
        self.onUsagePing = setUsagePing
        self.downloads = downloads
        self.options = options
        self.performReadiness = perform
        self.onFinish = onFinish
        self.notifications = notifications
        self.inputs = inputs
        let offered = options()
        facts = OnboardingModelFacts(options: offered, selected: nil, downloads: downloads.modelDownloads,
                                     partial: Self.partial(offered, downloads))
        let content = Self.content(inputs, facts, nil, config(), calendar)
        self.content = content
        current = content.landing(isFirstShow: isFirstShow)
        subscription = downloads.modelDownloadsPublisher.sink { [weak self] state in
            // Published from the main actor (SettingsViewModel's `@Published`).
            MainActor.assumeIsolated { self?.downloadsChanged(state) }
        }
        recheckNotifications()
    }

    // MARK: - What the view shows

    var step: OnboardingStep { content.step(current) }

    /// The models on offer, recommended first.
    var modelOptions: [OnboardingModelOption] { facts.options }

    /// The model the step's Download button targets: the user's pick, else
    /// the recommended one.
    var selectedModel: ModelDownloadKey? {
        facts.options.first { $0.key == facts.selected }?.key ?? facts.options.first?.key
    }

    /// The picker is shown: a choice to make, the model isn't set up yet.
    var showsModelPicker: Bool {
        facts.options.count > 1 && content.step(.model).state != .done && content.step(.model).state != .settling
    }

    /// The pick can change: nothing on offer is downloading.
    var canChooseModel: Bool {
        !facts.options.contains { if case .downloading? = facts.downloads[$0.key] { return true } else { return false } }
    }

    /// The current step's note is a problem (a failed download or load),
    /// not just a status line.
    var noteIsProblem: Bool {
        guard current == .model else { return false }
        if case .failed = inputs.engine.status { return true }
        if let key = selectedModel, case .failed? = facts.downloads[key] { return true }
        return false
    }

    var canGoBack: Bool { current != .welcome }

    /// Continue, or "Skip for Now" past an unfinished step; nil on Ready,
    /// where the step's own button is the way out.
    var forwardTitle: String? {
        guard current != .ready else { return nil }
        return step.state.isFinished ? "Continue" : "Skip for Now"
    }

    // MARK: - Updates

    /// Live readiness changed: the steps follow it, and a step that just
    /// finished moves the flow on (never back).
    func inputsChanged(_ inputs: ReadinessInputs) {
        let engineChanged = inputs.engine != self.inputs.engine
        self.inputs = inputs
        // The engine changing is often a model arriving (or failing).
        if engineChanged { reloadFacts() }
        rebuild()
    }

    /// The config (hotkeys, language, engine) or the models changed.
    func refresh() {
        reloadFacts()
        rebuild()
    }

    /// The window is shown again: land where setup stands.
    func reopened() {
        recheckNotifications()
        rebuild()   // Calendar access may have changed in System Settings
        current = content.landing(isFirstShow: false)
    }

    /// Re-reads the notification permission (back from System Settings).
    func recheckNotifications() {
        notifications.current { [weak self] permission in
            MainActor.assumeIsolated { self?.notificationsChanged(permission) }   // completions run on main
        }
    }

    // MARK: - Intents

    func perform(_ action: OnboardingAction) {
        switch action {
        case .readiness(let readiness):
            performReadiness(readiness)
        case .download(let key):
            downloads.downloadModel(key)
        case .cancelDownload(let key):
            downloads.cancelModelDownload(key)
        case .selectModel(let key):
            guard canChooseModel, facts.options.contains(where: { $0.key == key }) else { return }
            facts.selected = key
            rebuild()
        case .requestNotifications:
            notifications.request { [weak self] permission in
                MainActor.assumeIsolated { self?.notificationsChanged(permission) }
            }
        case .openNotificationSettings:
            notifications.openSettings()
        case .enableCalendar:
            calendar.requestAccess { [weak self] access in
                MainActor.assumeIsolated {
                    if access == .granted { self?.setCalendarNaming(true) }
                    self?.rebuild()
                }
            }
        case .openCalendarSettings:
            calendar.openSettings()
        case .goTo(let id):
            current = id
        case .finish:
            onFinish()
        }
    }

    /// The launch-ping choice; the app saves it and makes or deletes the id.
    func setUsagePing(_ on: Bool) {
        usagePing = on
        onUsagePing(on)
    }

    func back() {
        guard let previous = OnboardingStepID(rawValue: current.rawValue - 1) else { return }
        current = previous
    }

    func forward() {
        guard current != .ready, let next = OnboardingStepID(rawValue: current.rawValue + 1) else { return }
        current = next
    }

    // MARK: - Private

    private func downloadsChanged(_ state: [ModelDownloadKey: ModelDownloadState]) {
        let startedOrSettled = Self.shape(state) != Self.shape(facts.downloads)
        facts.downloads = state
        rebuild()
        // A download started, finished, failed or was cancelled: what's
        // installed and what's left to resume changed. Read once it's
        // settled — the publisher fires before the control updates — and
        // not on every progress tick (it's the disk).
        if startedOrSettled, !isFactsRefreshPending {
            isFactsRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isFactsRefreshPending = false
                reloadFacts()
                rebuild()
            }
        }
    }

    private func notificationsChanged(_ permission: NotificationPermission) {
        guard permission != notificationPermission else { return }
        notificationPermission = permission
        rebuild()
    }

    private func reloadFacts() {
        facts.options = options()
        facts.downloads = downloads.modelDownloads
        facts.partial = Self.partial(facts.options, downloads)
    }

    private func rebuild() {
        let old = content
        content = Self.content(inputs, facts, notificationPermission, config(), calendar)
        if let next = OnboardingContent.autoAdvance(current: current, old: old, new: content) { current = next }
    }

    private static func content(_ inputs: ReadinessInputs, _ facts: OnboardingModelFacts,
                                _ notifications: NotificationPermission?, _ config: Config,
                                _ calendar: CalendarPort) -> OnboardingContent {
        OnboardingContent(inputs: inputs, model: facts, notifications: notifications,
                          calendar: calendar.access, calendarOn: config.nameMeetingsFromCalendar, hold: config.hold,
                          toggle: config.toggle, cancelKeyCode: config.cancelKeyCode)
    }

    private static func partial(_ options: [OnboardingModelOption],
                                _ downloads: ModelDownloadControl) -> Set<ModelDownloadKey> {
        Set(options.map(\.key).filter(downloads.hasPartialDownload))
    }

    /// Which models are downloading, failed or neither — not how far along.
    private static func shape(_ state: [ModelDownloadKey: ModelDownloadState]) -> [ModelDownloadKey: Bool] {
        state.mapValues { if case .downloading = $0 { return true } else { return false } }
    }
}
