import Foundation

/// A read-only projection of actual set results. Different load conventions deliberately remain
/// separate: a 10 kg dumbbell marked "per hand" is never silently doubled or added to total-load work.
public struct TrainingHistoryMetrics: Equatable, Sendable {
    public var completedWorkingSets: Int = 0
    public var totalLoadRepetitionsKG: Double = 0
    public var perHandLoadRepetitionsKG: Double = 0
    public var durationSeconds: Double = 0

    public init(session: WorkoutSession, at now: Date) {
        durationSeconds = session.elapsed(at: now)
        for item in session.exercises {
            for set in item.sets where set.kind == .working && set.isCompleted && !set.skipped {
                completedWorkingSets += 1
                guard item.exercise.kind == .strength, item.exercise.metric == .repetitions,
                      let load = set.loadKG, load.isFinite, load >= 0,
                      let reps = set.reps, reps > 0 else { continue }
                let work = load * Double(reps)
                guard work.isFinite else { continue }
                switch item.exercise.loadConvention {
                case .total: totalLoadRepetitionsKG += work
                case .perHand: perHandLoadRepetitionsKG += work
                case .bodyweight, .assistance: break
                }
            }
        }
    }
}

public struct TrainingHistoryDay: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let isInMonth: Bool
    public let isToday: Bool
    /// Every saved session is represented, including unfinished and zero-result sessions.
    public let sessions: [WorkoutSession]
}

/// Calendar arithmetic uses natural days rather than 86,400-second offsets, including across DST.
/// Monday is always the first column, independently of the caller's firstWeekday preference.
public struct TrainingHistoryMonth: Equatable, Sendable {
    public let monthStart: Date
    public let nextMonthStart: Date
    public let days: [TrainingHistoryDay]
    public let sessions: [WorkoutSession]
    public var numberOfWeeks: Int { days.count / 7 }

    public init(containing date: Date, sessions: [WorkoutSession], calendar: Calendar, now: Date) throws {
        try CoreValidation.date(date, name: "历史月份")
        try CoreValidation.date(now, name: "当前时间")
        var calendar = calendar
        calendar.firstWeekday = 2
        guard let interval = calendar.dateInterval(of: .month, for: date),
              let count = calendar.range(of: .day, in: .month, for: date)?.count else {
            throw CoreError.invalidInput("无法读取这个月的日历。")
        }
        monthStart = interval.start
        nextMonthStart = interval.end
        let offset = (calendar.component(.weekday, from: interval.start) + 5) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -offset, to: interval.start) else {
            throw CoreError.invalidInput("无法读取这个月的起始日期。")
        }
        let dayCount = ((offset + count + 6) / 7) * 7
        let grouped = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.startedAt) }
        var result: [TrainingHistoryDay] = []
        for index in 0..<dayCount {
            guard let day = calendar.date(byAdding: .day, value: index, to: gridStart) else {
                throw CoreError.invalidInput("日历超出支持范围。")
            }
            let records = (grouped[calendar.startOfDay(for: day)] ?? []).sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt < $1.startedAt
            }
            result.append(TrainingHistoryDay(date: day, isInMonth: day >= interval.start && day < interval.end,
                                             isToday: calendar.isDate(day, inSameDayAs: now), sessions: records))
        }
        days = result
        self.sessions = result.filter(\.isInMonth).flatMap(\.sessions)
    }
}
