import Foundation

/// The max meeting length (#32): Settings › Meetings, `maxMeetingMinutes`.
/// A meeting that reaches it stops by itself, with a notice; its note is
/// written as usual and says so. Pure.
enum MeetingLimit {
    static let defaultMinutes: Double = 120
    /// What Settings offers, in minutes; 0 = Off.
    static let choices: [Double] = [30, 60, 120, 180, 240, 0]
    /// Off still stops a meeting after a day, so one left running can't fill
    /// the disk (about 5 GB a side).
    static let backstopSeconds: TimeInterval = 24 * 3600

    /// The cap for `minutes` (<= 0 = Off: nil).
    static func seconds(minutes: Double) -> TimeInterval? {
        minutes > 0 ? minutes * 60 : nil
    }

    /// The cap a meeting runs under: the setting (nil or <= 0 = Off), never
    /// past the backstop (a hand-edited huge value would skip it).
    static func cap(seconds: TimeInterval?) -> TimeInterval {
        guard let seconds, seconds > 0 else { return backstopSeconds }
        return min(seconds, backstopSeconds)
    }

    /// "30 min", "1 hour", "2 hours", "90 min", or "Off" for `<= 0`.
    static func label(_ minutes: Double) -> String {
        guard minutes > 0 else { return "Off" }
        let whole = Int(minutes.rounded())
        guard whole % 60 == 0 else { return "\(whole) min" }
        return whole == 60 ? "1 hour" : "\(whole / 60) hours"
    }

    /// "10 minutes", "1 hour", "2 hours", "90 minutes", for sentences.
    static func phrase(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
