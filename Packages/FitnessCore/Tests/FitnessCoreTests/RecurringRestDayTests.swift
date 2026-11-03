import XCTest
import Foundation
@testable import FitnessCore

/// A fortnightly appointment is a scheduling fact, not a medical restriction. These tests pin both
/// halves: it correctly marks the right Wednesdays as rest, and it never drifts to the wrong week.
final class RecurringRestDayTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)))
    }

    // MARK: - Which days count

    func testFortnightlyWednesdayRestsOnTheAnchorAndTwoWeeksLater() throws {
        let rule = RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-11-04")
        XCTAssertTrue(rule.applies(on: try date(2026, 11, 4), calendar: calendar), "起始日当天休息")
        XCTAssertFalse(rule.applies(on: try date(2026, 11, 11), calendar: calendar), "中间那个周三不休息")
        XCTAssertTrue(rule.applies(on: try date(2026, 11, 18), calendar: calendar), "两周后的周三休息")
        XCTAssertTrue(rule.applies(on: try date(2026, 12, 2), calendar: calendar))
    }

    func testOtherWeekdaysAreNeverAffected() throws {
        let rule = RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-11-04")
        XCTAssertFalse(rule.applies(on: try date(2026, 11, 5), calendar: calendar))
        XCTAssertFalse(rule.applies(on: try date(2026, 11, 6), calendar: calendar))
    }

    func testDatesBeforeTheAnchorAreNotRested() throws {
        let rule = RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-11-04")
        XCTAssertFalse(rule.applies(on: try date(2026, 10, 21), calendar: calendar),
                       "规则从起始日之后才生效，不回溯")
    }

    func testEveryWeekBehavesLikeAPlainWeekday() throws {
        let rule = RecurringRestDay(weekday: 3, everyWeeks: 1, anchorDateKey: "2026-11-04")
        XCTAssertTrue(rule.applies(on: try date(2026, 11, 11), calendar: calendar))
        XCTAssertTrue(rule.applies(on: try date(2026, 11, 18), calendar: calendar))
    }

    // MARK: - The anchor must agree with the weekday

    func testAnchorOnTheWrongWeekdayIsRejectedRatherThanGuessed() throws {
        // 2026-11-04 is a Wednesday; claiming Monday would silently rest the wrong day.
        let rule = RecurringRestDay(weekday: 1, everyWeeks: 2, anchorDateKey: "2026-11-04")
        XCTAssertThrowsError(try rule.validate())
    }

    func testInvalidIntervalAndDateAreRejected() {
        XCTAssertThrowsError(try RecurringRestDay(weekday: 3, everyWeeks: 0, anchorDateKey: "2026-11-04").validate())
        XCTAssertThrowsError(try RecurringRestDay(weekday: 3, everyWeeks: 99, anchorDateKey: "2026-11-04").validate())
        XCTAssertThrowsError(try RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-02-30").validate())
    }

    // MARK: - It reads as a schedule, not a diagnosis

    func testSummaryStatesTheScheduleInPlainWords() {
        let rule = RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-11-04", note: "中医埋线")
        XCTAssertEqual(rule.summary, "每 2 周的周三休息（中医埋线）")
        XCTAssertFalse(rule.summary.contains("诊断"))
        XCTAssertFalse(rule.summary.contains("受伤"))
    }

    // MARK: - The review uses it

    func testRestDateIncludesTheRecurringDay() throws {
        let review = TrainingConstraintReview(
            sourceText: "每两周周三做中医埋线", mode: .practicalOnly,
            painFreeConfirmed: true, allLimitsRepresentedConfirmed: true, confirmedAt: now,
            recurringRestDays: [RecurringRestDay(weekday: 3, everyWeeks: 2, anchorDateKey: "2026-11-04")])
        try review.validate()
        XCTAssertTrue(review.isRestDate(try date(2026, 11, 4), calendar: calendar))
        XCTAssertFalse(review.isRestDate(try date(2026, 11, 11), calendar: calendar))
        // A normal training day is unaffected.
        XCTAssertFalse(review.isRestDate(try date(2026, 11, 5), calendar: calendar))
    }

    private var now: Date { Date(timeIntervalSince1970: 1_790_000_000) }
}
