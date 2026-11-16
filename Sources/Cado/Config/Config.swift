import Foundation

/// User-editable configuration, persisted as JSON at `Paths.configFile`.
///
/// Decoding is tolerant: any missing key falls back to its default, so a
/// hand-edited or older config keeps working and new fields are forward-safe.
struct Config: Codable {
    /// "auto" (the default, also for configs without the key: the engine
    /// `EnginePolicy` picks for this Mac and language) or an engine's id
    /// (`EngineKind` raw value), e.g. "whisper" or "parakeet". Kept as
    /// written, even if unknown or unavailable here: the app then runs whisper
    /// (see `EngineRegistry.select`) without rewriting it, so the choice
    /// returns when it can run again. Read it through `engineChoice`.
    var engine: String
    /// whisper's model: "auto" (pick by chip + RAM) or a model id, e.g.
    /// "small.en-q5_1". Other engines' picks are in `engineModels`.
    var model: ModelChoice
    /// A specific whisper model file; overrides `model` when non-empty. Older
    /// configs carry one, so an existing choice keeps working.
    var modelPath: String
    /// The model pick of each engine other than whisper, by engine id ("auto"
    /// or the engine's model id); a missing entry means "auto". Use
    /// `modelChoice(for:)` / `setModelChoice(_:for:)`, which route whisper to
    /// `model`.
    var engineModels: [String: ModelChoice]
    var hold: KeyBinding
    var toggle: KeyBinding
    var cancelKeyCode: Int          // Esc = 53
    var maxRecordingSeconds: Double // <= 0 = no limit (a 30-min ceiling still applies)
    var trailingSpace: Bool
    var microphoneUID: String?      // nil = system default input
    var soundCues: Bool
    var language: String
    var threads: Int                // 0 = auto: performance cores, ≤ 8 (WhisperAdapter.autoThreadCount)
    var keepMicWarm: Bool           // no Settings UI: mic stays on from launch (pre-roll on every dictation)
    var keepModelWarm: Bool?        // nil = auto: unload when idle only on Macs with <= 8 GB
    var modelIdleMinutes: Double    // idle time before unloading, when not kept warm
    /// Keep a small resting mascot on screen between dictations; click it to
    /// start/stop one (#20). Off: the mascot shows only while active.
    var mascotAlwaysVisible: Bool
    /// Let screen shares and recordings capture the mascot. Off (the default):
    /// its window is excluded from capture.
    var mascotInScreenShares: Bool
    /// Where the user dragged the mascot, per display (key: the display's
    /// stable id; see `OverlayPlacement`). No entry = the default corner.
    var mascotPositions: [String: MascotPosition]
    /// Onboarding (#22) was finished or skipped, so launch doesn't show it.
    /// Missing (older configs) = false; launch then marks a Mac that's
    /// already set up as done (`OnboardingLaunch`), so upgraders never see it.
    var onboardingDone: Bool
    /// Opt-in anonymous launch ping (#26). Off unless the user switches it on
    /// (onboarding, Settings); missing in older configs = off.
    var usagePing: Bool
    /// The notes folder's path (#28); "" = `NotesFolder.defaultURL`. Read it
    /// through `NotesFolder.resolve`, which prefers the bookmark.
    var notesFolder: String
    /// Base64 bookmark of the chosen notes folder, so it survives being
    /// renamed or moved. nil = never chosen (or hand-edited away).
    var notesFolderBookmark: String?
    /// Keep the last few delivered dictations (`RecentDictationsStore`, in the
    /// support folder, not the notes folder) for the menu's copy-again (#28).
    /// Off by default.
    var dictationHistory: Bool

    static var defaults: Config {
        Config(
            model: .automatic,
            modelPath: "",
            hold: .controlShift,
            toggle: .controlOptionSpace,
            cancelKeyCode: KeyBinding.escapeKeyCode,
            maxRecordingSeconds: 600,
            trailingSpace: false,
            microphoneUID: nil,
            soundCues: false,
            language: "en",
            threads: 0,
            keepMicWarm: false,
            keepModelWarm: nil,
            modelIdleMinutes: 5,
            mascotAlwaysVisible: false,
            mascotInScreenShares: false,
            mascotPositions: [:],
            onboardingDone: false,
            usagePing: false,
            notesFolder: "",
            notesFolderBookmark: nil,
            dictationHistory: false
        )
    }

