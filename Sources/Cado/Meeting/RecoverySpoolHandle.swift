import Foundation

/// A leftover's spool while it's recovered (#48): the handle itself, but an
/// attempt's start always lands in the journal before anything else the
/// attempt writes there.
///
/// An attempt the journal can't count (the disk is full) is counted by the
/// folder's name instead (`.tried`). That rename reopens the spool's files
/// (`FolderSpoolHandle.setMarks`), so once there's room again the attempt's
/// later writes reach the journal. Journaled while its start is only in the
/// name, they'd come before it on the next launch (a mark is read after the
/// journal's own events): the attempt would look as if it got nowhere, a
/// stalled one, and journaling the mark would make that order stick. So
/// while the start is only in the name, every write first tries
/// `.recoveryStarted` again; once it's in, the name drops `.tried`. Until
/// then nothing else of the attempt is written (the write reports failure,
/// as on a full disk, and the caller falls back as it would there). Marks
/// set without `.tried` end the attempt (a note saved or not, a pause), and
/// with it the retry.
///
/// Once an attempt's start (or a give-up) is journaled the journal works
/// again, so a `.waited` mark from an earlier launch goes (`journalWorks`).
final class RecoverySpoolHandle: MeetingSpoolHandle {
    let inner: MeetingSpoolHandle
    /// This attempt's start is in the name (`.tried`), not yet in the journal.
    private(set) var startOnlyInName = false

    init(_ inner: MeetingSpoolHandle) { self.inner = inner }

    /// Journals that an attempt begins, else marks it `.tried`; false if
    /// neither (or it was marked already: an attempt the guard can't count).
    func beginAttempt() -> Bool {
        if inner.record(.recoveryStarted) {
            journalWorks()
            return true
        }
        guard !inner.folderMarks.contains(.tried), inner.setMarks(inner.folderMarks.union([.tried])) else { return false }
        startOnlyInName = true
        return true
    }

    /// The journal took what recovery must write first: no more waiting for room.
    func journalWorks() {
        if inner.folderMarks.contains(.waited) { inner.setMarks(inner.folderMarks.subtracting([.waited])) }
    }

    /// The start, if it's still only in the name: true once it's journaled.
    private func journalStart() -> Bool {
        guard startOnlyInName else { return true }
        guard inner.record(.recoveryStarted) else { return false }
        startOnlyInName = false
        if !inner.setMarks(inner.folderMarks.subtracting([.tried, .waited])) {
            Log.error("Meeting recovery: couldn't rename the spool back after journaling its attempt.")
        }
        return true
    }

    func record(_ event: SpoolEvent) -> Bool { journalStart() && inner.record(event) }
    func recordFlushingLater(_ event: SpoolEvent) -> Bool { journalStart() && inner.recordFlushingLater(event) }

    func setMarks(_ marks: Set<SpoolFolderMark>) -> Bool {
        guard inner.setMarks(marks) else { return false }
        if !marks.contains(.tried) { startOnlyInName = false }
        return true
    }

    var meeting: SpooledMeeting { inner.meeting }
    func append(_ samples: [Float], for speaker: MeetingSpeaker) { inner.append(samples, for: speaker) }
    var writeError: Error? { inner.writeError }
    func sampleCount(of speaker: MeetingSpeaker) -> Int { inner.sampleCount(of: speaker) }
    func samples(_ range: Range<Int>, of speaker: MeetingSpeaker) throws -> [Float] { try inner.samples(range, of: speaker) }
    func isSilent(_ speaker: MeetingSpeaker) -> Bool { inner.isSilent(speaker) }
    func audio() -> SpoolAudio { inner.audio() }
    var hasFolder: Bool { inner.hasFolder }
    var hasAllAudioOnDisk: Bool { inner.hasAllAudioOnDisk }
    var location: URL? { inner.location }
    var folderMarks: Set<SpoolFolderMark> { inner.folderMarks }
    func moveFolder(into folder: URL) -> URL? { inner.moveFolder(into: folder) }
    func discard() { inner.discard() }
}
