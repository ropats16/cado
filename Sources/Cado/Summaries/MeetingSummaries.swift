import Foundation

/// Reading a meeting note's transcript and writing its Summary section.
/// Real one: the note files (`DiskSummaryNoteFiles`). Called off main.
protocol SummaryNoteFiles: Sendable {
    func turns(of note: URL) throws -> [(speaker: MeetingSpeaker, text: String)]
    /// Puts `section` into the note in place of its Summary section (or
    /// before its transcript), changing nothing else. Throws
    /// `SummaryNoteError.changed` (writing nothing) if the note's transcript
    /// is no longer `turns`, the turns that were summarized.
    func writeSection(_ section: String, into note: URL, summarizing turns: [(speaker: MeetingSpeaker, text: String)]) throws
}

enum SummaryNoteError: LocalizedError, Equatable {
    case notAMeeting
    case notUTF8
    /// The transcript was edited while the summary was being written.
    case changed

    var errorDescription: String? {
        switch self {
        case .notAMeeting: return "Only meeting notes are summarized."
        case .changed: return "The note changed while it was being summarized. Try again."
        case .notUTF8: return "The note isn't saved as UTF-8 text, so Cado won't rewrite it."
        }
    }
}

/// The notes on disk. The rewrite re-reads the file right before writing
/// (an edit made meanwhile is kept), keeps the front matter byte for byte,
/// and replaces the file atomically: a crash leaves the old note or the new
/// one, never half of either.
struct DiskSummaryNoteFiles: SummaryNoteFiles {
    func turns(of note: URL) throws -> [(speaker: MeetingSpeaker, text: String)] {
        try Self.turns(in: try String(contentsOf: note, encoding: .utf8), of: note)
    }

    private static func turns(in text: String, of note: URL) throws -> [(speaker: MeetingSpeaker, text: String)] {
        let parsed = NoteFrontMatter.parse(text)
        guard NoteKind.isMeeting(parsed.value(for: "kind") ?? NoteKind.note) else { throw SummaryNoteError.notAMeeting }
        let summary = NoteSummary(id: note.lastPathComponent, title: "", date: Date(), kind: NoteKind.meeting,
                                  duration: nil, preview: "", url: note)
        return NoteReading(Note(summary: summary, body: parsed.body), calendar: .current).turns
            .map { (speaker: $0.speaker, text: $0.text) }
    }

    func writeSection(_ section: String, into note: URL, summarizing turns: [(speaker: MeetingSpeaker, text: String)]) throws {
        let bytes = try Data(contentsOf: note)
        let raw = String(decoding: bytes, as: UTF8.self)
        guard Data(raw.utf8) == bytes else { throw SummaryNoteError.notUTF8 }
        // Minutes may have passed: a turn deleted meanwhile must not live on in a summary.
        let now = try Self.turns(in: raw, of: note)
        guard now.map({ "\($0.speaker)|\($0.text)" }) == turns.map({ "\($0.speaker)|\($0.text)" }) else {
            throw SummaryNoteError.changed
        }
        let updated = Data(NoteText.replacingBody(of: raw) { SummarySection.applying(section, to: $0) }.utf8)
        if updated != bytes { try updated.write(to: note, options: .atomic) }
    }
}

/// A meeting note store that hands each saved note on for summarizing
/// (#34) once the save is done and the session has moved on: `saved` runs
/// on a later main-loop turn, so nothing about summaries can slow, fail or
/// reorder saving the note and journaling it (#31). A save that throws
/// hands nothing on.
final class SummarizingNoteStore: MeetingNoteStore {
    private let inner: MeetingNoteStore
    private let saved: (URL) -> Void
    private let later: (@escaping () -> Void) -> Void

    init(_ inner: MeetingNoteStore, later: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         saved: @escaping (URL) -> Void) {
        self.inner = inner
        self.later = later
        self.saved = saved
    }

    func save(_ draft: NoteDraft) throws -> URL {
        let url = try inner.save(draft)
        if NoteKind.isMeeting(draft.kind) {
            let saved = saved
            later { saved(url) }
        }
        return url
    }
}

/// Meeting summaries (#34): after a meeting note is saved, and when asked
/// (Regenerate in the Library), summarizes its transcript with the chosen
/// provider (`SummaryPipeline`) and writes the result into the note's
/// Summary section (`SummarySection`), in place.
///
/// Never in the way of the note: it runs after the note is saved
/// (`SummarizingNoteStore`), one note at a time, and a note it fails on is
/// left exactly as it was (a note without a summary is complete). Quitting
/// mid-summary loses only the summary; Regenerate adds it later.
///
/// Automatic summaries need Settings' switch (`Config.meetingSummaries`)
/// and an available provider; asking for one needs only the provider.
@MainActor
final class MeetingSummaries: ObservableObject {
    enum State: Equatable {
        case queued
        case working
        /// The last try failed: why, in plain words.
        case failed(String)
    }

    /// Notes being (or waiting to be) summarized, or whose last try failed.
    /// A note summarized fine has no entry.
    @Published private(set) var states: [URL: State] = [:]
    /// A note's Summary section was written (the Library reloads it).
    var onWritten: ((URL) -> Void)?