    init(engine: String = EngineChoice.automaticID, model: ModelChoice = .automatic, modelPath: String,
         engineModels: [String: ModelChoice] = [:], hold: KeyBinding, toggle: KeyBinding, cancelKeyCode: Int,
         maxRecordingSeconds: Double, trailingSpace: Bool, microphoneUID: String?,
         soundCues: Bool, language: String, threads: Int, keepMicWarm: Bool,
         keepModelWarm: Bool? = nil, modelIdleMinutes: Double = 5,
         mascotAlwaysVisible: Bool = false, mascotInScreenShares: Bool = false,
         mascotPositions: [String: MascotPosition] = [:], onboardingDone: Bool = false,
         usagePing: Bool = false,
         notesFolder: String = "", notesFolderBookmark: String? = nil,
         dictationHistory: Bool = false) {
        self.engine = engine
        self.model = model
        self.modelPath = modelPath
        self.engineModels = engineModels
        self.hold = hold
        self.toggle = toggle
        self.cancelKeyCode = cancelKeyCode
        self.maxRecordingSeconds = maxRecordingSeconds
        self.trailingSpace = trailingSpace
        self.microphoneUID = microphoneUID
        self.soundCues = soundCues
        self.language = language
        self.threads = threads
        self.keepMicWarm = keepMicWarm
        self.keepModelWarm = keepModelWarm
        self.modelIdleMinutes = modelIdleMinutes
        self.mascotAlwaysVisible = mascotAlwaysVisible
        self.mascotInScreenShares = mascotInScreenShares
        self.mascotPositions = mascotPositions
        self.onboardingDone = onboardingDone
        self.usagePing = usagePing
        self.notesFolder = notesFolder
        self.notesFolderBookmark = notesFolderBookmark
        self.dictationHistory = dictationHistory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        model = try c.decodeIfPresent(ModelChoice.self, forKey: .model) ?? d.model
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? d.modelPath
        // A pre-engine config that hand-picked a whisper model (a `modelPath`
        // or a named `model`) chose whisper; keep it there rather than moving
        // it to whatever Automatic picks. Untouched configs get Automatic.
        let pickedWhisper = !modelPath.isEmpty || model != .automatic
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
            ?? (pickedWhisper ? EngineKind.whisper.rawValue : d.engine)
        engineModels = try c.decodeIfPresent([String: ModelChoice].self, forKey: .engineModels) ?? d.engineModels
        hold = try c.decodeIfPresent(KeyBinding.self, forKey: .hold) ?? d.hold
        toggle = try c.decodeIfPresent(KeyBinding.self, forKey: .toggle) ?? d.toggle
        cancelKeyCode = try c.decodeIfPresent(Int.self, forKey: .cancelKeyCode) ?? d.cancelKeyCode
        maxRecordingSeconds = try c.decodeIfPresent(Double.self, forKey: .maxRecordingSeconds) ?? d.maxRecordingSeconds
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
        microphoneUID = try c.decodeIfPresent(String.self, forKey: .microphoneUID)
        soundCues = try c.decodeIfPresent(Bool.self, forKey: .soundCues) ?? d.soundCues
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        keepMicWarm = try c.decodeIfPresent(Bool.self, forKey: .keepMicWarm) ?? d.keepMicWarm
        keepModelWarm = try c.decodeIfPresent(Bool.self, forKey: .keepModelWarm)
        modelIdleMinutes = try c.decodeIfPresent(Double.self, forKey: .modelIdleMinutes) ?? d.modelIdleMinutes
        mascotAlwaysVisible = try c.decodeIfPresent(Bool.self, forKey: .mascotAlwaysVisible) ?? d.mascotAlwaysVisible
        mascotInScreenShares = try c.decodeIfPresent(Bool.self, forKey: .mascotInScreenShares) ?? d.mascotInScreenShares
        mascotPositions = try c.decodeIfPresent([String: MascotPosition].self, forKey: .mascotPositions) ?? d.mascotPositions
        onboardingDone = try c.decodeIfPresent(Bool.self, forKey: .onboardingDone) ?? d.onboardingDone
        usagePing = try c.decodeIfPresent(Bool.self, forKey: .usagePing) ?? d.usagePing
        notesFolder = try c.decodeIfPresent(String.self, forKey: .notesFolder) ?? d.notesFolder
        notesFolderBookmark = try c.decodeIfPresent(String.self, forKey: .notesFolderBookmark)
        dictationHistory = try c.decodeIfPresent(Bool.self, forKey: .dictationHistory) ?? d.dictationHistory
    }

    /// `engine` parsed: Automatic, a known engine, or nil for an id this
    /// build doesn't know (it runs whisper; see `ConfigValidator`).
    var engineChoice: EngineChoice? { EngineChoice(id: engine) }

    /// `engine`'s model pick: `model` for whisper, else its `engineModels`
    /// entry (Automatic if unset).
    func modelChoice(for engine: EngineKind) -> ModelChoice {
        engine == .whisper ? model : engineModels[engine.rawValue] ?? .automatic
    }

    /// `engine`'s hand-set model file (`ModelContext.customPath`): `modelPath`
    /// for whisper, which predates per-engine picks; "" for the others.
    func customModelPath(for engine: EngineKind) -> String {
        engine == .whisper ? modelPath : ""
    }

    /// Records a model pick for `engine`. For whisper it also clears
    /// `modelPath`: a pick replaces any hand-set file.
    mutating func setModelChoice(_ choice: ModelChoice, for engine: EngineKind) {
        if engine == .whisper {
            model = choice
            modelPath = ""
        } else {
            engineModels[engine.rawValue] = choice
        }
    }
}

/// A saved mascot spot on one display: the overlay window's origin as an
/// offset (points, y up) from that display's visible-frame origin, so it
/// survives the display moving in the arrangement. Clamped on restore.
struct MascotPosition: Codable, Equatable {
    var x: Double
    var y: Double
}

/// `config.json`'s `engine`: Automatic (`EnginePolicy`) or one engine.
enum EngineChoice: Hashable {
    case automatic
    case engine(EngineKind)

    /// The `engine` value meaning Automatic.
    static let automaticID = "auto"

    /// nil for an id that isn't "auto" or a known engine.
    init?(id: String) {
        if id == Self.automaticID {
            self = .automatic
        } else if let kind = EngineKind(rawValue: id) {
            self = .engine(kind)
        } else {
            return nil
        }
    }

    /// What `config.json` stores.
    var id: String {
        switch self {
        case .automatic: return Self.automaticID
        case .engine(let kind): return kind.rawValue
        }
    }
}

/// The max dictation lengths offered in Settings, in seconds (0 = no limit).
enum DictationLimit {
    static let choices: [Double] = [120, 300, 600, 1800, 0]

    /// "10 min", "90 s", or "No limit" for `<= 0`.
    static func label(_ seconds: Double) -> String {
        guard seconds > 0 else { return "No limit" }
        let whole = Int(seconds.rounded())
        return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole) s"
    }
}
