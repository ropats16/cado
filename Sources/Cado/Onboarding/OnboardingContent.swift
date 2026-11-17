import Foundation

/// The onboarding steps (#22), in flow order. The microphone comes before
/// Accessibility: its one-click system dialog is the easier start, while
/// Accessibility sends the user to System Settings. Notifications (#44) are
/// optional: asked here rather than at the first banner, which is often an
/// error, and never part of being set up.
enum OnboardingStepID: Int, CaseIterable, Comparable {
    case welcome, microphone, accessibility, model, notifications, ready

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Not part of being set up; a reopen doesn't land on it.
    var isOptional: Bool { self == .notifications }
}

enum OnboardingStepState: Equatable {
    case todo
    /// The user acted and it's under way: a download.
    case waiting
    /// Transient, finishes by itself (hotkeys starting, the model loading):
    /// the user can move on.
    case settling
    case done
    /// Nothing the user can do here (an administrator's restriction).
    case blocked
    /// An optional step the user (or the build) said no to: nothing left
    /// to do here, though it can be changed later.
    case declined

    var isFinished: Bool { self == .done || self == .settling || self == .declined }
}

/// What a step's button does; the onboarding view model carries it out.
enum OnboardingAction: Equatable {
    case readiness(ReadinessAction)
    case download(ModelDownloadKey)
    case cancelDownload(ModelDownloadKey)
    case selectModel(ModelDownloadKey)
    /// The system's notification prompt (`NotificationPermissionPort`).
    case requestNotifications
    /// System Settings › Notifications, to turn them back on.
    case openNotificationSettings
    /// Back to a step (Ready's list of what's still needed).
    case goTo(OnboardingStepID)
    /// Close onboarding and remember it's done.
    case finish
}

struct OnboardingButton: Equatable {
    var title: String
    var action: OnboardingAction
}

/// One step as shown. Navigation (Continue, Back) is the view's; these
/// buttons are the step's own.
struct OnboardingStep: Equatable {
    var id: OnboardingStepID
    var state: OnboardingStepState
    var title: String
    var detail: String
    var primary: OnboardingButton?
    var secondary: OnboardingButton?
    /// A download's fraction, 0…1.
    var progress: Double?
    /// A short status line: what's happening, or why it failed.
    var note: String?
    /// Ready, not yet set up: a button per step still needed, back to it.
    var jumps: [OnboardingButton] = []
}

/// What the model step knows beyond readiness: the models on offer
/// (`OnboardingModels.options`) and the downloads (`ModelDownloadControl`).
struct OnboardingModelFacts: Equatable {
    /// Recommended first.
    var options: [OnboardingModelOption]
    /// The user's pick; nil (or one no longer offered) = the recommended one.
    var selected: ModelDownloadKey?
    var downloads: [ModelDownloadKey: ModelDownloadState]
    /// Models with a stopped download to resume.
    var partial: Set<ModelDownloadKey>
}

/// Every onboarding step, derived from live readiness and the model facts.
/// Nothing about progress is stored: a permission granted (or revoked) in
/// System Settings, or a download finishing in Settings, shows here by
/// itself, and reopening the flow lands where setup actually stands.
struct OnboardingContent: Equatable {
    /// One per `OnboardingStepID`, in order.
    var steps: [OnboardingStep]
    /// Microphone, Accessibility and the model are finished (settling
    /// counts). Notifications are optional and don't count.
    var isSetUp: Bool

    /// `notifications`: nil until it's been read (it's asynchronous).
    init(inputs: ReadinessInputs, model: OnboardingModelFacts, notifications: NotificationPermission?,
         hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int) {
        let setup = [Self.microphone(inputs.microphone),
                     Self.accessibility(inputs.accessibility, tap: inputs.hotkeyTap),
                     Self.model(inputs.engine, model)]
        let ready = Self.ready(setup, hold: hold, toggle: toggle, cancelKeyCode: cancelKeyCode)
        steps = [Self.welcome] + setup + [Self.notifications(notifications), ready]
        isSetUp = ready.state == .done
    }

    func step(_ id: OnboardingStepID) -> OnboardingStep {
        steps[id.rawValue]   // one per id, in order (init)
    }

    /// Where the window opens: Welcome the first time; on a reopen, the
    /// first unfinished required step, else Ready. Never the optional
    /// Notifications step: a reopen is for fixing setup, and its permission
    /// is read asynchronously, so landing on it could flash and move on.
    func landing(isFirstShow: Bool) -> OnboardingStepID {
        guard !isFirstShow else { return .welcome }
        return steps.first { $0.id != .welcome && !$0.id.isOptional && ($0.id == .ready || !$0.state.isFinished) }?.id
            ?? .ready
    }

