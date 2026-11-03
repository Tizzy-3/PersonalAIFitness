import Foundation

/// A recurring appointment that takes a day out of training, e.g. "every two weeks on Wednesday".
///
/// This is deliberately *not* a medical restriction. Something like a fortnightly TCM thread-embedding
/// session is a scheduling fact — it says which day is unavailable, not what movements are unsafe —
/// and treating it as one kept blocking plan generation behind a clinical confirmation flow the person
/// could not complete.
///
/// The anchor date decides which weeks count. Without it there is no way to know whether "this
/// Wednesday" is one of the two, so it is required rather than guessed.
public struct RecurringRestDay: Codable, Equatable, Sendable {
    /// ISO weekday, Monday = 1 … Sunday = 7.
    public let weekday: Int
    /// Repeat every this many weeks. 1 means every week (equivalent to `excludedWeekdays`), 2 means
    /// every other week, and so on.
    public let everyWeeks: Int
    /// A date that must fall on `weekday`; it fixes which of the weeks are the affected ones.
    public let anchorDateKey: String
    public let note: String

    public init(weekday: Int, everyWeeks: Int, anchorDateKey: String, note: String = "") {
        self.weekday = weekday
        self.everyWeeks = everyWeeks
        self.anchorDateKey = anchorDateKey
        self.note = note
    }

    public static let maximumWeeks = 12

    public func validate() throws {
        guard (1...7).contains(weekday) else { throw CoreError.invalidInput("重复休息日需要一周内的某一天。") }
        guard (1...Self.maximumWeeks).contains(everyWeeks) else {
            throw CoreError.invalidInput("重复间隔需要在 1 至 \(Self.maximumWeeks) 周之间。")
        }
        guard TrainingConstraintReview.isValidDateKey(anchorDateKey) else {
            throw CoreError.invalidInput("重复休息日的起始日期无效。")
        }
        // An anchor on a different weekday cannot define "the Wednesday two weeks from now"; it would
        // silently schedule a different day than the one shown.
        let anchorWeekday = Self.weekday(of: anchorDateKey)
        guard anchorWeekday == weekday else {
            throw CoreError.invalidInput("起始日期必须落在这个星期几上，否则无法确定每几周的哪一天休息。")
        }
        guard note.count <= 200 else { throw CoreError.invalidInput("重复休息日说明过长。") }
    }

    /// Whether this recurring day falls on `date`.
    ///
    /// Weeks are counted from the anchor's own week, so a fortnightly rule anchored on a Wednesday is
    /// stable regardless of the app being opened on a Tuesday or a Thursday.
    public func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        var civil = Calendar(identifier: .gregorian)
        civil.timeZone = calendar.timeZone
        let day = civil.startOfDay(for: date)
        let weekdayIndex = ((civil.component(.weekday, from: day) + 5) % 7) + 1
        guard weekdayIndex == weekday else { return false }
        guard let anchor = Self.date(fromKey: anchorDateKey, calendar: civil) else { return false }
        let anchorDay = civil.startOfDay(for: anchor)
        guard day >= anchorDay else { return false }
        // Whole weeks between the two anchor-aligned days.
        let weeks = civil.dateComponents([.weekOfYear], from: anchorDay, to: day).weekOfYear ?? 0
        return weeks >= 0 && weeks % everyWeeks == 0
    }

    /// Human-readable summary used in the plan readback, e.g. 「每 2 周的周三休息（中医埋线）」.
    public var summary: String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        let day = names[max(0, min(6, weekday - 1))]
        let interval = everyWeeks == 1 ? "每周" : "每 \(everyWeeks) 周"
        let noteText = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return interval + "的" + day + "休息" + (noteText.isEmpty ? "" : "（\(noteText)）")
    }

    static func weekday(of dateKey: String, calendar: Calendar = .current) -> Int? {
        guard let date = date(fromKey: dateKey, calendar: calendar) else { return nil }
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        return ((civil.component(.weekday, from: date) + 5) % 7) + 1
    }

    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        guard TrainingConstraintReview.isValidDateKey(key) else { return nil }
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return civil.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
