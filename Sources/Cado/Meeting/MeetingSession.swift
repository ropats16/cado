import Foundation

/// One meeting at a time, started and stopped only from the menu:
///
///     idle → recording → finishing → transcribing → idle
///
/// Recording runs two independent streams: the mic ("Me") and the chosen
/// app's audio ("Them", never the whole Mac's). On stop, each stream is split
/// into speech chunks (`SpeechChunker`), the chunks are transcribed one at a
/// time through the shared engine queue, and the pieces are interleaved by
/// start time into Me/Them turns (`MeetingTranscript`) for a Markdown note in
/// the notes library (`MeetingNote`).
///
/// Rules worth knowing:
/// - Start is ignored unless idle; stop only while recording.
/// - Recording stops by itself at `maxSeconds`, with a notice; the note is
///   still written and says so. Both streams are held in memory, ~230 MB an
///   hour each (~920 MB together at the 2-hour cap). They grow in fixed
///   blocks (`SampleBlocks`), so growing never copies a stream; ending one
///   gathers it into one array, briefly ~1 MB over its size.
/// - Each stream's samples stay on its own wall-clock timeline: a source
///   restart mid-meeting is kept as silence (`AudioCapture`'s `keepsTime`),
///   so a chunk's offset is the stream's origin plus its sample position.
/// - A side that can't start, or stops by itself, gets a notice and a caveat
///   in the note; the other side keeps recording. With no side left
///   recording, the meeting stops.
/// - A Them stream that was silent throughout gets the readiness module's
///   hint (the permission may not be granted) in the note and the notice,
///   unless this run already proved the grant; `lastThemWasSilent` lets the
///   menu offer the Settings pane afterwards.
/// - Chunks go to the engine one at a time, so a dictation waits for at most
///   one chunk. Dictation is refused while recording (`blocksDictation`).
/// - A meeting where no speech was transcribed writes no note; a notice says
///   so. Failed chunks don't lose the meeting: the note keeps what was
///   transcribed, and the audio is kept (`MeetingArchive`) and named in it.
///   A note that can't be saved goes to the archive with the audio.
/// - `quit` (the app is quitting) stops, keeps the audio, writes a note with
///   whatever was transcribed so far plus where the audio is, then calls back.
/// - Each meeting gets an id; callbacks for any other meeting are ignored.
///
/// Main-thread only.
final class MeetingSession {
    /// The tracer's hard cap on one meeting (#31 makes long ones chunked and
    /// crash-safe).
    static let defaultMaxSeconds: TimeInterval = 2 * 3600

    static let dictationNotice = DictationBusyNotice(
        title: "Meeting recording",
        body: "Dictation is off while a meeting records. Stop the recording from the Cado menu first.")

    private final class Side {
        let stream: MeetingStream
        /// Seconds after the meeting's start when the stream started.
        var origin: TimeInterval?
        var startError: String?
        /// Seconds after the meeting's start when the source stopped by itself.
        var lostAt: TimeInterval?
        /// Set once the stream has ended (empty if it never started).
        var samples: [Float]?
        var isLive: Bool { startError == nil && lostAt == nil }
        init(_ stream: MeetingStream) { self.stream = stream }
    }

    private struct Job {
        let speaker: MeetingSpeaker
        let range: Range<Int>
        /// Seconds from the meeting's start.
        let offset: TimeInterval
    }

    private final class Meeting {
        let id: Int
        let app: MeetingApp
        let startedAt: TimeInterval
        let startDate: Date
        let sides: [MeetingSpeaker: Side]
        var stoppedAt: TimeInterval?
        var capReached = false
        var quit: (() -> Void)?
        var jobs: [Job] = []
        var total = 0
        var done = 0
        var pieces: [MeetingTranscript.Piece] = []
        var failures: [String] = []

        init(id: Int, app: MeetingApp, startedAt: TimeInterval, startDate: Date, me: MeetingStream, them: MeetingStream) {
            self.id = id
            self.app = app
            self.startedAt = startedAt
            self.startDate = startDate
            sides = [.me: Side(me), .them: Side(them)]
        }

        func side(_ speaker: MeetingSpeaker) -> Side { sides[speaker]! }
        var duration: TimeInterval { (stoppedAt ?? startedAt) - startedAt }
    }