    /// The first unfinished step after `id`, else Ready.
    func next(after id: OnboardingStepID) -> OnboardingStepID {
        steps.first { $0.id > id && ($0.id == .ready || !$0.state.isFinished) }?.id ?? .ready
    }

    /// Where to move when `current` just turned finished (a permission
    /// granted, a download landed); nil otherwise. Never pulls back: a step
    /// revoked behind the user shows on Ready instead.
    static func autoAdvance(current: OnboardingStepID, old: OnboardingContent,
                            new: OnboardingContent) -> OnboardingStepID? {
        guard current != .welcome, current != .ready,
              !old.step(current).state.isFinished, new.step(current).state.isFinished else { return nil }
        return new.next(after: current)
    }

    // MARK: - Steps

    private static let welcome = OnboardingStep(
        id: .welcome, state: .done, title: "Welcome to Cado",
        detail: "Hold a key, speak, and your words appear wherever you're typing. "
            + "Everything stays on this Mac. Setup takes a minute.")

    private static func microphone(_ permission: MicrophonePermission) -> OnboardingStep {
        var step = OnboardingStep(id: .microphone, state: .todo, title: "Microphone", detail: "")
        switch permission {
        case .notDetermined:
            step.detail = "Let Cado hear you. It records only while you use the hotkey, and transcribes on this Mac."
            step.primary = OnboardingButton(title: "Allow Microphone", action: .readiness(.requestMicrophone))
        case .denied:
            step.detail = "Microphone is off for Cado. Turn it on in Privacy & Security › Microphone."
            step.primary = OnboardingButton(title: "Open System Settings", action: .readiness(.openMicrophoneSettings))
        case .restricted:
            step.state = .blocked
            step.detail = "This Mac's administrator blocks the microphone."
        case .authorized:
            step.state = .done
            step.detail = "Cado can hear you."
        }
        return step
    }

    private static func accessibility(_ permission: AccessibilityPermission, tap: HotkeyTapHealth) -> OnboardingStep {
        var step = OnboardingStep(id: .accessibility, state: .todo, title: "Accessibility", detail: "")
        let open = OnboardingButton(title: "Allow Accessibility…", action: .readiness(.openAccessibilitySettings))
        switch (permission, tap) {
        case (.denied, _):
            step.detail = "Let Cado use its hotkeys in any app and paste where your cursor is."
            step.note = "Switch Cado on, then come back. This page updates by itself."
            step.primary = open
        case (.granted, .failed):
            step.detail = "macOS says Cado is allowed but its hotkeys won't start. Remove Cado with −, then add it again."
            step.primary = open
        case (.granted, .notInstalled):
            step.state = .settling
            step.detail = "Starting the hotkeys…"
        case (.granted, .installed):
            step.state = .done
            step.detail = "Hotkeys and pasting work in any app."
        }
        return step
    }

    private static func model(_ engine: EngineReadiness, _ facts: OnboardingModelFacts) -> OnboardingStep {
        var step = OnboardingStep(id: .model, state: .todo, title: "Speech model",
                                  detail: "Cado transcribes right on this Mac, so it needs a speech model.")
        let chosen = facts.options.first { $0.key == facts.selected } ?? facts.options.first

        switch engine.status {
        case .ready:
            step.state = .done
            step.detail = "Your speech model is ready. Nothing you say leaves this Mac."
            // Running something else (an older setup): the pick stays on offer.
            if let chosen, !chosen.isInstalled, chosen.fetch == .inApp {
                let get = download(chosen, facts)
                step.secondary = get.button.map {
                    $0.action == .download(chosen.key) ? OnboardingButton(title: "\($0.title) \(chosen.title)",
                                                                          action: $0.action) : $0
                }
                step.progress = get.progress
                step.note = get.note ?? "Optional: \(chosen.title) suits this Mac best."
            }
        case .verifying:
            step.state = .settling
            step.note = "Checking the speech model…"
        case .notLoaded, .loading:
            step.state = .settling
            step.note = engine.isFirstLoad ? "Preparing the speech model. The first time takes a minute."
                : "Loading the speech model…"
        case .missing, .failed:
            guard let chosen else {
                if case .failed(let reason) = engine.status { step.note = reason }
                step.primary = OnboardingButton(title: "Open Settings", action: .readiness(.openSettings))
                return step
            }
            if chosen.isInstalled {
                if case .failed(let reason) = engine.status {
                    step.detail = "\(chosen.title) is installed but didn't load."
                    step.note = reason
                    step.primary = OnboardingButton(title: "Open Settings", action: .readiness(.openSettings))
                } else {
                    // Just downloaded; the engine picks it up in a moment.
                    step.state = .settling
                    step.note = "Loading the speech model…"
                }
                return step
            }
            step.detail += chosen.isRecommended
                ? " \(chosen.title) suits this Mac best."   // its size is in the picker row
                : " You chose \(chosen.title)."
            let get = download(chosen, facts)
            step.state = get.state
            step.primary = get.button
            step.progress = get.progress
            step.note = get.note
        }
        return step
    }