    private let catalog: SummarizerCatalog
    private let provider: () -> SummaryProvider
    private let automatic: () -> Bool
    /// The model that writes, for the note's attribution (cloud providers).
    private let model: () -> String?
    private let files: SummaryNoteFiles
    private let minimumAutomaticWords: Int
    private var queue: [URL] = []
    /// Queued notes that were queued by a save, not asked for.
    private var automaticNotes: Set<URL> = []
    private var running: Task<Void, Never>?

    /// `provider` and `automatic` are read live (Settings).
    /// Automatic runs skip transcripts under `minimumAutomaticWords` words
    /// (asking still works).
    init(catalog: SummarizerCatalog, provider: @escaping () -> SummaryProvider,
         automatic: @escaping () -> Bool, model: @escaping () -> String? = { nil },
         files: SummaryNoteFiles = DiskSummaryNoteFiles(), minimumAutomaticWords: Int = 40) {
        self.model = model
        self.minimumAutomaticWords = minimumAutomaticWords
        self.catalog = catalog
        self.provider = provider
        self.automatic = automatic
        self.files = files
    }

    /// Whether the chosen provider can run now (read live: Apple
    /// Intelligence can be switched off or still be getting ready).
    var availability: SummarizerAvailability { catalog.availability(of: provider()) }

    func state(of note: URL) -> State? { states[Self.key(note)] }

    /// A meeting note was just saved: summarize it if the switch is on and
    /// the provider can run (else nothing, quietly).
    func noteSaved(_ note: URL) {
        guard automatic() else { return Log.info("Summary: summaries are off; not summarizing \(note.lastPathComponent).") }
        guard availability.isAvailable else {
            return Log.info("Summary: not summarizing \(note.lastPathComponent): \(availability)")
        }
        enqueue(note, automatic: true)
    }

    /// Summarize (again) on request, replacing the note's summary.
    func summarize(_ note: URL) { enqueue(note, automatic: false) }

    /// Resolves once nothing is queued or running (tests).
    func settled() async {
        while let running { await running.value }
    }

    private func enqueue(_ note: URL, automatic: Bool) {
        let key = Self.key(note)
        if let state = states[key], state == .queued || state == .working { return }
        if automatic { automaticNotes.insert(key) } else { automaticNotes.remove(key) }
        states[key] = .queued
        queue.append(key)
        pump()
    }

    private func pump() {
        guard running == nil, !queue.isEmpty else { return }
        let note = queue.removeFirst()
        states[note] = .working
        running = Task { [weak self] in
            await self?.run(note)
            self?.running = nil
            self?.pump()
        }
    }

    private func run(_ note: URL) async {
        let provider = provider()
        guard let summarizer = catalog.summarizer(for: provider) else {
            let why = Self.describe(SummarizerError.unavailable(Self.reason(availability)))
            states[note] = .failed(why)
            return Log.info("Summary: \(note.lastPathComponent) not summarized: \(why)")
        }
        let files = files
        let started = Date()
        do {
            let turns = try await Task.detached { try files.turns(of: note) }.value
            if automaticNotes.remove(note) != nil,
               turns.reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) < minimumAutomaticWords {
                states[note] = nil
                return Log.info("Summary: \(note.lastPathComponent) is too short to summarize on its own.")
            }
            let outcome = try await SummaryPipeline(summarizer: summarizer).run(turns)
            let section = SummarySection.markdown(outcome, provider: provider, model: model())
            try await Task.detached { try files.writeSection(section, into: note, summarizing: turns) }.value
            states[note] = nil
            Log.info("Summary: wrote \(note.lastPathComponent)'s summary (\(outcome.passages) passage(s), "
                + "\(outcome.skippedPassages) left out) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s.")
            onWritten?(note)
        } catch {
            states[note] = .failed(Self.describe(error))
            Log.error("Summary: \(note.lastPathComponent) not summarized: \(error)")
        }
    }

    private static func reason(_ availability: SummarizerAvailability) -> SummarizerUnavailable {
        if case .unavailable(let reason) = availability { return reason }
        return .modelNotReady
    }

    /// Notes are keyed by their standardized file URL.
    private static func key(_ note: URL) -> URL { note.standardizedFileURL }

    /// What went wrong, for the Library.
    static func describe(_ error: Error) -> String {
        switch error {
        case SummarizerError.unavailable(let reason): return reason.explanation
        case SummarizerError.unsupportedLanguage, SummaryPipelineError.noPassageSummarized(.unsupportedLanguage):
            return "Summaries aren't available in this meeting's language yet."
        case SummaryPipelineError.noPassageSummarized(.refused), SummarizerError.refused:
            return "The summary couldn't be written: the model declined to summarize this meeting."
        case SummaryPipelineError.nothingToSummarize: return "There's nothing in this note's transcript to summarize yet."
        case let error as SummaryNoteError: return error.errorDescription ?? "The note couldn't be summarized."
        case let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile:
            return "The note was moved or deleted before it could be summarized."
        default: return "Couldn't summarize right now. Try again."
        }
    }
}