    private enum State {
        case idle
        case recording(Meeting)
        /// Stopped; waiting for both streams' samples.
        case finishing(Meeting)
        case transcribing(Meeting)
    }

    private let recorder: MeetingRecorder
    private let engine: MeetingEngine
    private let notes: MeetingNoteStore
    private let archive: MeetingArchive
    private let feedback: MeetingFeedback
    private let activity: MeetingActivity
    private let clock: Clock
    private let date: () -> Date
    private let systemAudioPermission: () -> SystemAudioPermission
    private let locale: Locale
    private let timeZone: TimeZone
    let maxSeconds: TimeInterval

    private var state: State = .idle
    private var timer: ClockTimer?
    private var meetingCount = 0
    private(set) var status: MeetingStatus = .idle
    /// The last finished meeting's Them stream was silent while the grant
    /// was unproven: the menu offers the Settings pane
    /// (`SystemAudioReadiness.issue(for:lastMeetingThemSilent:)`).
    private(set) var lastThemWasSilent = false

    /// `systemAudioPermission` is read when a meeting ends, to tell a
    /// silent Them apart from an unconfirmed permission.
    init(recorder: MeetingRecorder, engine: MeetingEngine, notes: MeetingNoteStore, archive: MeetingArchive,
         feedback: MeetingFeedback, activity: MeetingActivity, clock: Clock = SystemClock(),
         date: @escaping () -> Date = Date.init,
         systemAudioPermission: @escaping () -> SystemAudioPermission,
         maxSeconds: TimeInterval = MeetingSession.defaultMaxSeconds,
         locale: Locale = .current, timeZone: TimeZone = .current) {
        self.recorder = recorder
        self.engine = engine
        self.notes = notes
        self.archive = archive
        self.feedback = feedback
        self.activity = activity
        self.clock = clock
        self.date = date
        self.systemAudioPermission = systemAudioPermission
        self.maxSeconds = maxSeconds
        self.locale = locale
        self.timeZone = timeZone
    }

    /// Recording (or about to stop): the mic is the meeting's, so a dictation
    /// press is refused with `dictationNotice` (dictation during meetings: #33).
    var blocksDictation: Bool {
        switch state {
        case .recording, .finishing: return true
        case .idle, .transcribing: return false
        }
    }

    /// `dictationNotice` while `blocksDictation`: `DictationSession`'s `busy`.
    var dictationBusy: DictationBusyNotice? { blocksDictation ? Self.dictationNotice : nil }

    // MARK: - Intents

    func start(_ app: MeetingApp) {
        guard case .idle = state else { return }
        meetingCount += 1
        let id = meetingCount
        let streams = recorder.streams(for: app, maxSeconds: maxSeconds)
        let meeting = Meeting(id: id, app: app, startedAt: clock.now, startDate: date(),
                              me: streams.me, them: streams.them)
        state = .recording(meeting)
        Log.info("Meeting recording started: \(app.name) (\(app.bundleID)) and the microphone.")
        timer = clock.schedule(after: maxSeconds) { [weak self] in self?.capReached(id) }
        report()
        for speaker in MeetingSpeaker.allCases {
            let stream = meeting.side(speaker).stream
            stream.onSourceLost = { [weak self] in self?.lost(id, speaker) }
            stream.begin { [weak self] error in self?.started(id, speaker, error) }
        }
    }

    func stop() {
        guard case .recording(let meeting) = state else { return }
        Log.info("Meeting recording stopped after \(MeetingNote.clock(clock.now - meeting.startedAt)).")
        finish(meeting)
    }

