import Foundation

/// A single problem found in a `Config`. Reporting only — see `ConfigValidator`.
struct ConfigIssue: Equatable {
    enum Severity { case error, warning }
    /// What it's about: Settings' Hotkeys section fixes `.hotkeys`; only
    /// the config file fixes `.engine`.
    enum Topic { case hotkeys, engine, dictationLanguage, meetingLanguage }
    let severity: Severity
    let topic: Topic
    /// For the log: names the config keys and values.
    let message: String
    /// For people (Settings, the menu): plain words, one sentence, with the
    /// names Settings shows ("Hold to talk", "Toggle to talk").
    let summary: String
}

/// Which issues are new since the last look, so each is logged once when
/// it appears (at launch, or later after a hand edit or a Settings change),
/// not on every menu refresh. One that goes away and comes back is new again.
struct ConfigIssueReporter {
    private var reported: [ConfigIssue] = []

    mutating func fresh(_ issues: [ConfigIssue]) -> [ConfigIssue] {
        let new = issues.filter { !reported.contains($0) }
        reported = issues
        return new
    }
}

/// Pure, side-effect-free validation of a `Config`. Detects invalid or
/// conflicting key bindings (plus a sanity check on max recording duration) so
/// the app can report them clearly at startup. It never mutates the config; it
/// only inspects and returns an ordered list of problems (errors first, then
/// warnings). The per-binding rules live in `KeyBinding`; this only phrases them.
/// It also warns about an `engine` that can't run here (`engines` and
/// `environment` are injectable for tests); the app runs whisper meanwhile.
enum ConfigValidator {
    static func validate(_ config: Config, engines: EngineRegistry = .shared,
                         environment: EngineEnvironment = .current) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []

        // error — hold and toggle resolve to the same chord, so both modes
        // would fire on the same key.
        if config.hold.isSameChord(as: config.toggle) {
            issues.append(ConfigIssue(
                severity: .error, topic: .hotkeys,
                message: "`hold` and `toggle` are the same binding (\(config.hold)); both modes would trigger on the same key.",
                summary: "\(Self.hold) and \(Self.toggle) use the same keys (\(config.hold))."))
        }

        // error — a binding with no key and no modifiers can never match.
        if config.hold.isUnmatchable {
            issues.append(ConfigIssue(
                severity: .error, topic: .hotkeys,
                message: "`hold` binding is empty (keyCode < 0 with no modifiers); it can never match.",
                summary: "\(Self.hold) has no keys set."))
        }
        if config.toggle.isUnmatchable {
            issues.append(ConfigIssue(
                severity: .error, topic: .hotkeys,
                message: "`toggle` binding is empty (keyCode < 0 with no modifiers); it can never match.",
                summary: "\(Self.toggle) has no keys set."))
        }

        // warning — the cancel (Esc) key shares a real key code with a binding.
        if config.hold.keyCode >= 0, config.cancelKeyCode == config.hold.keyCode {
            issues.append(ConfigIssue(
                severity: .warning, topic: .hotkeys,
                message: "`cancelKeyCode` (\(config.cancelKeyCode)) collides with the `hold` key code; cancel may shadow hold-to-talk.",
                summary: "\(Self.hold) uses the cancel key, so pressing it may cancel instead."))
        }
        if config.toggle.keyCode >= 0, config.cancelKeyCode == config.toggle.keyCode {
            issues.append(ConfigIssue(
                severity: .warning, topic: .hotkeys,
                message: "`cancelKeyCode` (\(config.cancelKeyCode)) collides with the `toggle` key code; cancel may shadow toggle.",
                summary: "\(Self.toggle) uses the cancel key, so pressing it may cancel instead."))
        }

        // warning — modifier names the runtime won't recognise (and so ignores).
        for name in config.hold.unknownModifiers {
            issues.append(ConfigIssue(
                severity: .warning, topic: .hotkeys,
                message: "`hold` has unknown modifier \"\(name)\"; it will be ignored.",
                summary: Self.unknownKey(name, in: Self.hold)))
        }
        for name in config.toggle.unknownModifiers {
            issues.append(ConfigIssue(
                severity: .warning, topic: .hotkeys,
                message: "`toggle` has unknown modifier \"\(name)\"; it will be ignored.",
                summary: Self.unknownKey(name, in: Self.toggle)))
        }

        // warning — an engine that's unknown, not in this build, or can't run
        // on this Mac. Not a language mismatch: that's a Settings choice, and
        // Settings explains that fallback itself. "auto" always runs.
        if config.engineChoice != .automatic,
           case .unavailable(let reason) = engines.availability(ofID: config.engine, in: environment) {
            issues.append(ConfigIssue(
                severity: .warning, topic: .engine,
                message: "`engine` \"\(config.engine)\": \(reason); using \(EngineKind.whisper.displayName).",
                summary: "The engine set in the config file can't run on this Mac, "
                    + "so Cado uses \(EngineKind.whisper.displayName)."))
        }

        // warning — a language code no engine knows ("hindi", "en-US"): whisper
        // would decode garbage. Dictation's is fixed on the Speech Model tab,
        // meetings' on the Meetings tab.
        if !Self.isKnownLanguage(config.language, allowSame: false) {
            issues.append(ConfigIssue(
                severity: .warning, topic: .dictationLanguage,
                message: "`language` \"\(config.language)\" isn't a language code (use e.g. \"en\", \"hi\" or \"auto\").",
                summary: "The dictation language in the config file (“\(config.language)”) isn't one Cado knows. "
                    + "Pick a language on the Speech Model tab."))
        }
        if !Self.isKnownLanguage(config.meetingLanguage, allowSame: true) {
            issues.append(ConfigIssue(
                severity: .warning, topic: .meetingLanguage,
                message: "`meetingLanguage` \"\(config.meetingLanguage)\" isn't a language code (use e.g. \"hi\", \"auto\" or \"same\").",
                summary: "The meeting language in the config file (“\(config.meetingLanguage)”) isn't one Cado knows. "
                    + "Pick a language on the Meetings tab."))
        }

        return issues
    }

    /// Empty, "auto", "same" (meetings only) or an ISO 639 language code
    /// (two or three letters, lower case, as whisper.cpp wants) — the codes
    /// the Settings pickers offer are all in it.
    static func isKnownLanguage(_ code: String, allowSame: Bool) -> Bool {
        if code.isEmpty || code == ModelSpec.autoDetect { return true }
        if allowSame, code.lowercased() == MeetingLanguageChoice.sameID { return true }
        let code = allowSame ? code.lowercased() : code   // meetings lower-case it; dictation doesn't
        guard code.count <= 3, code.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        return code == "jw" || Locale.LanguageCode(code).isISOLanguage
    }

    /// The hotkeys as Settings names them (its Hotkeys rows, the menu).
    static let hold = "Hold to talk"
    static let toggle = "Toggle to talk"

    private static func unknownKey(_ name: String, in hotkey: String) -> String {
        "\(hotkey) includes a key Cado doesn't recognize (“\(name)”), so it's ignored."
    }
}
