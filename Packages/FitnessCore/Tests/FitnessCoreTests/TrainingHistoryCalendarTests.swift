import Foundation
import XCTest
@testable import FitnessCore

final class TrainingHistoryCalendarTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        value.firstWeekday = 1
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12,
                      calendar: Calendar? = nil) throws -> Date {
        try XCTUnwrap((calendar ?? self.calendar()).date(from: DateComponents(
            year: year, month: month, day: day, hour: hour)))
    }

    func testMondayStartDoesNotDependOnSystemFirstWeekday() throws {
        let calendar = calendar()
        let reference = try date(2026, 10, 27)
        let month = try TrainingHistoryMonth(containing: reference, sessions: [], calendar: calendar, now: reference)
        XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(month.days.first).date), 2)
        XCTAssertEqual(month.days.count, 35)
        XCTAssertEqual(month.days.filter(\.isInMonth).count, 31)
        XCTAssertEqual(month.days.filter(\.isToday).count, 1)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(month.days.first).date), 28)
    }

    func testLeapYearIncludesFebruary29() throws {
        let reference = try date(2024, 2, 20)
        let month = try TrainingHistoryMonth(containing: reference, sessions: [], calendar: calendar(), now: reference)
        XCTAssertEqual(month.days.filter(\.isInMonth).count, 29)
        XCTAssertTrue(month.days.contains { $0.isInMonth && calendar().component(.day, from: $0.date) == 29 })
    }

    func testActualFourAndSixWeekMonthsRatherThanAlwaysFortyTwoCells() throws {
        let february = try date(2021, 2, 7)
        let november = try date(2026, 11, 15)
        XCTAssertEqual(try TrainingHistoryMonth(containing: february, sessions: [], calendar: calendar(), now: february).days.count, 28)
        XCTAssertEqual(try TrainingHistoryMonth(containing: november, sessions: [], calendar: calendar(), now: november).days.count, 42)
    }

    func testNewYearGridIncludesAdjacentYearWithoutAddingItToMonthSummary() throws {
        let reference = try date(2027, 1, 7)
        let previous = WorkoutSession(name: "去年", startedAt: try date(2026, 12, 31))
        let january = WorkoutSession(name: "本月", startedAt: reference)
        let month = try TrainingHistoryMonth(containing: reference, sessions: [january, previous], calendar: calendar(), now: reference)
        XCTAssertEqual(month.sessions.map(\.id), [january.id])
        XCTAssertEqual(month.days.flatMap(\.sessions).count, 2)
        XCTAssertEqual(calendar().component(.year, from: try XCTUnwrap(month.days.first).date), 2026)
    }

    func testMultipleSessionsRemainIndividuallyReachableAndChronologicallySorted() throws {
        let reference = try date(2026, 10, 27)
        let first = WorkoutSession(name: "早上", startedAt: try date(2026, 10, 27, hour: 8))
        var second = WorkoutSession(name: "晚上", startedAt: try date(2026, 10, 27, hour: 18))
        try second.pause(at: second.startedAt.addingTimeInterval(30))
        let month = try TrainingHistoryMonth(containing: reference, sessions: [second, first], calendar: calendar(), now: reference)
        let day = try XCTUnwrap(month.days.first { $0.isToday })
        XCTAssertEqual(day.sessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(day.sessions.last?.status, .paused)
    }

    func testLocalMidnightUsesSessionStartNotEndOrUTCDate() throws {
        let utc = calendar("UTC")
        let instant = try date(2026, 10, 26, hour: 18, calendar: utc)
        var session = WorkoutSession(name: "跨午夜训练", startedAt: instant)
        try session.finish(early: true, at: instant.addingTimeInterval(8 * 3_600))
        let month = try TrainingHistoryMonth(containing: instant, sessions: [session], calendar: calendar(), now: instant)
        let bucket = try XCTUnwrap(month.days.first { !$0.sessions.isEmpty })
        XCTAssertEqual(calendar().component(.day, from: bucket.date), 27)
        let utcMonth = try TrainingHistoryMonth(containing: instant, sessions: [session], calendar: utc, now: instant)
        XCTAssertEqual(utc.component(.day, from: try XCTUnwrap(utcMonth.days.first { !$0.sessions.isEmpty }).date), 26)
    }

    func testDaylightSavingDaysRemainNaturalMidnightsWithoutDuplicateOrMissingDays() throws {
        let calendar = calendar("America/Los_Angeles")
        let reference = try date(2026, 3, 15, calendar: calendar)
        let month = try TrainingHistoryMonth(containing: reference, sessions: [], calendar: calendar, now: reference)
        let march = month.days.filter(\.isInMonth).map(\.date)
        XCTAssertEqual(Set(march).count, 31)
        XCTAssertTrue(march.allSatisfy { calendar.component(.hour, from: $0) == 0 })
        XCTAssertEqual(march.map { calendar.component(.day, from: $0) }, Array(1...31))
        XCTAssertTrue(zip(march, march.dropFirst()).contains { $1.timeIntervalSince($0) == 23 * 3_600 })
    }

    func testEmptyMonthNeverCreatesPlannedOrCompletedSessions() throws {
        let reference = try date(2026, 10, 27)
        let month = try TrainingHistoryMonth(containing: reference, sessions: [], calendar: calendar(), now: reference)
        XCTAssertTrue(month.sessions.isEmpty)
        XCTAssertTrue(month.days.allSatisfy { $0.sessions.isEmpty })
    }

    func testMetricsExcludeUnfinishedWarmupBodyweightAndAssistanceFromLoadWork() throws {
        let now = try date(2026, 10, 27)
        let total = Exercise(id: "test.total", name: "总重", englishName: "Total", kind: .strength,
                             metric: .repetitions, equipment: "杠铃", muscle: "胸部", loadConvention: .total)
        let perHand = Exercise(id: "test.perHand", name: "每手", englishName: "Per Hand", kind: .strength,
                               metric: .repetitions, equipment: "哑铃", muscle: "胸部", loadConvention: .perHand)
        let bodyweight = Exercise(id: "test.bodyweight", name: "徒手", englishName: "Bodyweight", kind: .bodyweight,
                                  metric: .repetitions, equipment: "徒手", muscle: "胸部", loadConvention: .bodyweight)
        let assisted = Exercise(id: "test.assisted", name: "辅助", englishName: "Assisted", kind: .strength,
                                metric: .repetitions, equipment: "器械", muscle: "背部", loadConvention: .assistance)
        let completed = LoggedSet(loadKG: 20, reps: 10, completedAt: now)
        let warmup = LoggedSet(kind: .warmup, loadKG: 10, reps: 10, completedAt: now)
        let unfinished = LoggedSet(loadKG: 100, reps: 10)
        let skipped = LoggedSet(loadKG: 100, reps: 10, skipped: true)
        let session = WorkoutSession(name: "混合", startedAt: now, exercises: [
            WorkoutExercise(exercise: total, sets: [completed, warmup, unfinished, skipped]),
            WorkoutExercise(exercise: perHand, sets: [completed]),
            WorkoutExercise(exercise: bodyweight, sets: [completed]),
            WorkoutExercise(exercise: assisted, sets: [completed])
        ])
        let metrics = TrainingHistoryMetrics(session: session, at: now)
        XCTAssertEqual(metrics.completedWorkingSets, 4)
        XCTAssertEqual(metrics.totalLoadRepetitionsKG, 200)
        XCTAssertEqual(metrics.perHandLoadRepetitionsKG, 200)
    }

    func testMetricsIncludeEarlyEndedResultsAndExcludeExplicitPauseDuration() throws {
        let start = try date(2026, 10, 27)
        var session = WorkoutSession(name: "提前结束", startedAt: start)
        try session.pause(at: start.addingTimeInterval(60))
        try session.resume(at: start.addingTimeInterval(300))
        try session.finish(early: true, at: start.addingTimeInterval(360))
        XCTAssertEqual(TrainingHistoryMetrics(session: session, at: start.addingTimeInterval(900)).durationSeconds, 120)
        XCTAssertEqual(session.status, .endedEarly)
    }
}