    /// The app is quitting: stop, keep the audio, write what there is, then
    /// `done` (at once when idle).
    func quit(_ done: @escaping () -> Void) {
        switch state {
        case .idle:
            done()
        case .recording(let meeting):
            meeting.quit = done
            finish(meeting)
        case .finishing(let meeting):
            meeting.quit = done
        case .transcribing(let meeting):
            meeting.quit = done
            wrapUpForQuit(meeting)
        }
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

    private func started(_ id: Int, _ speaker: MeetingSpeaker, _ error: Error?) {
        guard let meeting = meeting(id) else { return }
        let side = meeting.side(speaker)
        guard side.samples == nil, side.startError == nil else { return }
        guard let error else {
            side.origin = clock.now - meeting.startedAt
            return
        }
        Log.error("Meeting: couldn't record \(describe(speaker, meeting)): \(error.localizedDescription)")
        side.startError = error.localizedDescription
        side.samples = []
        feedback.notify(title: "Couldn't record \(describe(speaker, meeting))", body: error.localizedDescription)
        sideStopped(meeting)
    }

    private func lost(_ id: Int, _ speaker: MeetingSpeaker) {
        guard let meeting = meeting(id), case .recording = state else { return }
        let side = meeting.side(speaker)
        guard side.isLive else { return }
        side.lostAt = clock.now - meeting.startedAt
        Log.error("Meeting: \(describe(speaker, meeting)) stopped recording by itself.")
        let other = speaker == .me ? "\(meeting.app.name)'s audio" : "your microphone"
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
        state = .finishing(meeting)
        report()
        engine.prewarm()   // reload an idle-unloaded model while the streams finish
        for speaker in MeetingSpeaker.allCases where meeting.side(speaker).samples == nil {
            meeting.side(speaker).stream.end { [weak self] samples in
                self?.captured(meeting.id, speaker, samples)
            }
        }
        allCaptured(meeting)
    }

    private func captured(_ id: Int, _ speaker: MeetingSpeaker, _ samples: [Float]) {
        guard let meeting = meeting(id), case .finishing = state else { return }
        meeting.side(speaker).samples = samples
        allCaptured(meeting)
    }

    private func allCaptured(_ meeting: Meeting) {
        guard case .finishing = state, meeting.sides.values.allSatisfy({ $0.samples != nil }) else { return }
        if meeting.quit != nil { return wrapUpForQuit(meeting) }
        transcribe(meeting)
    }

    // MARK: - Transcription

    private func transcribe(_ meeting: Meeting) {
        var jobs: [Job] = []
        for speaker in MeetingSpeaker.allCases {
            let side = meeting.side(speaker)
            let origin = side.origin ?? 0
            for chunk in SpeechChunker.chunks(side.samples ?? []) {
                jobs.append(Job(speaker: speaker, range: chunk.start..<chunk.end,
                                offset: origin + Double(chunk.start) / AudioCapture.sampleRate))
            }
        }
        // In time order, so what's done at any point is the meeting so far.
        meeting.jobs = jobs.sorted { $0.offset < $1.offset }
        meeting.total = jobs.count
        state = .transcribing(meeting)
        report()
        Log.info("Meeting: transcribing \(jobs.count) passage(s).")
        guard !meeting.jobs.isEmpty else {
            engine.endPrewarm()
            return complete(meeting)
        }
        submitNext(meeting)
    }

    private func submitNext(_ meeting: Meeting) {
        guard let job = meeting.jobs.first, let samples = meeting.side(job.speaker).samples else { return }
        engine.transcribe(Array(samples[job.range])) { [weak self] result in
            self?.transcribed(meeting.id, result)
        }
    }

    private func transcribed(_ id: Int, _ result: Result<Transcript, Error>) {
        guard let meeting = meeting(id), case .transcribing = state, !meeting.jobs.isEmpty else { return }
        let job = meeting.jobs.removeFirst()
        meeting.done += 1
        switch result {
        case .success(let transcript):
            for segment in NonSpeechFilter.filter(transcript.segments) {
                meeting.pieces.append(.init(speaker: job.speaker, start: job.offset + segment.start, text: segment.text))
            }
        case .failure(let error):
            Log.error("Meeting: a passage failed to transcribe: \(error.localizedDescription)")
            meeting.failures.append(error.localizedDescription)
        }
        report()
        meeting.jobs.isEmpty ? complete(meeting) : submitNext(meeting)
    }

    // MARK: - Writing the note

    private func complete(_ meeting: Meeting) {
        lastThemWasSilent = themSilence(meeting) != nil
        let turns = MeetingTranscript.turns(meeting.pieces)
        var caveats = caveats(meeting)
        if turns.isEmpty && meeting.failures.isEmpty {
            end()
            guard meeting.sides.values.contains(where: { $0.startError == nil }) else { return }   // already told
            var body = "No speech was heard in the meeting with \(meeting.app.name), so no note was saved."
            if let issue = themSilence(meeting) { body += " " + issue.detail }
            Log.info("Meeting: nothing was said; no note.")
            feedback.notify(title: "Nothing recorded", body: body)
            return
        }
        if !meeting.failures.isEmpty, let folder = keep(meeting, note: nil) { caveats.append(.audioKept(folder)) }
        let note = MeetingNote(appName: meeting.app.name, start: meeting.startDate, duration: meeting.duration,
                               turns: turns, caveats: caveats)
        let saved = save(note, meeting, audioKept: !meeting.failures.isEmpty)
        end()
        guard saved else { return }
        var body = note.draft(locale: locale, timeZone: timeZone).title
        if themSilence(meeting) != nil { body += " — no sound came from \(meeting.app.name); see the note." }
        if !meeting.failures.isEmpty { body += " Some of it couldn't be transcribed; see the note." }
        feedback.notify(title: "Meeting note saved", body: body)
    }

    /// Quitting: keep the audio, note what's transcribed so far, call back.
    private func wrapUpForQuit(_ meeting: Meeting) {
        guard let done = meeting.quit else { return }
        lastThemWasSilent = themSilence(meeting) != nil
        var caveats = caveats(meeting)
        caveats.append(.quitBeforeTranscribing)
        if let folder = keep(meeting, note: nil) { caveats.append(.audioKept(folder)) }
        let note = MeetingNote(appName: meeting.app.name, start: meeting.startDate, duration: meeting.duration,
                               turns: MeetingTranscript.turns(meeting.pieces), caveats: caveats)
        _ = save(note, meeting, audioKept: true)
        end()
        done()
    }

    /// Writes the note; if that fails, puts it (and the audio, unless kept
    /// already) in the archive and says where.
    private func save(_ note: MeetingNote, _ meeting: Meeting, audioKept: Bool) -> Bool {
        let draft = note.draft(locale: locale, timeZone: timeZone)
        do {
            let url = try notes.save(draft)
            Log.info("Meeting note saved: \(url.path)")
            return true
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
            return false
        }
    }

    private func keep(_ meeting: Meeting, note: String?, audio: Bool = true) -> URL? {
        let tracks = audio ? MeetingSpeaker.allCases.compactMap { speaker in
            meeting.side(speaker).samples.flatMap { $0.isEmpty ? nil : MeetingAudio(speaker: speaker, samples: $0) }
        } : []
        let name = NotesLibrary.sanitise(MeetingNote.title(appName: meeting.app.name, start: meeting.startDate,
                                                           locale: locale, timeZone: timeZone))
        do {
            let folder = try archive.keep(tracks, note: note, name: name)
            Log.info("Meeting audio kept in \(folder.path)")
            return folder
        } catch {
            Log.error("Couldn't keep the meeting's audio: \(error.localizedDescription)")
            return nil
        }
    }

    private func caveats(_ meeting: Meeting) -> [MeetingNote.Caveat] {
        var caveats: [MeetingNote.Caveat] = []
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
        let them = meeting.side(.them)
        guard them.startError == nil, let samples = them.samples, !samples.contains(where: { $0 != 0 }) else { return nil }
        return SystemAudioReadiness.issue(afterCaptureHeardSound: false, permission: systemAudioPermission())
    }

    private func end() {
        state = .idle
        report()
    }

    // MARK: - Helpers

    private func describe(_ speaker: MeetingSpeaker, _ meeting: Meeting) -> String {
        speaker == .me ? "your microphone" : "\(meeting.app.name)'s audio"
    }

    private func report() {
        let next: MeetingStatus
        switch state {
        case .idle:
            next = .idle
        case .recording(let m):
            next = .recording(app: m.app.name, startedAt: m.startedAt,
                              lost: Set(MeetingSpeaker.allCases.filter { !m.side($0).isLive }))
        case .finishing(let m):
            next = .transcribing(app: m.app.name, done: 0, total: 0)
        case .transcribing(let m):
            next = .transcribing(app: m.app.name, done: m.done, total: m.total)
        }
        guard next != status else { return }
        status = next
        activity.meetingStatusChanged(next)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
