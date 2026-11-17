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
///   marks it so, and the late note says that, not "quit unexpectedly".
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
/// - Start is ignored unless idle; during a recovery the user is told why.
///   Stop only while recording.
/// - Recording stops by itself at `maxSeconds`, with a notice; the note is
///   still written and says so.
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
    /// The hard cap on one meeting.
    static let defaultMaxSeconds: TimeInterval = 2 * 3600

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
    private let later: (@escaping () -> Void) -> Void
    private let background: (@escaping () -> Void, @escaping () -> Void) -> Void
    private let locale: Locale
    private let timeZone: TimeZone
    private let calendarNaming: MeetingCalendarNaming   // #38
    let maxSeconds: TimeInterval

    private var state: State = .idle
    private var timer: ClockTimer?
    private var meetingCount = 0
    /// `recoverLeftovers` was called; the leftovers are listed when idle.
    private var recoveryRequested = false
    private var leftovers: [LeftoverMeeting] = []
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
         maxSeconds: TimeInterval = MeetingSession.defaultMaxSeconds,
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
        if let recovering = current, recovering.isRecovery {
            // One meeting at a time: the earlier one first, and say so.
            feedback.notify(title: "Meeting not started",
                            body: "Cado is still finishing a meeting with \(recovering.appName) that wasn't finished. "
                                + "Start the new one once it's done.")
            return
        }
        guard case .idle = state, !isQuitting else { return }
        meetingCount += 1
        let id = meetingCount
        let startDate = date()
        let spool = makeSpool(SpooledMeeting(id: UUID(), appName: app.name, appBundleID: app.bundleID,
                                             startDate: startDate))
        let streams = recorder.streams(for: app, maxSeconds: maxSeconds)
        let meeting = Meeting(id: id, appName: app.name, startedAt: clock.now, startDate: startDate, spool: spool,
                              me: streams.me, them: streams.them)
        state = .recording(meeting)
        Log.info("Meeting recording started: \(app.name) (\(app.bundleID)) and the microphone.")
        timer = clock.schedule(after: maxSeconds) { [weak self] in self?.capReached(id) }
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
        recoveryRequested = false
        switch state {
        case .idle:
            whenCopiesAreSafe(done)
        case .finishing(let meeting) where meeting.isRecovery, .transcribing(let meeting) where meeting.isRecovery:
            Log.info("Meeting recovery: Cado is quitting; the meeting with \(meeting.appName) goes on next launch.")
            meeting.spool.record(.recoveryPaused)
            end()
            whenCopiesAreSafe(done)
        case .recording(let meeting):
            if meeting.spool.hasFolder { meeting.spool.record(.appQuit) }
            meeting.quit = done
            finish(meeting)
        case .finishing(let meeting):
            if meeting.spool.hasFolder { meeting.spool.record(.appQuit) }
            meeting.quit = done
        case .transcribing(let meeting):
            if meeting.spool.hasFolder { meeting.spool.record(.appQuit) }
            meeting.quit = done
            leaveForNextLaunch(meeting)
        }
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
        Log.info("Meeting reached the \(MeetingNote.hours(maxSeconds)) limit; stopping.")
        meeting.capReached = true
        finish(meeting)
        feedback.notify(title: "Meeting recording stopped",
                        body: "Meetings are recorded for up to \(MeetingNote.hours(maxSeconds).replacingOccurrences(of: "-", with: " "))s. The note is being written.")
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
            engine.prewarm()
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
        while meeting.inFlight == nil, meeting.quit == nil, !meeting.queue.isEmpty {
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
            engine.transcribe(samples) { [weak self] result in self?.transcribed(id, result) }
        }
    }

    private func transcribed(_ id: Int, _ result: Result<Transcript, Error>) {
        guard let meeting = meeting(id), let job = meeting.inFlight else { return }
        meeting.inFlight = nil
        recordResult(result, of: job, meeting)
        submitNext(meeting)
        completeIfDone(meeting)
    }

    /// A job's result: into the pieces (or failures) and the journal, before
    /// its side's `.settled` may move past it.
    private func recordResult(_ result: Result<Transcript, Error>, of job: Job, _ meeting: Meeting) {
        meeting.done += 1
        switch result {
        case .success(let transcript):
            let segments = NonSpeechFilter.filter(transcript.segments)
            for segment in segments {
                meeting.pieces.append(.init(speaker: job.speaker, start: job.offset + segment.start, text: segment.text))
            }
            meeting.spool.record(.transcribed(job.speaker, range: job.range, offset: job.offset,
                                              segments: segments.map { SpoolSegment(start: $0.start, text: $0.text) }))
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
        let draft = note.draft(locale: locale, timeZone: timeZone)
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
        guard !spool.record(.noteSaved(note: note, keepAudio: keepAudio, audioFolder: retryFolder)), spool.hasFolder else {
            return
        }
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
                                              duration: draft.duration, body: draft.body,
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
            if !spool.record(.noteSaveFailed(reason: reason)), !spool.mark(.noteNotSaved) {
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
        let draft = MeetingNote(appName: meeting.appName, start: meeting.startDate, duration: meeting.duration,
                                turns: MeetingTranscript.turns(meeting.pieces), caveats: caveats,
                                event: meeting.event)
            .draft(locale: locale, timeZone: timeZone)
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
        let archive = self.archive
        background({
            do { try archive.writeAudio(audio, into: folder) } catch { failure = error }
        }, { [weak self] in
            if let failure {
                self?.audioNotCopied(spool, failure, title: title, tell: failuresSoFar == 0 && !quietOnFailure, then: then)
            } else {
                // Copied: if the journal can't say so, the name does, so a failed delete isn't copied again.
                if !spool.record(.audioKept(folder: folder.path)), spool.hasFolder { spool.mark(.writtenDown) }
                spool.discard()   // saved and copied
                Log.info("Meeting audio kept (meeting \(spool.meeting.id)).")
                then(folder)
            }
            if fragile { self?.copyFinished() }
        })
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
        if meeting.capReached { caveats.append(.capReached(maxSeconds)) }
        if let reason = meeting.failures.first {
            caveats.append(.transcriptionFailed(failed: meeting.failures.count, of: meeting.total, reason: reason))
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

    /// Back to idle; then the next leftover, if any are waiting.
    private func end() {
        state = .idle
        report()
        startNextRecovery()
    }

    // MARK: - Recovery

    private func startNextRecovery() {
        guard !isQuitting, case .idle = state else { return }
        if recoveryRequested {
            recoveryRequested = false
            leftovers = spooling.leftovers()
            if !leftovers.isEmpty { Log.info("Meeting recovery: \(leftovers.count) unfinished meeting(s) found.") }
        }
        while case .idle = state, !leftovers.isEmpty, !isQuitting {
            recover(leftovers.removeFirst())
        }
    }

    /// Rebuilds a leftover from its journal (`RecoveryPlan`), then reads back
    /// and transcribes what's left. One already written down only gets its
    /// audio copy finished.
    private func recover(_ leftover: LeftoverMeeting) {
        let handle = leftover.handle
        let info = handle.meeting
        let counts = handle.audio().counts
        var plan = RecoveryPlan(events: leftover.events, sampleCounts: counts)
        let event = plan.event ?? info.event
        let title = MeetingNote.title(appName: info.appName, start: info.startDate, event: event, locale: locale, timeZone: timeZone)
        if plan.concluded == nil {
            // What the journal couldn't take, the folder's name says.
            switch leftover.mark {
            case .audioPending?:
                // Written down; the note's folder wasn't journaled: a new one, and the user is told where.
                let copied = leftover.events.contains { if case .audioKept = $0 { return true } else { return false } }
                plan.concluded = .init(note: nil, audioPending: !copied, audioFolder: nil, keepFailures: 1)
            case .noteNotSaved?:
                plan.reason = .noteNotSaved
            case .writtenDown?, nil:
                break
            }
        }
        if let concluded = plan.concluded {
            return finishCopy(handle, concluded, title: title)
        }
        if leftover.mark != .noteNotSaved, Self.diedAfterGivingUp(leftover.events) {
            return putAside(handle, leftover.events, title: title)
        }
        meetingCount += 1
        let meeting = Meeting(id: meetingCount, appName: info.appName, startedAt: clock.now,
                              startDate: info.startDate, spool: handle, me: nil, them: nil, recovery: plan.reason)
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
        meeting.recoveredDuration = plan.duration
        meeting.toldMeetingIsSafe = leftover.events.contains(.toldUser(.meetingIsSafe))
        meeting.event = event
        state = .finishing(meeting)
        report()
        Log.info("Meeting recovery: the meeting with \(info.appName) from \(info.startDate) "
                 + "(\(plan.done) passage(s) already transcribed, \(plan.stalledAttempts) stalled attempt(s)).")
        scanThemForSilence(meeting)
        guard !plan.shouldGiveUp else {
            return giveUp(meeting, reason: "recovery was begun \(plan.stalledAttempts) times without getting further")
        }
        handle.record(.recoveryStarted)
        readBack(meeting.id)
    }

    /// Whether the reopened Others side is all zeros: a whole-file scan, so
    /// off main.
    private func scanThemForSilence(_ meeting: Meeting) {
        guard meeting.side(.them).startError == nil else { meeting.themAllZero = false; return }
        let audio = meeting.spool.audio()
        var allZero = false
        let id = meeting.id
        background({ allZero = audio.isAllZero(.them) }, { [weak self] in
            guard let self, let meeting = self.meeting(id) else { return }
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
    /// Journaled first: if Cado dies writing that note, the next launch sets
    /// the meeting aside instead of dying the same way again.
    private func giveUp(_ meeting: Meeting, reason: String) {
        Log.error("Meeting recovery: can't finish the meeting with \(meeting.appName): \(reason).")
        meeting.spool.record(.recoveryGaveUp(reason: reason))
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

    /// Recovery gave up on it, and nothing came of that (no note saved, none
    /// failed to save): Cado died writing the note.
    private static func diedAfterGivingUp(_ events: [SpoolEvent]) -> Bool {
        guard let last = events.lastIndex(where: { if case .recoveryGaveUp = $0 { return true } else { return false } })
        else { return false }
        return !events[last...].contains { if case .noteSaveFailed = $0 { return true } else { return false } }
    }

    /// A leftover that already killed a launch while its note was written:
    /// not transcribed, not rendered, never deleted. Its folder is moved, as
    /// it is, into a new archive folder, and the user is told once where it
    /// is. If it can't be moved it stays in the spool, and later launches
    /// leave it there without a word.
    private func putAside(_ handle: MeetingSpoolHandle, _ events: [SpoolEvent], title: String) {
        guard !events.contains(.toldUser(.recordingSetAside)) else {
            return Log.error("Meeting recovery: meeting \(handle.meeting.id) was set aside already; left where it is.")
        }
        Log.error("Meeting recovery: meeting \(handle.meeting.id) stopped Cado last time; setting its recording aside, untouched.")
        let folder = newArchiveFolder(title)
        let moved = folder.flatMap { handle.moveFolder(into: $0) } != nil
        let place = moved ? folder?.path : handle.location?.path
        feedback.notify(title: "Couldn't finish a meeting",
                        body: "Cado couldn't finish “\(title)” and has stopped trying. Its recording is kept, unchanged, in "
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
