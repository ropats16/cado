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
/// Crash safety: the spool also journals each side's start, failure and
/// loss, every chunk's transcript (or failure), how far each side is
/// settled, and the stop (`SpoolEvent`). A spool left behind by a run that
/// crashed or was killed is recovered by a later launch (`recoverLeftovers`):
/// the meeting is rebuilt from the journal, the audio never transcribed is
/// chunked and transcribed the same way, and the note gets a caveat saying it
/// was recovered. Recovery runs through the same states (finishing, then
/// transcribing), oldest leftover first.
///
/// Rules worth knowing:
/// - Start is ignored unless idle (so also while a recovery runs); stop only
///   while recording.
/// - Recording stops by itself at `maxSeconds`, with a notice; the note is
///   still written and says so.
/// - Memory: neither the session nor the captures (`retainsSamples: false`)
///   keep the meeting's audio: it is on disk in the spool, read back one
///   chunk (at most `maxChunkSeconds`) or one recovery slice at a time. What
///   is held is bounded: the chunkers' state, the job ranges, the pieces of
///   text. Only if the spool can't be made, or the disk stops taking audio
///   mid-meeting, is (the rest of) the audio held in memory instead, ~230 MB
///   an hour per side, so the meeting still gets its note.
/// - Each stream's samples stay on its own wall-clock timeline: a source
///   restart mid-meeting is kept as silence (`AudioCapture`'s `keepsTime`),
///   so a chunk's offset is the stream's origin plus its sample position.
/// - A side that can't start, or stops by itself, gets a notice and a caveat
///   in the note; the other side keeps recording. With no side left
///   recording, the meeting stops.
/// - An Others stream that was silent throughout (`isSilent` on the spool)
///   gets the readiness module's hint (the permission may not be granted) in
///   the note and the notice, unless this run already proved the grant;
///   `lastThemWasSilent` lets the menu offer the Settings pane afterwards.
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
///   transcribed, and the audio is kept (`MeetingArchive`) and named in it.
///   A note that can't be saved goes to the archive with the audio.
/// - Retention: after a clean note the spool is deleted; with `keepAudio`
///   (read when the meeting ends) its audio is first copied to the archive.
///   Failures, a note that couldn't be saved and quitting keep the audio
///   whatever the setting. The spool is always deleted at the end, so a
///   finished meeting leaves no leftover.
/// - `quit` (the app is quitting) stops, keeps the audio, writes a note with
///   whatever was transcribed so far plus where the audio is, then calls
///   back. Quitting during a recovery stops it at once; the leftover, with
///   what it got through journaled, is picked up next launch.
/// - Each meeting (recovered ones too) gets an id; callbacks for any other
///   meeting are ignored.
///
/// Main-thread only.
final class MeetingSession {
    /// The hard cap on one meeting.
    static let defaultMaxSeconds: TimeInterval = 2 * 3600

    static let dictationNotice = DictationBusyNotice(
        title: "Meeting recording",
        body: "Dictation is off while a meeting records. Stop the recording from the Cado menu first.")

    /// A leftover whose recovery was begun this many times already without
    /// finishing (Cado quit or crashed during it) isn't tried again: its audio
    /// goes to the archive and the user is told.
    static let maxRecoveryAttempts = 2
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
        /// Rebuilt from a leftover spool, not recorded by this run.
        let isRecovery: Bool
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
        /// The archive folder this meeting's audio (and note) went to.
        var archived: URL?
        /// `engine.prewarm()` was called and no job has been submitted since.
        var prewarmed = false
        /// The user was told the spool stopped taking audio.
        var toldSpoolFailed = false

