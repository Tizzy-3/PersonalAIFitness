import Foundation
import XCTest
@testable import FitnessCore

final class HealthSafetyRegressionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T13:00:00Z")!
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sample(_ metric: HealthMetric = .restingHeartRate, value: Double = 60,
                        hoursAgo: Double = 1, durationHours: Double = 0,
                        source: String = "watch", category: Int? = nil, id: UUID = UUID()) -> HealthSampleRecord {
        let end = now.addingTimeInterval(-hoursAgo * 3_600)
        return HealthSampleRecord(id: id, metric: metric, startDate: end.addingTimeInterval(-durationHours * 3_600),
                                  endDate: end, value: value, sourceName: source,
                                  sourceBundleIdentifier: "test." + source, sleepCategory: category)
    }

    private func summary(_ metric: HealthMetric, _ samples: [HealthSampleRecord], at date: Date? = nil) -> HealthMetricSnapshot {
        HealthSampleMerger.summarize(metric: metric, samples: samples, anchor: Data([2]),
                                    queryStartDate: now.addingTimeInterval(-30 * 86_400),
                                    now: date ?? now, calendar: utc)
    }

    func testEmptyIncrementalBatchKeepsPriorValue() throws {
        let previous = sample()
        let merged = try HealthSampleMerger.merge(existing: [previous], added: [], deletedIDs: [],
                                                  metric: .restingHeartRate, now: now)
        XCTAssertEqual(merged, [previous])
        let result = summary(.restingHeartRate, merged)
        XCTAssertEqual(result.latestValue, 60)
        XCTAssertEqual(result.sampleCountInWindow, 1)
        XCTAssertEqual(result.anchor, Data([2]))
    }

    func testDuplicateUUIDDoesNotCreateExtraSample() throws {
        let previous = sample()
        let merged = try HealthSampleMerger.merge(existing: [previous], added: [previous, previous],
                                                  deletedIDs: [], metric: .restingHeartRate, now: now)
        XCTAssertEqual(merged.count, 1)
    }

    func testDeletingLatestFallsBackToPreviousRealSample() throws {
        let older = sample(value: 58, hoursAgo: 20)
        let latest = sample(value: 65)
        let merged = try HealthSampleMerger.merge(existing: [older, latest], added: [],
                                                  deletedIDs: [latest.id], metric: .restingHeartRate, now: now)
        XCTAssertEqual(summary(.restingHeartRate, merged).latestValue, 58)
        XCTAssertEqual(summary(.restingHeartRate, merged).latestSampleAt, older.endDate)
    }

    func testDeletingAllSamplesProducesNoSamplesWithoutInventedZero() throws {
        let previous = sample()
        let merged = try HealthSampleMerger.merge(existing: [previous], added: [], deletedIDs: [previous.id],
                                                  metric: .restingHeartRate, now: now)
        let result = summary(.restingHeartRate, merged)
        XCTAssertTrue(merged.isEmpty)
        XCTAssertEqual(result.state, .noSamples)
        XCTAssertNil(result.latestValue)
        XCTAssertEqual(result.anchor, Data([2]))
    }

    func testDeletionWinsWhenSameUUIDAppearsInAddedAndDeleted() throws {
        let value = sample()
        let merged = try HealthSampleMerger.merge(existing: [], added: [value], deletedIDs: [value.id],
                                                  metric: .restingHeartRate, now: now)
        XCTAssertTrue(merged.isEmpty)
    }

    func testLateArrivalDoesNotReplaceNewerMeasurement() throws {
        let latest = sample(value: 64, hoursAgo: 1)
        let late = sample(value: 57, hoursAgo: 24)
        let merged = try HealthSampleMerger.merge(existing: [latest], added: [late], deletedIDs: [],
                                                  metric: .restingHeartRate, now: now)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(summary(.restingHeartRate, merged).latestValue, 64)
    }

    func testExpiredCacheRecordIsPrunedWithoutAdvancingItsSampleDate() throws {
        let old = sample(hoursAgo: 31 * 24)
        XCTAssertTrue(try HealthSampleMerger.merge(existing: [old], added: [], deletedIDs: [],
                                                   metric: .restingHeartRate, now: now).isEmpty)
    }

    func testSleepUsesOneNightRatherThanAddingTwoNights() {
        let previousNight = sample(.sleepAnalysis, value: 0, hoursAgo: 29, durationHours: 10, category: 1)
        let latestNight = sample(.sleepAnalysis, value: 0, hoursAgo: 5, durationHours: 10, category: 1)
        let result = summary(.sleepAnalysis, [previousNight, latestNight])
        XCTAssertEqual(result.latestValue, 10)
        XCTAssertEqual(result.latestSampleAt, latestNight.endDate)
    }

    func testSleepOverlappingStagesAndSourcesUseIntervalUnion() {
        let first = sample(.sleepAnalysis, value: 0, hoursAgo: 7, durationHours: 8, source: "watch", category: 3)
        let overlap = sample(.sleepAnalysis, value: 0, hoursAgo: 6, durationHours: 8, source: "phone", category: 1)
        let deep = sample(.sleepAnalysis, value: 0, hoursAgo: 10, durationHours: 1, source: "watch", category: 4)
        let result = summary(.sleepAnalysis, [overlap, deep, first])
        XCTAssertEqual(result.latestValue, 9)
        XCTAssertTrue(result.sourceName?.contains("区间并集") == true)
    }

    func testInBedAndAwakeDoNotCountAsAsleep() {
        let inBed = sample(.sleepAnalysis, value: 0, hoursAgo: 4, durationHours: 12, category: 0)
        let awake = sample(.sleepAnalysis, value: 0, hoursAgo: 7, durationHours: 1, category: 2)
        let asleep = sample(.sleepAnalysis, value: 0, hoursAgo: 6, durationHours: 7, category: 5)
        XCTAssertEqual(summary(.sleepAnalysis, [inBed, awake, asleep]).latestValue, 7)
        XCTAssertEqual(summary(.sleepAnalysis, [inBed, awake]).state, .noSamples)
    }

    func testSleepClipsIntervalsToSelectedNight() {
        let longRecord = sample(.sleepAnalysis, value: 0, hoursAgo: 6, durationHours: 30, category: 1)
        // Selected window is yesterday noon to today noon; the record ends today at 07:00.
        XCTAssertEqual(summary(.sleepAnalysis, [longRecord]).latestValue, 19)
    }

    func testAfternoonNapDoesNotReplaceOvernightSleep() {
        let night = sample(.sleepAnalysis, value: 0, hoursAgo: 5, durationHours: 8, category: 1)
        let afternoon = now.addingTimeInterval(3 * 3_600)
        let nap = HealthSampleRecord(id: UUID(), metric: .sleepAnalysis,
                                    startDate: afternoon, endDate: afternoon.addingTimeInterval(3_600),
                                    value: 0, sourceName: "watch", sourceBundleIdentifier: "test.watch", sleepCategory: 1)
        XCTAssertEqual(summary(.sleepAnalysis, [night, nap], at: now.addingTimeInterval(7 * 3_600)).latestValue, 8)
    }

    func testSingleSourceDailyStepsDoNotDoubleCountPhoneAndWatch() {
        let watch = sample(.stepCount, value: 200, hoursAgo: 1, source: "watch")
        let phone = sample(.stepCount, value: 150, hoursAgo: 1, source: "phone")
        let result = summary(.stepCount, [watch, phone])
        XCTAssertEqual(result.latestValue, 200)
        XCTAssertTrue(result.sourceName?.contains("单一来源") == true)
    }

    func testMidnightDoesNotCarryYesterdayStepsIntoToday() {
        let previous = sample(.stepCount, value: 1_000, hoursAgo: 20)
        XCTAssertNil(summary(.stepCount, [previous]).latestValue)
    }

    func testLegacySnapshotDecodesWithoutLedgerAndNewSnapshotRoundTrips() throws {
        let old = HealthSnapshot(capturedAt: now, metrics: [summary(.restingHeartRate, [sample()])])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "cachedSamples")
        let decoded = try JSONDecoder().decode(HealthSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.cachedSamples)
        let updated = HealthSnapshot(capturedAt: now, metrics: old.metrics, cachedSamples: [sample()])
        XCTAssertEqual(try JSONDecoder().decode(HealthSnapshot.self, from: JSONEncoder().encode(updated)), updated)
        try updated.validate()
    }

    func testInvalidHealthBatchDoesNotMutateCallerCache() throws {
        let original = [sample()]
        let wrongType = sample(.bodyMass)
        XCTAssertThrowsError(try HealthSampleMerger.merge(existing: original, added: [wrongType], deletedIDs: [],
                                                         metric: .restingHeartRate, now: now))
        XCTAssertEqual(original.count, 1)
    }

    func testWorkoutDurationAlreadyInMinutesIsNotDividedAgain() {
        XCTAssertEqual(ReadinessEngine.describe(30, metric: .workoutDuration), "30 分钟")
    }

    private func profile() -> StructuredProfile {
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .confirmed, confirmedAt: now)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .confirmed, confirmedAt: now)
        profile.experience = .init(value: .beginner, provenance: .confirmed, confirmedAt: now)
        profile.weekdays = .init(value: [1, 3], provenance: .confirmed, confirmedAt: now)
        profile.minutesPerSession = .init(value: 30, provenance: .confirmed, confirmedAt: now)
        profile.equipment = .init(value: [.bodyweight], provenance: .confirmed, confirmedAt: now)
        profile.restrictions = .init(value: "无", provenance: .confirmed, confirmedAt: now)
        return profile
    }

    private func health(sleep: Double = 8, age: TimeInterval = 3_600) -> HealthSnapshot {
        HealthSnapshot(capturedAt: now.addingTimeInterval(-age), metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 10,
                                 latestValue: sleep, latestSampleAt: now.addingTimeInterval(-age),
                                 syncedAt: now.addingTimeInterval(-age), sourceName: "watch")
        ])
    }

    private func finishedSession() throws -> WorkoutSession {
        let start = now.addingTimeInterval(-86_400)
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        var session = WorkoutSession(name: "实际训练夹具", startedAt: start,
                                     exercises: [WorkoutExercise(exercise: exercise, sets: [LoggedSet(reps: 10)])])
        try session.completeSet(exerciseID: session.exercises[0].id, setID: session.exercises[0].sets[0].id,
                                at: start.addingTimeInterval(60))
        try session.finish(early: true, at: start.addingTimeInterval(120))
        return session
    }

    func testUnknownPainCannotBeOverriddenByCompleteHealthProfileAndHistory() throws {
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 5),
                                               health: health(), sessions: [finishedSession()], profile: profile(), now: now)
        XCTAssertEqual(result.safetyVerdict, .gatherData)
        XCTAssertEqual(result.verdict, .gatherData)
        XCTAssertTrue(result.todaySuggestion.contains("疼痛"))
    }

    func testKnownRestrictionCannotBeOverriddenByNoPainAndGoodSleep() throws {
        var restricted = profile()
        restricted.restrictions = .init(value: "膝部活动限制", provenance: .confirmed, confirmedAt: now)
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 5, painReported: false),
                                               health: health(), sessions: [finishedSession()], profile: restricted, now: now)
        XCTAssertEqual(result.safetyVerdict, .stop)
        XCTAssertEqual(result.verdict, .stop)
    }

    func testLowEnergyVerdictAndSuggestionAgree() throws {
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 1, painReported: false),
                                               health: health(), sessions: [finishedSession()], profile: profile(), now: now)
        XCTAssertEqual(result.verdict, .conservative)
        XCTAssertTrue(result.todaySuggestion.contains("保守"))
        XCTAssertFalse(result.todaySuggestion.contains("按计划推进"))
    }

    func testOldShortSleepNaturallyExpiresWithoutAnotherImport() throws {
        let snapshot = health(sleep: 4, age: 4 * 86_400)
        XCTAssertEqual(snapshot.metrics[0].state, .available)
        XCTAssertEqual(snapshot.metrics[0].effectiveState(at: now), .stale)
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 4, painReported: false),
                                               health: snapshot, sessions: [finishedSession()], profile: profile(), now: now)
        XCTAssertFalse(result.recoveryEvidence.contains { $0.contains("低于") })
        XCTAssertFalse(result.evidence.contains { $0.id == "health:sleepAnalysis" })
        XCTAssertTrue(result.limitations.contains { $0.contains("已过期") })
    }

    func testYesterdayCheckInCannotAnswerTodaysPainQuestion() throws {
        let old = PreWorkoutCheckIn(createdAt: now.addingTimeInterval(-86_400), energy: 5, painReported: false)
        let result = try ReadinessEngine.assess(checkIn: old, health: health(), sessions: [finishedSession()],
                                               profile: profile(), now: now)
        XCTAssertEqual(result.verdict, .gatherData)
        XCTAssertFalse(result.evidence.contains { $0.id.hasPrefix("checkin:") })
    }

    func testRecentTooHardFeedbackAndSorenessAffectRecommendation() throws {
        let session = try finishedSession()
        let feedback = SessionFeedback(sessionID: session.id, createdAt: now.addingTimeInterval(-86_000),
                                       completedWorkingSets: 1, totalSeconds: 120, tooHard: true)
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 4,
                                                                          sorenessLevel: 4, painReported: false),
                                               health: health(), sessions: [session], profile: profile(),
                                               sessionFeedback: [feedback], now: now)
        XCTAssertEqual(result.verdict, .conservative)
        XCTAssertTrue(result.recoveryEvidence.contains { $0.contains("酸痛") })
        XCTAssertTrue(result.evidence.contains { $0.id == "feedback:\(feedback.id.uuidString)" })
    }

    func testAvailableTimeShortageIsExplicitAndCannotSayNormal() throws {
        let result = try ReadinessEngine.assess(checkIn: PreWorkoutCheckIn(createdAt: now, energy: 5,
                                                                          painReported: false, availableMinutes: 15),
                                               health: health(), sessions: [finishedSession()], profile: profile(), now: now)
        XCTAssertEqual(result.verdict, .conservative)
        XCTAssertTrue(result.todaySuggestion.contains("时间不足"))
        XCTAssertTrue(result.recoveryEvidence.contains { $0.contains("15") && $0.contains("30") })
    }

    func testPreviousRulesAssessmentRemainsReadable() throws {
        var result = try ReadinessEngine.assess(checkIn: nil, health: nil, sessions: [], profile: StructuredProfile(), now: now)
        result.rulesVersion = "readiness-1"
        XCTAssertNoThrow(try result.validate())
    }
}
