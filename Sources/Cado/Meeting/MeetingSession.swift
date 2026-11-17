import Foundation

/// One meeting at a time, started and stopped only from the menu:
///
///     idle → recording → finishing → transcribing → idle
///
/// Recording runs two independent streams: the mic ("Me") and the chosen
/// app's audio ("Others", never the whole Mac's). Each batch a stream
/// delivers is appended to the meeting's spool (`MeetingSpool`, on disk) and
/// fed to that side's `StreamingSpeechChunker`; every speech chunk it
/// completes becomes a job, and jobs go one at a time, in the order they were
/// emitted, through the shared engine queue, their audio read back from the
/// spool. So most of the meeting is transcribed while it's still going: on
/// stop the streams end, the chunkers hand over the still-open chunk, the
/// jobs left run (the open tail, plus any backlog a slow Mac hasn't caught up
/// on), and the pieces are interleaved by start time into Me/Others turns
/// (`MeetingTranscript`) for a Markdown note in the notes library
/// (`MeetingNote`).
///
/// The spool is the last copy of the meeting. It also journals each side's
/// start, failure and loss, every chunk's transcript (or failure), how far
/// each side is settled, the stop, a quit, and once the meeting is written
/// down, `.noteSaved` (`SpoolEvent`). A spool with a folder on disk
/// (`hasFolder`: what's physically there, whatever write failed) is deleted
/// only once the note is saved (in the notes library, or the archive when
/// that fails) AND any audio that has to be kept was copied; until then it
/// stays on disk and a later launch finishes the job (`recoverLeftovers`,
/// `RecoveryPlan`):
/// - no `.noteSaved` (a crash, a quit, a note that couldn't be saved
///   anywhere): the meeting is rebuilt from the journal, the audio not yet
///   transcribed is chunked and transcribed the same way, and the note says
///   why it was finished later. This runs through the same states, shown as
///   `.recovering`, oldest leftover first.
/// - `.noteSaved` with an audio copy pending: only the copy is done again;
///   never a second note.
/// - A milestone the journal can't take (the disk is full) goes into the
///   folder's name instead (`SpoolFolderMark`, a rename in place: no space
///   needed): a note saved but not journaled marks it written down (the next
///   launch just deletes it) or audio pending (only the copy is redone, into
///   a new folder: the note's isn't known); a note that couldn't be saved
///   marks it so, and the late note says that, not "quit unexpectedly"; so
///   does a quit (#48). Recovery reads marks as the events they stand for
///   and journals them (the name goes back to plain) once the journal takes
///   events again. An attempt the journal can't count is marked `.tried`,
///   once, and its start is journaled before anything else of it once the
///   journal takes events (`RecoverySpoolHandle`); another, or a give-up it
///   can't journal, waits for a launch with room, once (`.waited`): a full
///   disk never switches off the crash-loop guard. Still full the launch
///   after, or a journal Cado can't write at all, sets it aside, told once.
/// - A note carries its meeting's id (#48): a leftover without `.noteSaved`
///   whose note is in the notes folder anyway (Cado died in between) adopts
///   it, looked for off main; never a second note. Only a whole note, and
///   never after a save that failed (it may have left part of one): then the
///   note is written afresh. An adopted note's audio is always kept.
/// - A folder without its details (no readable meeting.json) has its audio
///   kept as WAVs, the folder itself moved in beside them: never deleted.
/// - Recovery that gives up journals `.recoveryGaveUp` before writing the
///   note. A leftover that has it with no outcome after (Cado died writing
///   that note) isn't tried again: its folder is moved, as it is, into the
///   archive and the user is told once where (`putAside`). Never deleted.
/// - Only a spool with no folder (the disk spool couldn't be made: all in
///   memory) is dropped when its note can't be saved anywhere; the notice
///   says the meeting is lost.
/// - "The meeting is safe" is said once per meeting (`.toldUser`); if even
///   that can't be journaled, a later launch says it again.
///
/// Half on disk (`FallbackSpoolHandle`: the disk filled up mid-meeting, the
/// rest is in memory): the note is written from both parts. Once it's
/// saved, `.noteSaved` goes to the part on disk (or its mark), so a later
/// launch never writes a second, partial note; it names no audio folder, so
/// a pending copy is redone from the disk part into a folder of its own,
/// never over the complete copy. Until the note is saved the disk part is
/// never deleted; if Cado dies first, the next launch recovers it: a partial
/// note is the most there is. Quitting writes such a meeting down at once
/// (the memory part can't wait), journaled the same way.
///
/// Rules worth knowing:
/// - Start is ignored unless idle or recovering. During a recovery it holds
///   the recovery at a chunk boundary (`hold`, #48) and records at once; the
///   recovery goes on once the new meeting is written down. Stop only while
///   recording.
/// - Recording stops by itself at `maxSeconds` (read at start; nil = Off,
///   which still stops at `MeetingLimit.backstopSeconds`), with a notice;
///   the note is still written and says so.
/// - Memory: neither the session nor the captures (`retainsSamples: false`)
///   keep the meeting's audio: it is on disk in the spool, read back one
///   chunk (at most `maxChunkSeconds`) or one recovery slice at a time. What
///   is held is bounded: the chunkers' state, the job ranges, the pieces of
///   text. Only if the spool can't be made, or the disk stops taking audio
///   mid-meeting, is (the rest of) the audio held in memory instead, ~230 MB
///   an hour per side, so the meeting still gets its note.
/// - Slow file work runs off the main thread (`background`): copying audio
///   to the archive, and the silence scan of a reopened Others side.
/// - Each stream's samples stay on its own wall-clock timeline: a source
///   restart mid-meeting is kept as silence (`AudioCapture`'s `keepsTime`),
///   so a chunk's offset is the stream's origin plus its sample position.
/// - A side that can't start, or stops by itself, gets a notice and a caveat
///   in the note; the other side keeps recording, and a lost side's last
///   chunk is transcribed at once. With no side left recording, the meeting
///   stops.
/// - An Others stream that was silent throughout gets the readiness module's
///   hint (the permission may not be granted) in the note and the notice,
///   unless this run already proved the grant; `lastThemWasSilent` lets the
///   menu offer the Settings pane afterwards.
/// - Chunks go to the engine one at a time, so a dictation waits for at most
///   one chunk. Dictation is refused while recording (`blocksDictation`).
/// - Engine model lifetime: no `prewarm` while recording. Each chunk is a
///   job, which restarts the engine's idle clock, so the model stays loaded
///   while people talk and is unloaded (by the user's "keep model loaded"
///   setting) only after minutes without a chunk; the next chunk reloads it.
///   On stop the engine is prewarmed for the tail, and `endPrewarm` balances
///   it if no job followed.
/// - Language (#47): `meetingLanguage` is read at start into the spool
///   (`SpooledMeeting.language`); every job and the tail's prewarm carry
///   it, a recovery too, so the engine (`MeetingModelRouter`) picks the
///   model for it.
/// - A meeting where no speech was transcribed writes no note; a notice says
///   so. Failed chunks don't lose the meeting: the note keeps what was
///   transcribed, and the audio is kept (`MeetingArchive`). The note names
///   its folder only when all the audio is on disk (so it's there, or still
///   in the spool for the next launch to copy); audio held in memory could
///   still be lost, so a notice names the folder once it's there.
///   A note the notes library won't take goes to the archive with the audio.
/// - Retention: with `keepAudio` (read when the meeting ends) the audio is
///   copied to the archive, also when nothing was said. Failures and a note
///   that couldn't be saved keep the audio whatever the setting.
/// - `quit` (the app is quitting) stops the streams, journals the quit and
///   leaves the spool: the next launch writes the complete note. Only a
///   meeting with audio held in memory is written down on the way out, with
///   what there is, its audio kept. Quitting during a recovery pauses it
///   (`.recoveryPaused`, not counted as a failed attempt).
/// - Each meeting (recovered ones too) gets an id; callbacks for any other
///   meeting are ignored.
/// - Calendar title (#38): looked up once recording is under way, never
///   before. An answer that comes before the note is written names it and is
///   journaled (`.calendarEvent`), so a recovery names it the same way; a
///   later answer, none, or none in time keeps the app and time. Logs never
///   carry the title (nor paths, which contain it).
///
/// Main-thread only.
final class MeetingSession {
    /// The cap on one meeting unless set (Settings › Meetings).
    static let defaultMaxSeconds: TimeInterval = MeetingLimit.defaultMinutes * 60

    static let dictationNotice = DictationBusyNotice(
        title: "Meeting recording",
        body: "Dictation is off while a meeting records. Stop the recording from the Cado menu first.")

    /// Recovery reads a side back this many samples at a time (30 s), one
    /// slice per side per main-loop turn.
    static let recoverySliceSamples = 30 * 16_000
    /// Between chunks, a side's `.settled` is journaled once it has moved
    /// this far (5 s); after every chunk and result, whenever it moved.
    static let settledJournalStep = 5 * 16_000

    private final class Side {
        let speaker: MeetingSpeaker
        /// Nil for a recovered meeting.
        let stream: MeetingStream?
        /// Seconds after the meeting's start when the stream started.
        var origin: TimeInterval?
        var startError: String?
        /// Seconds after the meeting's start when the source stopped by itself.
        var lostAt: TimeInterval?
        /// No more audio is coming: the stream ended (or never started) and
        /// the chunker has been finished.
        var ended = false
        var chunker = StreamingSpeechChunker()
        /// The chunker was finished early (the source was lost).
        var chunkerFinished = false
        /// The spool index of the chunker's first sample (a recovery picks up
        /// where the journal left off).
        var base = 0
        /// Recovery: the next spool index to read back.
        var cursor = 0
        /// The last `.settled` journaled for this side.
        var journaledSettled = 0
        /// Under Auto-detect, the language last detected on a long passage
        /// of this side, for its short ones (`PassageLanguage`, #47).
        var lastLanguage: String?
        var isLive: Bool { startError == nil && lostAt == nil }
        init(_ speaker: MeetingSpeaker, _ stream: MeetingStream?) {
            self.speaker = speaker
            self.stream = stream
        }
    }