    private static func notifications(_ permission: NotificationPermission?) -> OnboardingStep {
        var step = OnboardingStep(
            id: .notifications, state: .todo, title: "Notifications",
            detail: "Cado can tell you when a meeting note is saved, an update is ready, or something needs you, "
                + "like a dictation it copied instead of pasting. This step is optional.")
        switch permission {
        case .notDetermined?:
            step.primary = OnboardingButton(title: "Allow Notifications", action: .requestNotifications)
        case .authorized?:
            step.state = .done
            step.detail = "Cado can tell you when a meeting note is saved or something needs you."
        case .denied?:
            step.state = .declined
            step.detail = "Notifications are off for Cado. You can turn them on in System Settings › Notifications."
            step.primary = OnboardingButton(title: "Open System Settings", action: .openNotificationSettings)
        case .unavailable?:
            step.state = .declined
            step.detail = "This copy of Cado can't show notifications."
        case nil:
            step.state = .settling   // read in a moment; nothing to stop on
        }
        return step
    }

    /// How to get `option` now: its download's progress or failure, else
    /// how it's fetched.
    private static func download(_ option: OnboardingModelOption, _ facts: OnboardingModelFacts)
        -> (state: OnboardingStepState, button: OnboardingButton?, progress: Double?, note: String?) {
        switch facts.downloads[option.key] {
        case .downloading(let fraction)?:
            return (.waiting, OnboardingButton(title: "Cancel", action: .cancelDownload(option.key)), fraction,
                    "Downloading… \(Int((fraction * 100).rounded(.down)))%")
        case .failed(let reason)?:
            return (.todo, OnboardingButton(title: "Retry", action: .download(option.key)), nil, reason)
        case nil:
            switch option.fetch {
            case .inApp:
                let title = facts.partial.contains(option.key) ? "Resume" : "Download"
                return (.todo, OnboardingButton(title: title, action: .download(option.key)), nil, nil)
            case .settings:
                return (.todo, OnboardingButton(title: "Open Settings", action: .readiness(.openSettings)), nil, nil)
            case .command:
                // Only a source checkout fetches it (the command is logged
                // with the engine's missing-model notice).
                return (.todo, OnboardingButton(title: "Open Settings", action: .readiness(.openSettings)), nil,
                        "Cado can't download \(option.title). Choose another speech model in Settings.")
            }
        }
    }

    private static func ready(_ setup: [OnboardingStep], hold: KeyBinding, toggle: KeyBinding,
                              cancelKeyCode: Int) -> OnboardingStep {
        let unfinished = setup.filter { !$0.state.isFinished }
        let modelSettling = setup.contains { $0.id == .model && $0.state == .settling }
        let note = modelSettling ? "Preparing the speech model. You can start now; your first dictation waits for it." : nil
        guard unfinished.isEmpty else {
            return OnboardingStep(
                id: .ready, state: .todo, title: "Almost there",
                detail: "Finish these steps to start dictating, or come back later: "
                    + "Set Up Cado… in the menu bar reopens this window.",
                primary: OnboardingButton(title: "Finish Later", action: .finish), note: note,
                jumps: unfinished.map { OnboardingButton(title: jumpTitle($0), action: .goTo($0.id)) })
        }
        var lines = ["Hold \(hold.description) and speak; release to paste.",
                     "Or press \(toggle.description) to start, and again to stop."]
        if cancelKeyCode == KeyBinding.escapeKeyCode { lines.append("Esc cancels.") }
        lines.append("Cado lives in the menu bar.")
        return OnboardingStep(id: .ready, state: .done, title: "You're ready", detail: lines.joined(separator: "\n"),
                              primary: OnboardingButton(title: "Done", action: .finish), note: note)
    }
}

/// A step's name as a button (Title Case).
private func jumpTitle(_ step: OnboardingStep) -> String {
    step.id == .model ? "Speech Model" : step.title
}

/// Whether launch opens onboarding.
enum OnboardingLaunch {
    enum Decision: Equatable {
        case show
        /// Already set up (an upgrade): record it as done without showing it.
        case markDone
        case nothing
    }

    /// Done → nothing. Not done but already set up (Accessibility granted,
    /// microphone authorized, a model installed) → mark it done, so
    /// upgraders never see it. Otherwise show it.
    static func decide(done: Bool, inputs: ReadinessInputs, modelInstalled: Bool) -> Decision {
        guard !done else { return .nothing }
        let setUp = inputs.accessibility == .granted && inputs.microphone == .authorized && modelInstalled
        return setUp ? .markDone : .show
    }
}