        init(id: Int, appName: String, startedAt: TimeInterval, startDate: Date, spool: MeetingSpoolHandle,
             me: MeetingStream?, them: MeetingStream?, isRecovery: Bool = false) {
            self.id = id
            self.appName = appName
            self.startedAt = startedAt
            self.startDate = startDate
            self.spool = spool
            self.isRecovery = isRecovery
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
    private let locale: Locale
    private let timeZone: TimeZone
    let maxSeconds: TimeInterval

    private var state: State = .idle
    private var timer: ClockTimer?
    private var meetingCount = 0
    /// `recoverLeftovers` was called; the leftovers are listed when idle.
    private var recoveryRequested = false
    private var leftovers: [LeftoverMeeting] = []
    private var isQuitting = false
    private(set) var status: MeetingStatus = .idle
    /// The last finished meeting's Them stream was silent while the grant
    /// was unproven: the menu offers the Settings pane
    /// (`SystemAudioReadiness.issue(for:lastMeetingThemSilent:)`).
    private(set) var lastThemWasSilent = false

    /// `spool` keeps each meeting's audio and journal on disk (the app: a
    /// `FolderMeetingSpool`); if it can't make one, the meeting is kept in
    /// memory instead. `systemAudioPermission` is read when a meeting ends,
    /// to tell a silent Others apart from an unconfirmed permission;
    /// `keepAudio` (Settings › Notes › Keep meeting audio) too. `later` runs
    /// the next step of a recovery's read-back on a later main-loop turn.
    init(recorder: MeetingRecorder, engine: MeetingEngine, notes: MeetingNoteStore, archive: MeetingArchive,
         spool: MeetingSpooling, feedback: MeetingFeedback, activity: MeetingActivity, clock: Clock = SystemClock(),
         date: @escaping () -> Date = Date.init,
         systemAudioPermission: @escaping () -> SystemAudioPermission,
         keepAudio: @escaping () -> Bool = { false },
         maxSeconds: TimeInterval = MeetingSession.defaultMaxSeconds,
         locale: Locale = .current, timeZone: TimeZone = .current,
         later: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
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
        self.later = later
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
    }

    func stop() {
        guard case .recording(let meeting) = state else { return }
        Log.info("Meeting recording stopped after \(MeetingNote.clock(clock.now - meeting.startedAt)).")
        finish(meeting)
    }

    /// The app is quitting: stop, keep the audio, write what there is, then
    /// `done` (at once when idle, or when recovering a leftover: that stops
    /// and is picked up again next launch).
    func quit(_ done: @escaping () -> Void) {
        isQuitting = true
        leftovers = []
        recoveryRequested = false
        switch state {
        case .idle:
            done()
        case .recording(let meeting):
            meeting.quit = done
            finish(meeting)
        case .finishing(let meeting) where meeting.isRecovery, .transcribing(let meeting) where meeting.isRecovery:
            Log.info("Meeting recovery: Cado is quitting; the meeting with \(meeting.appName) is picked up next launch.")
            end()
            done()
        case .finishing(let meeting):
            meeting.quit = done
        case .transcribing(let meeting):
            meeting.quit = done
            wrapUpForQuit(meeting)
        }
    }

    /// Recovers the meetings earlier runs left unfinished (crashed, killed,
    /// lost power), oldest first, one at a time. Call when Cado can
    /// transcribe. While a meeting is under way nothing happens until it's
    /// over (its own spool is never touched); meanwhile, and while recovering,
    /// `start` is ignored as for any meeting still transcribing.
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
        meeting.spool.append(samples, for: speaker)
        checkSpool(meeting)
        chunked(side.chunker.append(samples), side, meeting)
    }

    /// The disk stopped taking the meeting's audio (full, folder gone): the
    /// spool now holds the rest in memory, so the meeting and its note go
    /// on; only crash recovery is lost. Said once.
    private func checkSpool(_ meeting: Meeting) {
        guard !meeting.toldSpoolFailed, let error = meeting.spool.writeError else { return }
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
        // Reload an idle-unloaded model for the tail while the streams finish.
        engine.prewarm()
        meeting.prewarmed = true
        for speaker in MeetingSpeaker.allCases where !meeting.side(speaker).ended {
            meeting.side(speaker).stream?.end { [weak self] in self?.streamEnded(meeting.id, speaker) }
        }
        allEnded(meeting)
    }