    private struct Job {
        let speaker: MeetingSpeaker
        /// Spool sample indices.
        let range: Range<Int>
        /// Seconds from the meeting's start.
        let offset: TimeInterval
        var duration: TimeInterval { Double(range.count) / AudioCapture.sampleRate }
    }

    private final class Meeting {
        let id: Int
        let appName: String
        let startedAt: TimeInterval
        let startDate: Date
        let spool: MeetingSpoolHandle
        let sides: [MeetingSpeaker: Side]
        /// Rebuilt from a leftover spool: why it wasn't finished then.
        let recovery: RecoveryPlan.Reason?
        var isRecovery: Bool { recovery != nil }
        var stoppedAt: TimeInterval?
        /// A recovered meeting's length: the stop's, else the audio on disk.
        var recoveredDuration: TimeInterval = 0
        var capReached = false
        /// The length it stops at (live meetings; 0 for a recovered one).
        var cap: TimeInterval = 0
        var quit: (() -> Void)?
        /// Emitted, not yet submitted, in emission order.
        var queue: [Job] = []
        var inFlight: Job?
        var total = 0
        var done = 0
        var pieces: [MeetingTranscript.Piece] = []
        var failures: [String] = []
        /// Recovery couldn't go on (why); the note has what there is.
        var gaveUp: String?
        /// Recovery: whether the reopened Others side is all zeros, found
        /// off main; nil until known.
        var themAllZero: Bool?
        /// `engine.prewarm()` was called and no job has been submitted since.
        var prewarmed = false
        /// The user was told the spool stopped taking audio.
        var toldSpoolFailed = false
        /// An earlier launch said "the meeting is safe" (`.toldUser`).
        var toldMeetingIsSafe = false
        /// A recovery held for a meeting the user started (#48): nothing more
        /// is submitted until it's resumed.
        var onHold = false
        /// A passage ran on a model that can't write the meeting's language
        /// (`.ranOnFallbackModel`, #47): the note says so.
        var ranOnFallbackModel = false
        /// The calendar event it's named after (#38): found after the start
        /// (`calendarEventFound`), or journaled by an earlier launch.
        var event: MatchedEvent?

        init(id: Int, appName: String, startedAt: TimeInterval, startDate: Date, spool: MeetingSpoolHandle,
             me: MeetingStream?, them: MeetingStream?, recovery: RecoveryPlan.Reason? = nil) {
            self.id = id
            self.appName = appName
            self.startedAt = startedAt
            self.startDate = startDate
            self.spool = spool
            self.recovery = recovery
            sides = [.me: Side(.me, me), .them: Side(.them, them)]
        }

        func side(_ speaker: MeetingSpeaker) -> Side { sides[speaker]! }
        var duration: TimeInterval { isRecovery ? recoveredDuration : (stoppedAt ?? startedAt) - startedAt }
        var allEnded: Bool { sides.values.allSatisfy(\.ended) }
        var hasNoWork: Bool { inFlight == nil && queue.isEmpty }
    }

    private enum State {
        case idle
        case recording(Meeting)
        /// Stopped; waiting for the streams' last samples. For a recovery:
        /// reading the spool back.
        case finishing(Meeting)
        case transcribing(Meeting)
    }

    /// A chunk whose audio couldn't be read back from the spool.
    private struct AudioUnreadable: LocalizedError {
        var errorDescription: String? { "Its recorded audio couldn't be read back." }
    }

    private struct NoFolder: LocalizedError {
        var errorDescription: String? { "The Meeting Audio folder couldn't be made." }
    }

    private let recorder: MeetingRecorder
    private let engine: MeetingEngine
    private let notes: MeetingNoteStore
    private let archive: MeetingArchive
    private let spooling: MeetingSpooling
    private let feedback: MeetingFeedback
    private let activity: MeetingActivity
    private let clock: Clock
    private let date: () -> Date
    private let systemAudioPermission: () -> SystemAudioPermission
    private let keepAudio: () -> Bool
    /// The language a meeting started now is decoded in (#47), recorded in its spool.
    private let meetingLanguage: () -> String?
    private let later: (@escaping () -> Void) -> Void
    private let background: (@escaping () -> Void, @escaping () -> Void) -> Void
    private let locale: Locale
    private let timeZone: TimeZone
    private let calendarNaming: MeetingCalendarNaming   // #38
    private let maxSeconds: () -> TimeInterval?

    private var state: State = .idle
    private var timer: ClockTimer?
    private var meetingCount = 0
    /// `recoverLeftovers` was called; the leftovers are listed when idle.
    private var recoveryRequested = false
    private var leftovers: [LeftoverMeeting] = []
    /// A recovery held while a meeting the user started records and is
    /// written down (#48); resumed after it.
    private var held: Meeting?
    /// A leftover's note is being looked for off main (#48): nothing else
    /// recovers meanwhile.
    private var lookingForNote = false
    /// What's next for that leftover once it's found (or not): run when idle.
    private var afterLookup: (() -> Void)?
    private var isQuitting = false
    /// Audio copies under way whose source lives only in memory: quitting
    /// waits for them (an on-disk spool's copy is just redone next launch).
    private var fragileCopies = 0
    private var quitWaiters: [() -> Void] = []
    private(set) var status: MeetingStatus = .idle
    /// The last finished meeting's Them stream was silent while the grant
    /// was unproven: the menu offers the Settings pane
    /// (`SystemAudioReadiness.issue(for:lastMeetingThemSilent:)`).
    private(set) var lastThemWasSilent = false