    /// Every sample of the stream has been delivered.
    private func streamEnded(_ id: Int, _ speaker: MeetingSpeaker) {
        guard let meeting = meeting(id), case .finishing = state else { return }
        let side = meeting.side(speaker)
        guard !side.ended else { return }
        endSide(side, meeting)
        allEnded(meeting)
    }

    /// No more audio for `side`: its chunker hands over the open chunk.
    private func endSide(_ side: Side, _ meeting: Meeting) {
        side.ended = true
        chunked(side.chunker.finish(), side, meeting)
    }

    private func allEnded(_ meeting: Meeting) {
        guard case .finishing(let m) = state, m === meeting, meeting.allEnded else { return }
        if meeting.quit != nil { return wrapUpForQuit(meeting) }
        state = .transcribing(meeting)
        report()
        let left = meeting.queue.count + (meeting.inFlight == nil ? 0 : 1)
        Log.info("Meeting: \(left) of \(meeting.total) passage(s) left to transcribe.")
        if meeting.hasNoWork { complete(meeting) }
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
    // max(S, E): nothing before that point is pending, and nothing
    // journaled lies after it, so each stretch of speech is transcribed
    // exactly once whichever step the crash interrupted.

    /// Queues the chunks a side's chunker emitted and journals its progress.
    private func chunked(_ chunks: [SpeechChunker.Chunk], _ side: Side, _ meeting: Meeting) {
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
        if case .transcribing(let m) = state, m === meeting, meeting.hasNoWork { complete(meeting) }
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

    // MARK: - Writing the note

    private func complete(_ meeting: Meeting) {
        endPrewarmIfHeld(meeting)
        let silence = themSilence(meeting)
        if !meeting.isRecovery { lastThemWasSilent = silence != nil }
        let turns = MeetingTranscript.turns(meeting.pieces)
        var caveats = caveats(meeting)
        if turns.isEmpty && meeting.failures.isEmpty {
            meeting.spool.discard()
            if meeting.isRecovery {
                Log.info("Meeting recovery: no speech in the meeting with \(meeting.appName); nothing to keep.")
            } else if meeting.sides.values.contains(where: { $0.startError == nil }) {   // else already told
                var body = "No speech was heard in the meeting with \(meeting.appName), so no note was saved."
                if let silence { body += " " + silence.detail }
                Log.info("Meeting: nothing was said; no note.")
                feedback.notify(title: "Nothing recorded", body: body)
            }
            return end()
        }
        let failed = !meeting.failures.isEmpty
        if failed, let folder = keep(meeting, note: nil) { caveats.append(.audioKept(folder)) }
        let note = MeetingNote(appName: meeting.appName, start: meeting.startDate, duration: meeting.duration,
                               turns: turns, caveats: caveats)
        let saved = save(note, meeting, audioKept: failed)
        if saved != nil, !failed, keepAudio() {
            if keep(meeting, note: nil) == nil {
                feedback.notify(title: "Couldn't keep the meeting's audio",
                                body: "The note was saved, but the audio couldn't be copied to Cado's Meeting Audio folder.")
            }
        }
        meeting.spool.discard()
        if let saved {
            var body = note.draft(locale: locale, timeZone: timeZone).title
            if silence != nil { body += " — no sound came from \(meeting.appName); see the note." }
            if failed { body += " Some of it couldn't be transcribed; see the note." }
            feedback.noteSaved(saved, title: meeting.isRecovery ? "Meeting note recovered" : "Meeting note saved",
                               body: body)
        }
        end()
    }

    /// Quitting: keep the audio, note what's transcribed so far, call back.
    private func wrapUpForQuit(_ meeting: Meeting) {
        guard let done = meeting.quit else { return }
        endPrewarmIfHeld(meeting)
        lastThemWasSilent = themSilence(meeting) != nil
        var caveats = caveats(meeting)
        caveats.append(.quitBeforeTranscribing)
        if let folder = keep(meeting, note: nil) { caveats.append(.audioKept(folder)) }
        let note = MeetingNote(appName: meeting.appName, start: meeting.startDate, duration: meeting.duration,
                               turns: MeetingTranscript.turns(meeting.pieces), caveats: caveats)
        save(note, meeting, audioKept: true)
        meeting.spool.discard()
        end()
        done()
    }

    /// Writes the note and returns its file; if that fails, puts it (and the
    /// audio, unless kept already) in the archive, says where, returns nil.
    @discardableResult
    private func save(_ note: MeetingNote, _ meeting: Meeting, audioKept: Bool) -> URL? {
        let draft = note.draft(locale: locale, timeZone: timeZone)
        do {
            let url = try notes.save(draft)
            Log.info("Meeting note saved: \(url.path)")
            return url
        } catch {
            Log.error("Couldn't save the meeting note: \(error.localizedDescription)")
            let markdown = NoteFrontMatter.render(title: draft.title, date: draft.date, kind: draft.kind,
                                                  duration: draft.duration, body: draft.body)
            if let folder = keep(meeting, note: markdown, audio: !audioKept) {
                feedback.notify(title: "Couldn't save the meeting note",
                                body: "\(error.localizedDescription) The transcript and audio are in \(folder.path).")
            } else {
                feedback.notify(title: "Couldn't save the meeting", body: error.localizedDescription)
            }
            return nil
        }
    }

    /// Copies the meeting's audio (streamed from the spool, as WAVs) and/or
    /// its note into its archive folder; returns the folder.
    private func keep(_ meeting: Meeting, note: String?, audio: Bool = true) -> URL? {
        let name = NotesLibrary.sanitise(title(meeting))
        do {
            let folder = try archive.keep(audio ? meeting.spool : nil, note: note, name: name, into: meeting.archived)
            meeting.archived = folder
            Log.info("Meeting audio kept in \(folder.path)")
            return folder
        } catch {
            Log.error("Couldn't keep the meeting's audio: \(error.localizedDescription)")
            return nil
        }
    }

    private func caveats(_ meeting: Meeting) -> [MeetingNote.Caveat] {
        var caveats: [MeetingNote.Caveat] = meeting.isRecovery ? [.recoveredAfterCrash] : []
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
        guard meeting.side(.them).startError == nil, meeting.spool.isSilent(.them) else { return nil }
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

    // MARK: - Crash recovery

    private func startNextRecovery() {
        guard !isQuitting, case .idle = state else { return }
        if recoveryRequested {
            recoveryRequested = false
            leftovers = spooling.leftovers()
            if !leftovers.isEmpty { Log.info("Meeting recovery: \(leftovers.count) unfinished meeting(s) found.") }
        }
        guard !leftovers.isEmpty else { return }
        recover(leftovers.removeFirst())
    }

    /// Rebuilds a leftover meeting from its journal, then reads back (and
    /// chunks) the audio from where the journal says it's safe to.
    private func recover(_ leftover: LeftoverMeeting) {
        meetingCount += 1
        let handle = leftover.handle
        let info = handle.meeting
        let meeting = Meeting(id: meetingCount, appName: info.appName, startedAt: clock.now,
                              startDate: info.startDate, spool: handle, me: nil, them: nil, isRecovery: true)
        var settled: [MeetingSpeaker: Int] = [:], doneThrough: [MeetingSpeaker: Int] = [:]
        var seen = Set<String>()
        var attempts = 0
        var stoppedAt: TimeInterval?
        func result(_ speaker: MeetingSpeaker, _ range: Range<Int>) -> Bool {
            guard seen.insert("\(speaker.spoolKey) \(range.lowerBound) \(range.upperBound)").inserted else { return false }
            meeting.done += 1
            meeting.total += 1
            doneThrough[speaker] = max(doneThrough[speaker] ?? 0, range.upperBound)
            return true
        }
        for event in leftover.events {
            switch event {
            case let .sideStarted(speaker, origin):
                if meeting.side(speaker).origin == nil { meeting.side(speaker).origin = origin }
            case let .sideFailed(speaker, reason):
                meeting.side(speaker).startError = reason
            case let .sideLost(speaker, at):
                meeting.side(speaker).lostAt = at
            case let .settled(speaker, through):
                settled[speaker] = max(settled[speaker] ?? 0, through)
            case let .transcribed(speaker, range, offset, segments):
                guard result(speaker, range) else { continue }
                meeting.pieces += segments.map { .init(speaker: speaker, start: offset + $0.start, text: $0.text) }
            case let .failed(speaker, range, reason):
                guard result(speaker, range) else { continue }
                meeting.failures.append(reason)
            case let .stopped(at, capReached):
                stoppedAt = at
                meeting.capReached = capReached
            case .recoveryStarted:
                attempts += 1
            }
        }
        var onDisk: TimeInterval = 0
        for side in meeting.sides.values {
            let count = handle.sampleCount(of: side.speaker)
            let from = min(max(settled[side.speaker] ?? 0, doneThrough[side.speaker] ?? 0), count)
            side.base = from
            side.cursor = from
            side.journaledSettled = from
            if count > 0 { onDisk = max(onDisk, (side.origin ?? 0) + Double(count) / AudioCapture.sampleRate) }
        }
        meeting.recoveredDuration = stoppedAt ?? onDisk
        state = .finishing(meeting)
        report()
        Log.info("Meeting recovery: the meeting with \(meeting.appName) from \(info.startDate) "
                 + "(\(meeting.done) passage(s) already transcribed, attempt \(attempts + 1)).")
        guard attempts < Self.maxRecoveryAttempts else {
            return giveUp(meeting, reason: "recovery was already begun \(attempts) times without finishing")
        }
        handle.record(.recoveryStarted)
        readBack(meeting.id)
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
            chunked(side.chunker.append(samples), side, meeting)
        }
        guard self.meeting(id) != nil else { return }
        if meeting.allEnded { return allEnded(meeting) }
        later { [weak self] in self?.readBack(id) }
    }

    /// A leftover that can't be turned into a note: its audio goes to the
    /// archive, the user is told where, and it leaves the spool so it isn't
    /// tried again. If even the audio can't be copied, it stays in the spool
    /// (and isn't transcribed again: the attempts are journaled).
    private func giveUp(_ meeting: Meeting, reason: String) {
        Log.error("Meeting recovery: giving up on the meeting with \(meeting.appName): \(reason).")
        let title = title(meeting)
        if let folder = keep(meeting, note: nil) {
            meeting.spool.discard()
            feedback.notify(title: "Couldn't recover a meeting",
                            body: "Cado quit unexpectedly during “\(title)”, and its note couldn't be recovered. "
                                + "The audio is kept in \(folder.path).")
        } else {
            feedback.notify(title: "Couldn't recover a meeting",
                            body: "Cado quit unexpectedly during “\(title)”, and its note couldn't be recovered. "
                                + "The audio stays in Cado's Meetings In Progress folder.")
        }
        end()
    }

    // MARK: - Helpers

    private func title(_ meeting: Meeting) -> String {
        MeetingNote.title(appName: meeting.appName, start: meeting.startDate, locale: locale, timeZone: timeZone)
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
            next = .transcribing(app: m.appName, done: 0, total: 0)
        case .transcribing(let m):
            next = .transcribing(app: m.appName, done: m.done, total: m.total)
        }
        guard next != status else { return }
        status = next
        activity.meetingStatusChanged(next)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