    /// `spool` keeps each meeting's audio and journal on disk (the app: a
    /// `FolderMeetingSpool`); if it can't make one, the meeting is kept in
    /// memory instead. `systemAudioPermission` is read when a meeting ends,
    /// to tell a silent Others apart from an unconfirmed permission;
    /// `keepAudio` (Settings › Meetings › Keep meeting audio) too. `later` runs
    /// the next step of a recovery's read-back on a later main-loop turn;
    /// `background` runs slow file work off main, then its completion on main.
    init(recorder: MeetingRecorder, engine: MeetingEngine, notes: MeetingNoteStore, archive: MeetingArchive,
         spool: MeetingSpooling, feedback: MeetingFeedback, activity: MeetingActivity, clock: Clock = SystemClock(),
         date: @escaping () -> Date = Date.init,
         systemAudioPermission: @escaping () -> SystemAudioPermission,
         keepAudio: @escaping () -> Bool = { false },
         meetingLanguage: @escaping () -> String? = { nil },
         maxSeconds: @escaping () -> TimeInterval? = { MeetingSession.defaultMaxSeconds },
         locale: Locale = .current, timeZone: TimeZone = .current,
         calendarNaming: MeetingCalendarNaming = .off,
         later: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) },
         background: @escaping (@escaping () -> Void, @escaping () -> Void) -> Void = { work, done in
             DispatchQueue.global(qos: .utility).async {
                 work()
                 DispatchQueue.main.async(execute: done)
             }
         }) {
        self.recorder = recorder
        self.engine = engine
        self.notes = notes
        self.archive = archive
        self.spooling = spool
        self.feedback = feedback
        self.activity = activity
        self.clock = clock
        self.date = date
        self.systemAudioPermission = systemAudioPermission
        self.keepAudio = keepAudio
        self.meetingLanguage = meetingLanguage
        self.maxSeconds = maxSeconds
        self.locale = locale
        self.timeZone = timeZone
        self.calendarNaming = calendarNaming
        self.later = later
        self.background = background
    }

    /// Recording (or about to stop): the mic is the meeting's, so a dictation
    /// press is refused with `dictationNotice` (dictation during meetings: #33).
    var blocksDictation: Bool {
        switch state {
        case .recording: return true
        case .finishing(let m): return !m.isRecovery
        case .idle, .transcribing: return false
        }
    }

    /// `dictationNotice` while `blocksDictation`: `DictationSession`'s `busy`.
    var dictationBusy: DictationBusyNotice? { blocksDictation ? Self.dictationNotice : nil }

    // MARK: - Intents

    func start(_ app: MeetingApp) {
        if let recovering = current, recovering.isRecovery, !isQuitting { hold(recovering) }
        guard case .idle = state, !isQuitting else { return }
        meetingCount += 1
        let id = meetingCount
        let startDate = date()
        let spool = makeSpool(SpooledMeeting(id: UUID(), appName: app.name, appBundleID: app.bundleID,
                                             startDate: startDate, language: meetingLanguage()))
        let cap = MeetingLimit.cap(seconds: maxSeconds())
        let streams = recorder.streams(for: app, maxSeconds: cap)
        let meeting = Meeting(id: id, appName: app.name, startedAt: clock.now, startDate: startDate, spool: spool,
                              me: streams.me, them: streams.them)
        meeting.cap = cap
        state = .recording(meeting)
        Log.info("Meeting recording started: \(app.name) (\(app.bundleID)) and the microphone.")
        timer = clock.schedule(after: cap) { [weak self] in self?.capReached(id) }
        report()
        for speaker in MeetingSpeaker.allCases {
            guard let stream = meeting.side(speaker).stream else { continue }
            stream.onSourceLost = { [weak self] in self?.lost(id, speaker) }
            stream.onSamples = { [weak self] samples in self?.received(id, speaker, samples) }
            stream.begin { [weak self] error in self?.started(id, speaker, error) }
        }
        // After the recording is under way: the calendar never holds it up.
        calendarNaming.lookUp(forMeetingStartingAt: startDate) { [weak self] event in
            self?.calendarEventFound(id, event)
        }
    }

    /// The calendar's answer (#38): kept, and journaled so a recovery names
    /// the note the same way. Dropped once the note is written (the meeting
    /// is over: it keeps the app and time), or for nothing found.
    private func calendarEventFound(_ id: Int, _ event: MatchedEvent?) {
        guard let event, let meeting = meeting(id), !meeting.isRecovery, meeting.event == nil else { return }
        meeting.event = event
        meeting.spool.record(.calendarEvent(event))   // not journaled (disk full): a recovery uses the app and time
    }

    func stop() {
        guard case .recording(let meeting) = state else { return }
        Log.info("Meeting recording stopped after \(MeetingNote.clock(clock.now - meeting.startedAt)).")
        finish(meeting)
    }

    /// The app is quitting: stop the streams, journal the quit and leave the
    /// spool for the next launch, then `done` (a meeting held only in memory
    /// is written down first). A recovery under way pauses at once.
    func quit(_ done: @escaping () -> Void) {
        isQuitting = true
        leftovers = []
        afterLookup = nil   // its leftover is untouched: the next launch looks again
        recoveryRequested = false
        if let recovery = held {
            held = nil
            if recovery.inFlight != nil { journalPause(recovery.spool) }   // else journaled when it was held
        }
        switch state {
        case .idle:
            whenCopiesAreSafe(done)
        case .finishing(let meeting) where meeting.isRecovery, .transcribing(let meeting) where meeting.isRecovery:
            Log.info("Meeting recovery: Cado is quitting; the meeting with \(meeting.appName) goes on next launch.")
            journalPause(meeting.spool)
            end()
            whenCopiesAreSafe(done)
        case .recording(let meeting):
            journalQuit(meeting)
            meeting.quit = done
            finish(meeting)
        case .finishing(let meeting):
            journalQuit(meeting)
            meeting.quit = done
        case .transcribing(let meeting):
            journalQuit(meeting)
            meeting.quit = done
            leaveForNextLaunch(meeting)
        }
    }

    /// `.appQuit`; if the journal can't take it (the disk is full), the
    /// folder's name says it (#48), so the late note says Cado was quit, not
    /// that it quit unexpectedly.
    private func journalQuit(_ meeting: Meeting) {
        let spool = meeting.spool
        guard spool.hasFolder, !spool.record(.appQuit) else { return }
        if !spool.setMarks(spool.folderMarks.union([.quit])) {
            Log.error("Meeting: couldn't note in the spool that Cado was quit; the late note will say it quit unexpectedly.")
        }
    }

    /// A clean quit (or hold) during a recovery doesn't count against it
    /// (`.recoveryPaused`); with the journal full, the attempt's mark goes.
    /// Journaled, a `.tried` a failed rename left goes too (the start is in
    /// the journal: the mark would be read as a second, empty attempt).
    /// `forLiveMeeting` (a hold): the pause's flush to the disk runs in the
    /// background (`recordFlushingLater`), so the meeting being recorded is
    /// never held up by it.
    ///
    /// What that costs the crash-loop guard: nothing new. A power cut in the
    /// few milliseconds before that flush is done loses the pause, as it did
    /// while the flush ran on main before recording began (the window is the
    /// flush itself, wherever it runs); the next launch can't tell the two
    /// meetings' journals apart either way (each spool is folded alone), so
    /// that attempt counts as stalled only if it got nowhere (no passage
    /// back, no settled point moved), and it takes two for a give-up, which
    /// still writes the note and keeps the audio.
    private func journalPause(_ spool: MeetingSpoolHandle, forLiveMeeting: Bool = false) {
        _ = forLiveMeeting ? spool.recordFlushingLater(.recoveryPaused) : spool.record(.recoveryPaused)
        endAttemptMark(spool)   // either way
    }

    /// Recovers the meetings earlier runs left unfinished (crashed, killed,
    /// lost power, quit mid-meeting, couldn't save the note), oldest first,
    /// one at a time. Call when Cado can transcribe. While a meeting is under
    /// way nothing happens until it's over (its own spool is locked, never a
    /// leftover).
    func recoverLeftovers() {
        guard !isQuitting else { return }
        recoveryRequested = true
        startNextRecovery()
    }

    // MARK: - Recording

    private var current: Meeting? {
        switch state {
        case .idle: return nil
        case .recording(let m), .finishing(let m), .transcribing(let m): return m
        }
    }

    private func meeting(_ id: Int) -> Meeting? {
        current.flatMap { $0.id == id ? $0 : nil }
    }

    /// The spool for a new meeting; in memory (with a log line) if the
    /// on-disk one can't be made: recording never fails over it.
    private func makeSpool(_ info: SpooledMeeting) -> MeetingSpoolHandle {
        do {
            return FallbackSpoolHandle(try spooling.create(info))
        } catch {
            Log.error("Meeting: couldn't keep the recording on disk (\(error.localizedDescription)); "
                      + "this meeting is held in memory and can't be recovered if Cado quits unexpectedly.")
            return InMemorySpoolHandle(info)
        }
    }

    private func started(_ id: Int, _ speaker: MeetingSpeaker, _ error: Error?) {
        guard let meeting = meeting(id), !meeting.isRecovery else { return }
        let side = meeting.side(speaker)
        guard !side.ended, side.startError == nil else { return }
        guard let error else {
            if side.origin == nil { setOrigin(side, meeting) }
            return
        }
        Log.error("Meeting: couldn't record \(describe(speaker, meeting)): \(error.localizedDescription)")
        side.startError = error.localizedDescription
        side.ended = true
        meeting.spool.record(.sideFailed(speaker, reason: error.localizedDescription))
        feedback.notify(title: "Couldn't record \(describe(speaker, meeting))", body: error.localizedDescription)
        sideStopped(meeting)
    }

    private func setOrigin(_ side: Side, _ meeting: Meeting) {
        let origin = clock.now - meeting.startedAt
        side.origin = origin
        meeting.spool.record(.sideStarted(side.speaker, origin: origin))
    }

    /// A stream's next samples: to the spool, then through its chunker.
    private func received(_ id: Int, _ speaker: MeetingSpeaker, _ samples: [Float]) {
        guard let meeting = meeting(id), !meeting.isRecovery, !samples.isEmpty else { return }
        switch state {
        case .recording, .finishing: break
        case .idle, .transcribing: return
        }
        let side = meeting.side(speaker)
        guard !side.ended else { return }
        if side.origin == nil { setOrigin(side, meeting) }
        if side.chunkerFinished {
            // Audio after a loss (shouldn't happen): a fresh chunker from here.
            side.chunker = StreamingSpeechChunker()
            side.base = meeting.spool.sampleCount(of: speaker)
            side.chunkerFinished = false
        }
        meeting.spool.append(samples, for: speaker)
        checkSpool(meeting)
        queueChunks(side.chunker.append(samples), of: side, meeting)
    }

    /// The disk stopped taking the meeting's audio (full, folder gone): the
    /// spool now holds the rest in memory, so the meeting and its note go
    /// on; only crash recovery is lost. Said once. A journal append that
    /// failed alone loses nothing a recovery needs: not said.
    private func checkSpool(_ meeting: Meeting) {
        guard !meeting.toldSpoolFailed, let error = meeting.spool.writeError,
              !meeting.spool.hasAllAudioOnDisk else { return }
        meeting.toldSpoolFailed = true
        Log.error("Meeting: the on-disk recording failed (\(error.localizedDescription)); "
                  + "the rest of the meeting is held in memory and can't be recovered if Cado quits unexpectedly.")
        feedback.notify(title: "Meeting audio isn't being saved to disk",
                        body: "Your Mac's disk may be full. Cado keeps recording and will still write the note, "
                            + "but if Cado quits unexpectedly, this meeting can't be recovered.")
    }

    private func lost(_ id: Int, _ speaker: MeetingSpeaker) {
        guard let meeting = meeting(id), case .recording = state else { return }
        let side = meeting.side(speaker)
        guard side.isLive else { return }
        let at = clock.now - meeting.startedAt
        side.lostAt = at
        meeting.spool.record(.sideLost(speaker, at: at))
        Log.error("Meeting: \(describe(speaker, meeting)) stopped recording by itself.")
        let other = speaker == .me ? "\(meeting.appName)'s audio" : "your microphone"
        feedback.notify(title: "\(describe(speaker, meeting).capitalizedFirst) stopped recording",
                        body: "Cado keeps recording \(other); the note will say where it stopped.")
        // Every sample came before the loss: its last chunk can go now.
        side.chunkerFinished = true
        queueChunks(side.chunker.finish(), of: side, meeting)
        sideStopped(meeting)
    }

    /// With no side left recording, the meeting is over.
    private func sideStopped(_ meeting: Meeting) {
        report()
        guard case .recording = state, !meeting.sides.values.contains(where: \.isLive) else { return }
        finish(meeting)
    }

    private func capReached(_ id: Int) {
        guard let meeting = meeting(id), case .recording = state else { return }
        Log.info("Meeting reached the \(MeetingNote.hours(meeting.cap)) limit; stopping.")
        meeting.capReached = true
        finish(meeting)
        let setting = meeting.cap == MeetingLimit.backstopSeconds ? "" : " You can change this in Settings › Meetings."
        feedback.notify(title: "Meeting recording stopped",
                        body: "Meetings are recorded for up to \(MeetingLimit.phrase(meeting.cap)).\(setting) The note is being written.")
    }

    private func finish(_ meeting: Meeting) {
        timer?.cancel()
        timer = nil
        meeting.stoppedAt = clock.now
        meeting.spool.record(.stopped(at: meeting.duration, capReached: meeting.capReached))
        state = .finishing(meeting)
        report()
        if meeting.quit == nil {
            // Reload an idle-unloaded model for the tail while the streams finish.
            engine.prewarm(language: meeting.spool.meeting.language)
            meeting.prewarmed = true
        }
        for speaker in MeetingSpeaker.allCases where !meeting.side(speaker).ended {
            meeting.side(speaker).stream?.end { [weak self] in self?.streamEnded(meeting.id, speaker) }
        }
        transcribeRestOnceAllSidesEnded(meeting)
    }

    /// Every sample of the stream has been delivered.
    private func streamEnded(_ id: Int, _ speaker: MeetingSpeaker) {
        guard let meeting = meeting(id), case .finishing = state else { return }
        let side = meeting.side(speaker)
        guard !side.ended else { return }
        endSide(side, meeting)
        transcribeRestOnceAllSidesEnded(meeting)
    }

    /// No more audio for `side`: its chunker hands over the open chunk.
    private func endSide(_ side: Side, _ meeting: Meeting) {
        side.ended = true
        queueChunks(side.chunker.finish(), of: side, meeting)
        // A tail of silence settles too, so a later launch can tell nothing was left (`RecoveryPlan.mayAdoptNote`).
        journalSettled(side, meeting, force: true)
    }

    private func transcribeRestOnceAllSidesEnded(_ meeting: Meeting) {
        guard case .finishing(let m) = state, m === meeting, meeting.allEnded else { return }
        if meeting.quit != nil { return leaveForNextLaunch(meeting) }
        state = .transcribing(meeting)
        report()
        let left = meeting.queue.count + (meeting.inFlight == nil ? 0 : 1)
        Log.info("Meeting: \(left) of \(meeting.total) passage(s) left to transcribe.")
        completeIfDone(meeting)
    }

    // MARK: - Transcription

    // Exactly once after a crash. Per side, the journal's last `.settled`
    // (S) never passes the start of a chunk that isn't transcribed yet:
    // `journalSettled` journals min(the chunker's `settledThrough`, the
    // start of that side's first queued or in-flight job), and only after
    // newly emitted chunks are queued. Both terms only grow (no chunk starts
    // before `settledThrough`), so every chunk not done when Cado dies —
    // still in the chunker, queued, in flight, or answered but not yet
    // journaled — starts at or after S. A result is journaled
    // (`.transcribed`/`.failed`) before S moves past its chunk. Jobs run in
    // emission order, so per side results are journaled in order, and every
    // chunk ending at or before the last journaled result's end (E) is done.
    // Recovery takes each journaled result once and chunks again from
    // max(S, E) (`RecoveryPlan`): nothing before that point is pending, and
    // nothing journaled lies after it, so each stretch of speech is
    // transcribed exactly once whichever step the crash interrupted. And once
    // the note is saved, `.noteSaved` is journaled before anything else, so
    // a crash after it never writes a second note.

    /// Queues the chunks a side's chunker emitted and journals its progress.
    private func queueChunks(_ chunks: [SpeechChunker.Chunk], of side: Side, _ meeting: Meeting) {
        let origin = side.origin ?? 0
        for chunk in chunks {
            let range = (side.base + chunk.start)..<(side.base + chunk.end)
            meeting.queue.append(Job(speaker: side.speaker, range: range,
                                     offset: origin + Double(range.lowerBound) / AudioCapture.sampleRate))
        }
        meeting.total += chunks.count
        journalSettled(side, meeting, force: !chunks.isEmpty)
        submitNext(meeting)
    }

    private func journalSettled(_ side: Side, _ meeting: Meeting, force: Bool) {
        var safe = side.base + side.chunker.settledThrough
        if let job = meeting.inFlight, job.speaker == side.speaker { safe = min(safe, job.range.lowerBound) }
        if let job = meeting.queue.first(where: { $0.speaker == side.speaker }) { safe = min(safe, job.range.lowerBound) }
        guard safe > side.journaledSettled,
              force || safe - side.journaledSettled >= Self.settledJournalStep else { return }
        side.journaledSettled = safe
        meeting.spool.record(.settled(side.speaker, through: safe))
    }

    /// Submits the next job unless one is in flight (or Cado is quitting).
    /// A job whose audio can't be read back counts as failed at once.
    private func submitNext(_ meeting: Meeting) {
        while meeting.inFlight == nil, meeting.quit == nil, !meeting.onHold, !meeting.queue.isEmpty {
            let job = meeting.queue.removeFirst()
            let samples: [Float]
            do {
                samples = try meeting.spool.samples(job.range, of: job.speaker)
            } catch {
                Log.error("Meeting: couldn't read a passage back: \(error.localizedDescription)")
                recordResult(.failure(AudioUnreadable()), of: job, meeting)
                continue
            }
            meeting.inFlight = job
            meeting.prewarmed = false
            let id = meeting.id
            let language = meeting.spool.meeting.language
            let hint = PassageLanguage.hint(meetingLanguage: language, duration: job.duration,
                                            lastDetected: meeting.side(job.speaker).lastLanguage)
            let passage = MeetingPassageJob(meeting: meeting.spool.meeting.id, language: language, hint: hint)
            engine.transcribe(samples, passage: passage) { [weak self] result in
                self?.transcribed(id, result)
            }
        }
    }

    private func transcribed(_ id: Int, _ result: Result<MeetingPassage, Error>) {
        if let recovery = held, recovery.id == id, let job = recovery.inFlight {
            // The held recovery's last passage: journaled, then the pause (a chunk boundary).
            recovery.inFlight = nil
            recordPassage(result, of: job, recovery)
            return journalPause(recovery.spool, forLiveMeeting: true)
        }
        guard let meeting = meeting(id), let job = meeting.inFlight else { return }
        meeting.inFlight = nil
        recordPassage(result, of: job, meeting)
        submitNext(meeting)
        completeIfDone(meeting)
    }

    /// A passage back from the engine: its side's detected language
    /// remembered (#47), its result recorded, then the fallback-model caveat
    /// journaled (once per meeting).
    private func recordPassage(_ result: Result<MeetingPassage, Error>, of job: Job, _ meeting: Meeting) {
        if case .success(let passage) = result {
            let language = meeting.spool.meeting.language
            if PassageLanguage.remembers(meetingLanguage: language, duration: job.duration),
               passage.detected, let detected = passage.transcript.language {
                meeting.side(job.speaker).lastLanguage = detected
            }
        }
        recordResult(result.map(\.transcript), of: job, meeting)
        // After the passage's own result: a crash between would otherwise redo it, maybe on the proper model, with the line.
        if case .success(let passage) = result, passage.onFallbackModel, !meeting.ranOnFallbackModel {
            meeting.ranOnFallbackModel = true
            meeting.spool.record(.ranOnFallbackModel)   // if this fails, only a recovered note misses the line
        }
    }

    /// A job's result: into the pieces (or failures) and the journal, before
    /// its side's `.settled` may move past it.
    private func recordResult(_ result: Result<Transcript, Error>, of job: Job, _ meeting: Meeting) {
        meeting.done += 1
        switch result {
        case .success(let transcript):
            let segments = NonSpeechFilter.filter(transcript.segments)
            for segment in segments {
                meeting.pieces.append(.init(speaker: job.speaker, start: job.offset + segment.start, text: segment.text,
                                            end: job.offset + segment.end))
            }
            meeting.spool.record(.transcribed(job.speaker, range: job.range, offset: job.offset, segments: segments.map {
                SpoolSegment(start: $0.start, text: $0.text, end: $0.end)
            }))
        case .failure(let error):
            Log.error("Meeting: a passage failed to transcribe: \(error.localizedDescription)")
            meeting.failures.append(error.localizedDescription)
            meeting.spool.record(.failed(job.speaker, range: job.range, reason: error.localizedDescription))
        }
        journalSettled(meeting.side(job.speaker), meeting, force: true)
        if !meeting.isRecovery { checkSpool(meeting) }
        report()
    }

    /// Transcribing, nothing left to run, and (recovery) the silence scan in.
    private func completeIfDone(_ meeting: Meeting) {
        guard case .transcribing(let m) = state, m === meeting, meeting.hasNoWork else { return }
        guard !meeting.isRecovery || meeting.themAllZero != nil else { return }
        complete(meeting)
    }

    // MARK: - Writing the note

    /// Writes the meeting down. The spool goes only once the note is saved
    /// (`.noteSaved` journaled first) and any audio that must be kept is
    /// copied; otherwise it stays for the next launch.
    private func complete(_ meeting: Meeting) {
        endPrewarmIfHeld(meeting)
        let silence = themSilence(meeting)
        if !meeting.isRecovery { lastThemWasSilent = silence != nil }
        let turns = MeetingTranscript.turns(meeting.pieces)
        let failed = !meeting.failures.isEmpty || meeting.gaveUp != nil
        let keepSetting = keepAudio()
        let hasAudio = !meeting.spool.audio().isEmpty
        let mustKeep = hasAudio && (failed || keepSetting)
        let spool = meeting.spool, title = title(meeting), app = meeting.appName

        if turns.isEmpty && !failed {
            let saidNothing = "No speech was heard in the meeting with \(app), so no note was saved."
                + (silence.map { " " + $0.detail } ?? "")
            let someoneRecorded = meeting.sides.values.contains { $0.startError == nil }
            guard mustKeep else {
                spool.discard()   // no note needed, nothing to keep
                if meeting.isRecovery {
                    Log.info("Meeting recovery: no speech in the meeting with \(app); nothing to keep.")
                } else if someoneRecorded {   // else already told
                    Log.info("Meeting: nothing was said; no note.")
                    feedback.notify(title: "Nothing recorded", body: saidNothing)
                }
                return end()
            }
            // Keep meeting audio is on: the audio is kept, nothing heard or not.
            let folder = newArchiveFolder(title)
            journalWrittenDown(spool, note: nil, keepAudio: true, folder: folder)
            copyAudioThenDiscard(spool, into: folder, title: title, failuresSoFar: 0) { [feedback] kept in
                let whereItIs = kept.map { " Its audio is kept in \($0.path)." } ?? ""
                feedback.notify(title: "Nothing recorded", body: saidNothing + whereItIs)
            }
            return end()
        }

        var caveats = caveats(meeting)
        let folder = mustKeep ? newArchiveFolder(title) : nil
        // The note names the folder only if the audio can't be lost: all on
        // disk, it's either copied there or still in the spool for the next
        // launch (the caveat says both). Held in memory, a notice says where.
        let noteNamesFolder = failed && spool.hasAllAudioOnDisk
        if noteNamesFolder, let folder { caveats.append(.audioKept(folder)) }
        let note = MeetingNote(appName: app, start: meeting.startDate, duration: meeting.duration,
                               turns: turns, caveats: caveats, event: meeting.event)
        let draft = identified(note.draft(locale: locale, timeZone: timeZone), meeting)
        do {
            let url = try notes.save(draft)
            Log.info("Meeting note saved (meeting \(spool.meeting.id)).")   // no path: it has the event title
            journalWrittenDown(spool, note: url.path, keepAudio: mustKeep, folder: folder)
            var body = draft.title
            if silence != nil { body += " — no sound came from \(app); see the note." }
            if failed { body += " Some of it couldn't be transcribed; see the note." }
            let titled = meeting.recovery == .crashed ? "Meeting note recovered" : "Meeting note saved"
            feedback.noteSaved(url, title: titled, body: body)
            if mustKeep {
                copyAudioThenDiscard(spool, into: folder, title: title, failuresSoFar: 0,
                                     then: failed && !noteNamesFolder ? tellWhereTheAudioIs(title) : { _ in })
            } else {
                spool.discard()   // saved, nothing to keep
            }
        } catch {
            noteNotSaved(draft, error, meeting, folder: folder, hasAudio: hasAudio)
        }
        end()
    }

    /// Journals that the meeting is written down (`.noteSaved`) before
    /// anything else, so no later launch writes it again. If the journal
    /// can't take it (the disk is full), the folder's name says it instead
    /// (a rename in place: no space needed); a later launch then only
    /// deletes it, or finishes the copy (`SpoolFolderMark`). With audio held
    /// in memory, no folder is journaled: a retry copies only the disk part,
    /// and must not land on top of the complete copy.
    private func journalWrittenDown(_ spool: MeetingSpoolHandle, note: String?, keepAudio: Bool, folder: URL?) {
        let retryFolder = spool.hasAllAudioOnDisk ? folder?.path : nil
        if spool.record(.noteSaved(note: note, keepAudio: keepAudio, audioFolder: retryFolder)) {
            // The journal says it all now: a mark left from a full disk goes (#48).
            if !spool.folderMarks.isEmpty { spool.setMarks([]) }
            return
        }
        guard spool.hasFolder else { return }
        Log.error("Meeting: the note is saved but the spool's journal didn't take it; marking the spool instead.")
        if !spool.mark(keepAudio ? .audioPending : .writtenDown) {
            Log.error("Meeting: the spool couldn't be marked either; a later launch may write this meeting's note again.")
        }
    }

    /// "Meeting audio kept" naming the folder, once the copy is there (a
    /// failure is said by `audioNotCopied`).
    private func tellWhereTheAudioIs(_ title: String) -> (URL?) -> Void {
        { [feedback] kept in
            guard let kept else { return }
            feedback.notify(title: "Meeting audio kept", body: "The audio of “\(title)” is in \(kept.path).")
        }
    }

    /// The notes library wouldn't take the note: into the archive with the
    /// audio; if even that fails, a spool with a folder stays (whatever
    /// failed to write) and the next launch finishes the meeting. Only one
    /// with no folder (all in memory) is lost, and the notice says so.
    private func noteNotSaved(_ draft: NoteDraft, _ error: Error, _ meeting: Meeting, folder: URL?, hasAudio: Bool) {
        Log.error("Couldn't save the meeting note (meeting \(meeting.spool.meeting.id)): \(Self.logged(error))")
        let spool = meeting.spool, title = title(meeting)
        let markdown = NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind,
                                              duration: draft.duration, body: draft.body, id: draft.id,
                                              event: draft.event, attendees: draft.attendees)
        let reason = error.localizedDescription
        if let folder = folder ?? newArchiveFolder(title), (try? archive.writeNote(markdown, into: folder)) != nil {
            journalWrittenDown(spool, note: folder.appendingPathComponent("Note.md").path, keepAudio: hasAudio, folder: folder)
            guard hasAudio else {
                spool.discard()   // saved (in the archive), no audio to keep
                return feedback.notify(title: "Couldn't save the meeting note",
                                       body: "\(reason) The transcript is in \(folder.path).")
            }
            let allOnDisk = spool.hasAllAudioOnDisk, partOnDisk = spool.hasFolder   // before the copy
            copyAudioThenDiscard(spool, into: folder, title: title, failuresSoFar: 0, quietOnFailure: true) { [feedback] kept in
                let audio = kept != nil ? "The transcript and audio are in \(folder.path)."
                    : allOnDisk ? "The transcript is in \(folder.path); the audio is safe and Cado copies it there "
                        + "the next time it starts."
                    : partOnDisk ? "The transcript is in \(folder.path). The first part of the audio is safe and Cado "
                        + "copies it to its Meeting Audio folder the next time it starts; the rest couldn't be kept."
                    : "The transcript is in \(folder.path); the audio couldn't be kept."
                feedback.notify(title: "Couldn't save the meeting note", body: "\(reason) \(audio)")
            }
        } else if spool.hasFolder {
            // Stays, whatever failed to write: the next launch finishes it.
            // The attempt (if a recovery) ended here, so its `.tried` mark goes either way.
            if spool.record(.noteSaveFailed(reason: reason)) {
                endAttemptMark(spool)
            } else if !spool.setMarks(spool.folderMarks.subtracting([.tried]).union([.noteNotSaved])) {
                Log.error("Meeting: couldn't note in the spool that the note wasn't saved.")
            }
            Log.error("Meeting: the note couldn't be saved anywhere; the meeting stays in its spool for the next launch.")
            guard !meeting.toldMeetingIsSafe else { return }   // said on an earlier launch
            let safe = spool.hasAllAudioOnDisk ? "The meeting is safe: Cado will finish it the next time it starts."
                : "Only the first part of the meeting is safe: Cado will finish it the next time it starts. "
                    + "The rest couldn't be kept."
            feedback.notify(title: "Couldn't save the meeting note", body: "\(reason) \(safe)")
            spool.record(.toldUser(.meetingIsSafe))   // if this fails, the next launch says it again
        } else {
            spool.discard()   // no folder: nothing outlives the app anyway
            feedback.notify(title: "Couldn't save the meeting",
                            body: "\(reason) The meeting couldn't be saved anywhere, so it is lost.")
        }
    }

    /// Cado is quitting mid-meeting: the spool (with `.appQuit`) is left for
    /// the next launch to finish. A meeting with audio held in memory can't
    /// wait: it's written down now with what there is, its audio kept, the
    /// same way as any note (journaled; a disk part kept if it can't be saved).
    private func leaveForNextLaunch(_ meeting: Meeting) {
        guard let done = meeting.quit else { return }
        endPrewarmIfHeld(meeting)
        guard !meeting.spool.hasAllAudioOnDisk else {
            Log.info("Meeting: Cado is quitting; the meeting with \(meeting.appName) is finished next launch.")
            end()
            return whenCopiesAreSafe(done)
        }
        lastThemWasSilent = themSilence(meeting) != nil
        let spool = meeting.spool, title = title(meeting)
        let hasAudio = !spool.audio().isEmpty
        let folder = hasAudio ? newArchiveFolder(title) : nil
        var caveats = caveats(meeting)
        caveats.append(.quitBeforeTranscribing)
        let draft = identified(MeetingNote(appName: meeting.appName, start: meeting.startDate, duration: meeting.duration,
                                           turns: MeetingTranscript.turns(meeting.pieces), caveats: caveats,
                                           event: meeting.event)
            .draft(locale: locale, timeZone: timeZone), meeting)
        do {
            let url = try notes.save(draft)
            journalWrittenDown(spool, note: url.path, keepAudio: hasAudio, folder: folder)
            if hasAudio {
                copyAudioThenDiscard(spool, into: folder, title: title, failuresSoFar: 0, then: tellWhereTheAudioIs(title))
            } else {
                spool.discard()   // saved, no audio
            }
        } catch {
            noteNotSaved(draft, error, meeting, folder: folder, hasAudio: hasAudio)
        }
        end()
        whenCopiesAreSafe(done)
    }

    /// The draft with the meeting's stable id in its front matter (#48), so a
    /// later launch can find the note if Cado dies before journaling it.
    private func identified(_ draft: NoteDraft, _ meeting: Meeting) -> NoteDraft {
        var draft = draft
        draft.id = meeting.spool.meeting.id.uuidString
        return draft
    }

    /// A new archive folder for the meeting, or nil (logged).
    private func newArchiveFolder(_ title: String) -> URL? {
        do {
            return try archive.newFolder(name: NotesLibrary.sanitise(title))
        } catch {
            Log.error("Couldn't make the meeting's audio folder: \(Self.logged(error))")
            return nil
        }
    }

    /// Copies the spool's audio into `folder` (nil: a new one) off main. Call
    /// only once the note is saved: on success it journals `.audioKept` and
    /// deletes the spool, else journals `.audioKeepFailed` and leaves a spool
    /// with a folder (copied again next launch). The user hears of a failure
    /// once (`failuresSoFar` 0), unless `quietOnFailure` (the caller says
    /// it). `then` gets the folder on success.
    private func copyAudioThenDiscard(_ spool: MeetingSpoolHandle, into folder: URL?, title: String,
                                      failuresSoFar: Int, quietOnFailure: Bool = false,
                                      then: @escaping (URL?) -> Void) {
        guard let folder = folder ?? newArchiveFolder(title) else {
            return audioNotCopied(spool, NoFolder(), title: title, tell: failuresSoFar == 0 && !quietOnFailure, then: then)
        }
        let audio = spool.audio()
        let fragile = !spool.hasAllAudioOnDisk
        if fragile { fragileCopies += 1 }
        var failure: Error?
        var missing: TimeInterval = 0
        let archive = self.archive
        background({
            do { missing = try Self.keep(audio, in: folder, archive) } catch { failure = error }
        }, { [weak self, feedback] in
            if let failure {
                self?.audioNotCopied(spool, failure, title: title, tell: failuresSoFar == 0 && !quietOnFailure, then: then)
            } else {
                // Copied: if the journal can't say so, the name does, so a failed delete isn't copied again.
                if !spool.record(.audioKept(folder: folder.path)), spool.hasFolder { spool.mark(.writtenDown) }
                spool.discard()   // saved and copied (as much as there is)
                Log.info("Meeting audio kept (meeting \(spool.meeting.id)).")
                if missing > 0 {
                    feedback.notify(title: "Part of a meeting's audio is missing",
                                    body: "The end of the recording of “\(title)” couldn't be read, so "
                                        + "\(Self.roughly(missing)) at the end of its audio is missing from \(folder.path).")
                }
                then(folder)
            }
            if fragile { self?.copyFinished() }
        })
    }

    /// Keeps `audio` as WAVs in `folder` (`writeAudio`). A spool file
    /// shorter than its journal says (`SpoolWAVError.shortRead`) is so for
    /// good: every copy would come out short, on every launch (#48). Then
    /// what can be read is kept instead (`writeReadableAudio`, each WAV whole
    /// for its length) and the copy is done: how much is missing at the end
    /// (0: none). Off main.
    private static func keep(_ audio: SpoolAudio, in folder: URL, _ archive: MeetingArchive) throws -> TimeInterval {
        do {
            try archive.writeAudio(audio, into: folder)
            return 0
        } catch let error as SpoolWAVError {
            guard case .shortRead = error else { throw error }
            Log.error("Meeting audio: the recording is shorter than its journal says (\(error.localizedDescription)); "
                      + "keeping what can be read.")
            let kept = try archive.writeReadableAudio(audio, into: folder)
            let missing = MeetingSpeaker.allCases.map { audio.count(of: $0) - (kept[$0] ?? audio.count(of: $0)) }.max() ?? 0
            return Double(max(missing, 0)) / AudioCapture.sampleRate
        }
    }

    /// "about 12 seconds", "about 3 minutes".
    static func roughly(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 90 { return "about \(s) second\(s == 1 ? "" : "s")" }
        return "about \(Int((seconds / 60).rounded())) minutes"
    }

    private func audioNotCopied(_ spool: MeetingSpoolHandle, _ error: Error, title: String, tell: Bool,
                                then: (URL?) -> Void) {
        Log.error("Couldn't keep the meeting's audio (meeting \(spool.meeting.id)): \(Self.logged(error))")
        spool.record(.audioKeepFailed(reason: error.localizedDescription))
        if tell {
            let place = spool.location?.path ?? "Cado's Meetings In Progress folder"
            let body = spool.hasAllAudioOnDisk
                ? "The audio of “\(title)” couldn't be copied to Cado's Meeting Audio folder yet. It's safe in "
                    + "\(place); Cado will try again the next time it starts."
                : spool.hasFolder
                ? "The audio of “\(title)” couldn't be copied to Cado's Meeting Audio folder. The first part of it is safe in "
                    + "\(place); Cado will try again the next time it starts. The rest couldn't be kept."
                : "The audio of “\(title)” couldn't be copied to Cado's Meeting Audio folder, so it couldn't be kept."
            feedback.notify(title: "Couldn't keep the meeting's audio", body: body)
        }
        if !spool.hasFolder { spool.discard() }   // no folder: the audio can't outlive the app anyway
        then(nil)
    }

    private func copyFinished() {
        fragileCopies -= 1
        guard fragileCopies == 0 else { return }
        let waiters = quitWaiters
        quitWaiters = []
        waiters.forEach { $0() }
    }

    /// `done` once no copy of in-memory-only audio is still running.
    private func whenCopiesAreSafe(_ done: @escaping () -> Void) {
        fragileCopies == 0 ? done() : quitWaiters.append(done)
    }

    private func caveats(_ meeting: Meeting) -> [MeetingNote.Caveat] {
        var caveats: [MeetingNote.Caveat] = meeting.recovery.map { [.finishedLater($0)] } ?? []
        if meeting.gaveUp != nil { caveats.append(.unfinished) }
        for speaker in MeetingSpeaker.allCases {
            if let reason = meeting.side(speaker).startError { caveats.append(.couldNotRecord(speaker, reason: reason)) }
        }
        if let issue = themSilence(meeting) { caveats.append(.themSilent(issue)) }
        for speaker in MeetingSpeaker.allCases {
            if let at = meeting.side(speaker).lostAt { caveats.append(.stopped(speaker, at: at)) }
        }
        if meeting.capReached {
            // A recovered meeting stopped at its cap: its length, to the
            // minute (caps are whole minutes); else today's setting.
            let length = (meeting.duration / 60).rounded() * 60
            let cap = meeting.cap > 0 ? meeting.cap
                : length > 0 ? length : maxSeconds().flatMap { $0 > 0 ? $0 : nil } ?? MeetingLimit.backstopSeconds
            caveats.append(.capReached(cap))
        }
        if let reason = meeting.failures.first {
            caveats.append(.transcriptionFailed(failed: meeting.failures.count, of: meeting.total, reason: reason))
        }
        if meeting.ranOnFallbackModel, let language = meeting.spool.meeting.language {
            caveats.append(.ranOnFallbackModel(language: language))
        }
        return caveats
    }

    /// The readiness hint for a Them stream that recorded only exact zeros
    /// (what a tap without the grant delivers), unless the grant is proven.
    private func themSilence(_ meeting: Meeting) -> SystemAudioIssue? {
        guard meeting.side(.them).startError == nil,
              meeting.themAllZero ?? meeting.spool.isSilent(.them) else { return nil }
        return SystemAudioReadiness.issue(afterCaptureHeardSound: false, permission: systemAudioPermission())
    }

    private func endPrewarmIfHeld(_ meeting: Meeting) {
        guard meeting.prewarmed else { return }
        meeting.prewarmed = false
        engine.endPrewarm()
    }

    /// Back to idle; then a held recovery, or the next leftover, if any.
    private func end() {
        if !isQuitting, let recovery = held {
            held = nil
            return resume(recovery)
        }
        state = .idle
        report()
        startNextRecovery()
    }

    /// The user starts a meeting during a recovery (#48): recording comes
    /// first. The recovery is held at a chunk boundary: the passage already
    /// in the engine (one queue for everything) finishes and is journaled,
    /// nothing more is submitted or read back; its state stays in memory and
    /// its spool locked. `.recoveryPaused` is journaled once nothing of it is
    /// in flight, so a crash meanwhile isn't held against it, unless its own
    /// last passage caused it.
    private func hold(_ recovery: Meeting) {
        Log.info("Meeting recovery: the meeting with \(recovery.appName) waits while a new meeting records.")
        recovery.onHold = true
        held = recovery
        if recovery.inFlight == nil { journalPause(recovery.spool, forLiveMeeting: true) }
        state = .idle
    }

    /// The new meeting is written down: the held recovery goes on where it
    /// was, as a new attempt (journaled, so the crash-loop guard counts it).
    /// If its passage from before the hold isn't back yet (the new meeting
    /// was short), the pause is journaled first: the hold must not count as
    /// an attempt that got nowhere. That passage is then this attempt's.
    private func resume(_ recovery: Meeting) {
        recovery.onHold = false
        state = recovery.allEnded ? .transcribing(recovery) : .finishing(recovery)
        report()
        Log.info("Meeting recovery: going on with the meeting with \(recovery.appName).")
        if recovery.inFlight != nil { journalPause(recovery.spool) }
        guard beginAttempt(recovery.spool) else { return waitForRoom(recovery) }
        guard recovery.allEnded else { return readBack(recovery.id) }
        submitNext(recovery)
        completeIfDone(recovery)
    }

    // MARK: - Recovery

    private func startNextRecovery() {
        guard !isQuitting, case .idle = state, !lookingForNote else { return }
        if recoveryRequested {
            recoveryRequested = false
            leftovers = spooling.leftovers()
            if !leftovers.isEmpty { Log.info("Meeting recovery: \(leftovers.count) unfinished meeting(s) found.") }
        }
        while case .idle = state, !lookingForNote, !isQuitting {
            if let next = afterLookup {
                afterLookup = nil
                next()
                continue
            }
            guard !leftovers.isEmpty else { break }
            recover(leftovers.removeFirst())
        }
    }

    /// Rebuilds a leftover from its journal (`RecoveryPlan`), then reads back
    /// and transcribes what's left. One already written down only gets its
    /// audio copy finished.
    private func recover(_ leftover: LeftoverMeeting) {
        if leftover.isUnidentified { return keepUnidentified(leftover.handle) }
        let handle = leftover.handle
        let info = handle.meeting
        let counts = handle.audio().counts
        // What the journal couldn't take, the folder's name says: read as the
        // events it stands for, after the journal's own (#48).
        let events = leftover.events + SpoolFolderMark.events(for: leftover.marks)
        var plan = RecoveryPlan(events: events, sampleCounts: counts)
        let title = MeetingNote.title(appName: info.appName, start: info.startDate, event: plan.event ?? info.event,
                                      locale: locale, timeZone: timeZone)
        if plan.concluded == nil, leftover.marks.contains(.audioPending) {
            // Written down; the note's folder wasn't journaled: a new one, and the user is told where.
            let copied = leftover.events.contains { if case .audioKept = $0 { return true } else { return false } }
            plan.concluded = .init(note: nil, audioPending: !copied, audioFolder: nil, keepFailures: 1)
        }
        if let concluded = plan.concluded {
            return finishCopy(handle, concluded, title: title)
        }
        guard plan.mayAdoptNote else { return recoverAnew(handle, plan, events: events, title: title) }
        lookForNote(handle, plan, events: events, title: title)
    }

    /// Cado may have died between saving the meeting's note and journaling
    /// it (#48): the notes with the meeting's id are looked for off main (a
    /// listing of the notes folder), and the first whole one
    /// (`RecoveryPlan.isWholeNote`) is adopted, a part beside it passed over;
    /// with none whole the note is written afresh, the others left as they are. Until the
    /// lookup is back no other leftover starts and this one is untouched
    /// (its spool stays locked); a meeting the user starts meanwhile records
    /// at once and this leftover goes on once that one is written down, as a
    /// held recovery does. Quitting meanwhile leaves it for the next launch.
    private func lookForNote(_ handle: MeetingSpoolHandle, _ plan: RecoveryPlan, events: [SpoolEvent], title: String) {
        let notes = self.notes, archive = self.archive, info = handle.meeting
        let hasAudio = !handle.audio().isEmpty
        var found: (note: URL, adoption: RecoveryPlan.Adoption)?
        var notWhole = false
        var returned = false
        lookingForNote = true
        background({
            // The first whole one; a part left beside it (an older Cado's failed save) is passed over.
            for note in notes.existingNotes(id: info.id.uuidString, since: info.startDate) {
                guard let text = notes.text(of: note), plan.isWholeNote(text) else { notWhole = true; continue }
                let named = RecoveryPlan.audioFolder(namedIn: text)
                found = (note, RecoveryPlan.adoption(hasAudio: hasAudio, namedFolder: named,
                                                     namedFolderIsFree: named.map(archive.isFreeFolder) ?? false))
                return
            }
        }, { [weak self] in
            guard let self else { return }
            self.lookingForNote = false
            guard !self.isQuitting else { return }
            self.afterLookup = { [unowned self] in
                if let found { return self.adopt(found.note, handle, found.adoption, title: title) }
                if notWhole {
                    Log.error("Meeting recovery: meeting \(info.id) has a note that isn't whole (a save that failed); "
                              + "writing it again, the other left as it is.")
                }
                self.recoverAnew(handle, plan, events: events, title: title)
            }
            if returned { self.startNextRecovery() }   // else the caller's loop runs it
        })
        returned = true
    }

    /// Rebuilds the leftover from its plan and transcribes what's left (or
    /// sets it aside, if a give-up died writing its note).
    private func recoverAnew(_ handle: MeetingSpoolHandle, _ plan: RecoveryPlan, events: [SpoolEvent], title: String) {
        let info = handle.meeting
        if RecoveryPlan.diedAfterGivingUp(events) {
            return putAside(handle, events, title: title)
        }
        journalMarks(handle)
        meetingCount += 1
        // Through `RecoverySpoolHandle`: an attempt's start is journaled before anything else of it.
        let meeting = Meeting(id: meetingCount, appName: info.appName, startedAt: clock.now, startDate: info.startDate,
                              spool: RecoverySpoolHandle(handle), me: nil, them: nil, recovery: plan.reason)
        for (speaker, planned) in plan.sides {
            let side = meeting.side(speaker)
            side.origin = planned.origin
            side.startError = planned.startError
            side.lostAt = planned.lostAt
            side.base = planned.restartAt
            side.cursor = planned.restartAt
            side.journaledSettled = planned.restartAt
        }
        meeting.pieces = plan.pieces
        meeting.failures = plan.failures
        meeting.done = plan.done
        meeting.total = plan.done
        meeting.capReached = plan.capReached
        meeting.ranOnFallbackModel = plan.ranOnFallbackModel
        meeting.recoveredDuration = plan.duration
        meeting.toldMeetingIsSafe = events.contains(.toldUser(.meetingIsSafe))
        meeting.event = plan.event ?? info.event
        state = .finishing(meeting)
        report()
        Log.info("Meeting recovery: the meeting with \(info.appName) from \(info.startDate) "
                 + "(\(plan.done) passage(s) already transcribed, \(plan.stalledAttempts) stalled attempt(s)).")
        scanThemForSilence(meeting)
        guard !plan.shouldGiveUp else {
            return giveUp(meeting, reason: "recovery was begun \(plan.stalledAttempts) times without getting further")
        }
        guard beginAttempt(meeting.spool) else { return waitForRoom(meeting) }
        readBack(meeting.id)
    }

    // A full disk must not switch off the crash-loop guard (#48): an attempt
    // the journal can't count is counted by the folder's name (`.tried`),
    // once; one more, or a give-up the journal can't take, waits for a
    // launch with room, once, then is set aside (`waitForRoom`). And a mark has no place in time, so once the journal
    // takes events again the marks go into it and the name goes back to
    // plain: a later `.recoveryGaveUp` is then read in its right place.

    /// The marks that stand for journal events go into the journal, and off
    /// the name. The name goes first: if the journal then refuses, the name
    /// says again what it couldn't take (never a mark journaled twice).
    private func journalMarks(_ handle: MeetingSpoolHandle) {
        let marks = handle.folderMarks.filter { $0.event != nil }
        guard !marks.isEmpty, handle.setMarks(handle.folderMarks.subtracting(marks)) else { return }
        var left = Set(marks)
        for mark in SpoolFolderMark.ordered(left) {
            guard let event = mark.event, handle.record(event) else { break }
            left.remove(mark)
        }
        guard !left.isEmpty else { return }
        Log.info("Meeting recovery: the journal is still full; the spool's name keeps what it couldn't take.")
        handle.setMarks(handle.folderMarks.union(left))
    }

    /// Journals that an attempt begins, else marks it `.tried`
    /// (`RecoverySpoolHandle.beginAttempt`); false if neither.
    private func beginAttempt(_ spool: MeetingSpoolHandle) -> Bool {
        (spool as? RecoverySpoolHandle)?.beginAttempt() ?? spool.record(.recoveryStarted)
    }

    /// The attempt ended (a note saved or not, a clean quit): its mark goes,
    /// and a give-up's: journaled by then (`RecoverySpoolHandle`), or, if
    /// not (a pause the journal can't take), the give-up is decided again.
    private func endAttemptMark(_ spool: MeetingSpoolHandle) {
        let marks = spool.folderMarks.intersection([.tried, .gaveUp])
        if !marks.isEmpty { spool.setMarks(spool.folderMarks.subtracting(marks)) }
    }

    /// The journal can't take what recovery must write first: the meeting
    /// isn't run where the crash-loop guard can't count it, and it's never
    /// touched. What the write's error says decides what then (bounded, #48):
    /// - The disk is full: it waits, once, for a launch with room (`.waited`,
    ///   a rename: no space needed). Said unless the user heard of this
    ///   meeting already ("the meeting is safe").
    /// - Still full a launch later, the wait can't be marked, or Cado can't
    ///   write there at all (permissions, a read-only disk: room won't help):
    ///   it's set aside, moved as it is into the archive (`setAside`), and
    ///   the user is told once where. Not tried again.
    private func waitForRoom(_ meeting: Meeting) {
        let title = title(meeting), spool = meeting.spool
        meeting.queue.removeAll()
        let diskFull = SpoolWriteFailure.isDiskFull(spool.writeError)
        if diskFull, !spool.folderMarks.contains(.waited), spool.setMarks(spool.folderMarks.union([.waited])) {
            Log.error("Meeting recovery: the disk is full, so the spool's journal can't be written; "
                      + "meeting \(spool.meeting.id) waits for a launch with room, once.")
            if !meeting.toldMeetingIsSafe {
                feedback.notify(title: "Couldn't finish a meeting yet",
                                body: "Your Mac's disk is full, so Cado can't finish “\(title)” yet. Its recording is safe; "
                                    + "Cado will try again the next time it starts.")
            }
            return end()
        }
        Log.error("Meeting recovery: the spool's journal can't be written ("
                  + "\(spool.writeError.map(Self.logged) ?? "no error given")); setting meeting \(spool.meeting.id) aside.")
        setAside(spool, title: title, why: diskFull ? "Your Mac's disk is still full, so Cado couldn't finish “\(title)”"
                    : "Cado can't write to its Meetings In Progress folder, so it couldn't finish “\(title)”")
        end()
    }

    /// Whether the reopened Others side is all zeros: a whole-file scan, so
    /// off main.
    private func scanThemForSilence(_ meeting: Meeting) {
        guard meeting.side(.them).startError == nil else { meeting.themAllZero = false; return }
        let audio = meeting.spool.audio()
        var allZero = false
        let id = meeting.id
        background({ allZero = audio.isAllZero(.them) }, { [weak self] in
            guard let self, let meeting = self.meeting(id) ?? self.held.flatMap({ $0.id == id ? $0 : nil }) else { return }
            meeting.themAllZero = allZero
            self.completeIfDone(meeting)
        })
    }

    /// One slice of each side's unsettled audio through its chunker; again
    /// on a later turn until both are read.
    private func readBack(_ id: Int) {
        guard let meeting = meeting(id), case .finishing = state else { return }
        for speaker in MeetingSpeaker.allCases {
            let side = meeting.side(speaker)
            guard !side.ended else { continue }
            let count = meeting.spool.sampleCount(of: speaker)
            guard side.cursor < count else {
                endSide(side, meeting)
                continue
            }
            let samples: [Float]
            do {
                samples = try meeting.spool.samples(side.cursor..<min(side.cursor + Self.recoverySliceSamples, count),
                                                    of: speaker)
            } catch {
                return giveUp(meeting, reason: "its audio couldn't be read (\(error.localizedDescription))")
            }
            guard !samples.isEmpty else {
                endSide(side, meeting)
                continue
            }
            side.cursor += samples.count
            queueChunks(side.chunker.append(samples), of: side, meeting)
        }
        guard self.meeting(id) != nil else { return }
        if meeting.allEnded { return transcribeRestOnceAllSidesEnded(meeting) }
        later { [weak self] in self?.readBack(id) }
    }

    /// Recovery can't go on: the note is written from what was transcribed
    /// (saying so), and the audio kept with it, under the usual rule.
    /// Journaled first (or, the journal full, said by the folder's name:
    /// `RecoverySpoolHandle.giveUp`): if Cado dies writing that note, the
    /// next launch sets the meeting aside instead of dying the same way again.
    private func giveUp(_ meeting: Meeting, reason: String) {
        Log.error("Meeting recovery: can't finish the meeting with \(meeting.appName): \(reason).")
        // Not counted, a death writing the note would come back every launch.
        let counted = (meeting.spool as? RecoverySpoolHandle)?.giveUp(reason: reason)
            ?? meeting.spool.record(.recoveryGaveUp(reason: reason))
        guard counted else { return waitForRoom(meeting) }
        meeting.gaveUp = reason
        meeting.queue.removeAll()
        for side in meeting.sides.values { side.ended = true }
        transcribeRestOnceAllSidesEnded(meeting)
    }

    /// A leftover already written down: finish copying its audio, else just
    /// delete it. Never a second note.
    private func finishCopy(_ handle: MeetingSpoolHandle, _ concluded: RecoveryPlan.Concluded, title: String) {
        guard concluded.audioPending, !handle.audio().isEmpty else {
            Log.info("Meeting recovery: meeting \(handle.meeting.id) was already written down; removing what was left of it.")
            return handle.discard()
        }
        Log.info("Meeting recovery: copying the audio of meeting \(handle.meeting.id) (the note was saved already).")
        let folder = concluded.audioFolder.map { URL(fileURLWithPath: $0) }
        copyAudioThenDiscard(handle, into: folder, title: title, failuresSoFar: concluded.keepFailures) { [feedback] kept in
            guard let kept, concluded.keepFailures > 0 else { return }
            feedback.notify(title: "Meeting audio kept", body: "The audio of “\(title)” is now in \(kept.path).")
        }
    }

    /// Cado died between saving the meeting's note and journaling it (#48):
    /// that note (whole) is the meeting's, found by its id; journaled now,
    /// never a second one. The user hadn't heard of it: said now. Its audio
    /// is kept whenever there is any (`RecoveryPlan.adoption`: the rule the
    /// note was written under isn't known for sure), into the folder the
    /// note names if that's free, else a new one, and the user is told where.
    /// Once journaled it's handed on as a saved note is (`notes.adopted`: a
    /// summary, under the usual rules).
    private func adopt(_ note: URL, _ handle: MeetingSpoolHandle, _ adoption: RecoveryPlan.Adoption, title: String) {
        Log.info("Meeting recovery: meeting \(handle.meeting.id) has its note already; not writing a second one.")
        let folder = adoption.keepAudio ? adoption.audioFolder ?? newArchiveFolder(title) : nil
        journalWrittenDown(handle, note: note.path, keepAudio: adoption.keepAudio, folder: folder)
        notes.adopted(note)
        feedback.noteSaved(note, title: "Meeting note saved", body: title)
        guard adoption.keepAudio else {
            Log.info("Meeting recovery: meeting \(handle.meeting.id) was already written down; removing what was left of it.")
            return handle.discard()   // saved, no audio at all
        }
        copyAudioThenDiscard(handle, into: folder, title: title, failuresSoFar: 0) { [feedback] kept in
            guard let kept else { return }   // a failure is said by `audioNotCopied`
            let notThere = adoption.namedFolderUnusable ? ", not in the folder its note names" : ""
            feedback.notify(title: "Meeting audio kept", body: "The audio of “\(title)” is in \(kept.path)\(notThere).")
        }
    }

    /// A spool folder with audio but no readable meeting.json (#48): what app,
    /// and when, isn't known, so no note can be written. Its audio is kept
    /// as WAVs in a Meeting Audio folder of its own; once they're written
    /// whole (`writeAudio` didn't throw), the spool folder itself, journal
    /// and all (what was transcribed so far), is moved in beside them. Never
    /// deleted. The user is told once where. If the WAVs or the move fail,
    /// it stays where it is, named so later launches leave it alone, and the
    /// user is told where.
    private func keepUnidentified(_ handle: MeetingSpoolHandle) {
        let title = MeetingNote.title(appName: "an unknown app", start: handle.meeting.startDate,
                                      locale: locale, timeZone: timeZone)
        Log.error("Meeting recovery: a recording without its details was found; keeping its audio.")
        let found = "Cado found a meeting recording without its details (which app, and when), so it can't write its note."
        var short = ""   // the end of its recording couldn't be read
        let leaveIt = { [feedback] (wavs: URL?) in
            guard handle.hasFolder else { return }
            handle.setMarks(handle.folderMarks.union([.unidentified]))   // if this fails, said again next launch
            let also = wavs.map { " A copy of its audio is in \($0.path).\(short)" } ?? ""
            feedback.notify(title: "Couldn't finish a meeting",
                            body: "\(found) Its recording is kept, unchanged, in "
                                + "\(handle.location?.path ?? "Cado's Meetings In Progress folder").\(also)")
        }
        let audio = handle.audio()
        // Not one whole sample: nothing to convert.
        guard !audio.isEmpty, let folder = newArchiveFolder(title) else { return leaveIt(nil) }
        let archive = self.archive
        var failure: Error?
        var missing: TimeInterval = 0
        background({
            do { missing = try Self.keep(audio, in: folder, archive) } catch { failure = error }
        }, { [feedback] in
            if let failure {
                Log.error("Couldn't keep the audio of the recording without its details: \(Self.logged(failure))")
                return leaveIt(nil)
            }
            if missing > 0 {
                short = " The end of the recording couldn't be read, so \(Self.roughly(missing)) at the end of its audio is missing."
            }
            guard handle.moveFolder(into: folder) != nil else { return leaveIt(folder) }
            Log.info("Meeting recovery: the recording without its details is kept in the meeting audio folder.")
            feedback.notify(title: "Couldn't finish a meeting",
                            body: "\(found) Its audio is kept in \(folder.path), with what was transcribed of it so far.\(short)")
        })
    }

    /// A leftover that already killed a launch while its note was written:
    /// not transcribed, not rendered, never deleted: set aside.
    private func putAside(_ handle: MeetingSpoolHandle, _ events: [SpoolEvent], title: String) {
        guard !events.contains(.toldUser(.recordingSetAside)) else {
            return Log.error("Meeting recovery: meeting \(handle.meeting.id) was set aside already; left where it is.")
        }
        Log.error("Meeting recovery: meeting \(handle.meeting.id) stopped Cado last time; setting its recording aside, untouched.")
        setAside(handle, title: title, why: "Cado couldn't finish “\(title)”")
    }

    /// Recovery stops trying: the folder is moved, as it is, into a new
    /// archive folder (no journal needed), and the user is told once where
    /// (`why` starts the notice). If it can't be moved it stays in the
    /// spool, named so later launches leave it there without a word
    /// (`.setAside`), and journaled so too; only if neither can be written
    /// is the user told again on a later launch.
    private func setAside(_ handle: MeetingSpoolHandle, title: String, why: String) {
        let folder = newArchiveFolder(title)
        let moved = folder.flatMap { handle.moveFolder(into: $0) } != nil
        if !moved, !handle.setMarks(handle.folderMarks.union([.setAside])) {
            Log.error("Meeting recovery: couldn't mark meeting \(handle.meeting.id) as set aside either.")
        }
        let place = moved ? folder?.path : handle.location?.path
        feedback.notify(title: "Couldn't finish a meeting",
                        body: "\(why) and has stopped trying. Its recording is kept, unchanged, in "
                            + "\(place ?? "Cado's Meetings In Progress folder").")
        if !moved { handle.record(.toldUser(.recordingSetAside)) }   // after telling: twice is better than never
    }

    // MARK: - Helpers

    /// An error for the system log, which is public: a file error's text
    /// names the file, and a note's or folder's name can be its calendar
    /// event's title (#38). Its domain and code are enough to debug.
    private static func logged(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.domain) \(e.code)"
    }

    private func title(_ meeting: Meeting) -> String {
        MeetingNote.title(appName: meeting.appName, start: meeting.startDate, event: meeting.event,
                          locale: locale, timeZone: timeZone)
    }

    private func describe(_ speaker: MeetingSpeaker, _ meeting: Meeting) -> String {
        speaker == .me ? "your microphone" : "\(meeting.appName)'s audio"
    }

    private func report() {
        let next: MeetingStatus
        switch state {
        case .idle:
            next = .idle
        case .recording(let m):
            next = .recording(app: m.appName, startedAt: m.startedAt,
                              lost: Set(MeetingSpeaker.allCases.filter { !m.side($0).isLive }))
        case .finishing(let m):
            next = m.isRecovery ? .recovering(app: m.appName, done: 0, total: 0)
                : .transcribing(app: m.appName, done: 0, total: 0)
        case .transcribing(let m):
            next = m.isRecovery ? .recovering(app: m.appName, done: m.done, total: m.total)
                : .transcribing(app: m.appName, done: m.done, total: m.total)
        }
        guard next != status else { return }
        status = next
        activity.meetingStatusChanged(next)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
