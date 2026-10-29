import Foundation
import XCTest
@testable import FitnessCore

/// Synthetic restrictions only. No personal medical narrative is part of these fixtures.
final class TrainingConstraintPlanningTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var utc: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func profile() -> StructuredProfile {
        var value = StructuredProfile()
        value.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now)
        value.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: now)
        value.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now)
        value.weekdays = .init(value: [1, 3, 5], provenance: .stated, confirmedAt: now)
        value.minutesPerSession = .init(value: 35, provenance: .stated, confirmedAt: now)
        value.equipment = .init(value: [.bodyweight, .walkingSpace, .dumbbells, .bench, .stableSupport], provenance: .stated, confirmedAt: now)
        value.restrictions = .init(value: "保留本人描述的安排与动作限制", provenance: .stated, confirmedAt: now)
        return value
    }
    private func review(mode: ConstraintReviewMode = .practicalOnly) -> TrainingConstraintReview {
        TrainingConstraintReview(sourceText: profile().restrictions.value!, mode: mode,
            painFreeConfirmed: true, allLimitsRepresentedConfirmed: true, confirmedAt: now)
    }
    private func reviewed(_ review: TrainingConstraintReview? = nil) throws -> InterviewSession {
        var session = InterviewSession(createdAt: now, profile: profile())
        try session.confirmConstraintReview(review ?? self.review(), at: now)
        return session
    }

    func testCompleteFactsWithUnreviewedRestrictionsDoNotClaimReady() {
        let session = InterviewSession(createdAt: now, phase: .ready, profile: profile())
        XCTAssertTrue(session.profile.isReadyForPlanning, "This property means complete facts, not permission")
        XCTAssertEqual(session.derivedPhase, .awaitingReview)
        let eligibility = session.planningEligibility(at: now)
        XCTAssertFalse(eligibility.canGenerate)
        XCTAssertTrue(eligibility.needsConstraintReview)
        XCTAssertThrowsError(try session.profile.planningInput(at: now))
    }

    func testConfirmedPracticalBoundariesProduceARealPlanWithoutErasingOriginalText() throws {
        var boundaries = review()
        boundaries.excludedWeekdays = [3]
        boundaries.avoidedPositions = [.kneeling, .floorWork]
        boundaries.excludedExerciseIDs = ["builtin.goblet-squat"]
        boundaries.maxSessionMinutes = 20
        let session = try reviewed(boundaries)
        XCTAssertEqual(session.profile.restrictions.value, profile().restrictions.value)
        XCTAssertTrue(session.planningEligibility(at: now).canGenerate)
        let input = try session.profile.planningInput(at: now)
        XCTAssertEqual(input.safety, .reviewedConstraints)
        XCTAssertEqual(input.weekdays, [1, 5])
        XCTAssertEqual(input.minutesPerSession, 20)
        let pool = try PlannerEngine.candidatePool(input: input)
        XCTAssertTrue(Set(pool.values.flatMap { $0 }).isDisjoint(with: boundaries.effectiveExcludedExerciseIDs))
        for option in try PlannerEngine.options(for: input) {
            try option.validate(input: input)
            XCTAssertTrue(option.days[2].isRestDay)
            XCTAssertTrue(option.days.allSatisfy { $0.estimatedMinutesUpper <= 20 })
        }
    }

    func testProfessionalBoundariesNeedBothRecordedGuidanceAndExplicitWhitelist() throws {
        var boundaries = review(mode: .professionalBoundaries)
        XCTAssertThrowsError(try boundaries.validate())
        boundaries.professionalGuidanceNote = "合成测试：已明确允许下面列出的活动，其他活动不加入。"
        XCTAssertThrowsError(try boundaries.validate())
        boundaries.allowedExerciseIDs = ["builtin.bodyweight-squat", "builtin.incline-push-up", "builtin.walking"]
        let session = try reviewed(boundaries)
        let input = try session.profile.planningInput(at: now)
        let pool = try PlannerEngine.candidatePool(input: input)
        XCTAssertTrue(Set(pool.values.flatMap { $0 }).isSubset(of: Set(boundaries.allowedExerciseIDs!)))
        let option = try PlannerEngine.synthesize(input: input, choices: pool.mapValues { $0[0] })
        XCTAssertTrue(Set(option.days.flatMap(\.items).map(\.exerciseID)).isSubset(of: Set(boundaries.allowedExerciseIDs!)))
        XCTAssertThrowsError(try PlannerEngine.synthesize(input: input, choices: ["push": "builtin.dumbbell-bench-press"]))
    }

    func testUnsupportedSafetyPermissionCannotBeCreatedByAddingAReview() throws {
        var boundaries = review(); boundaries.painFreeConfirmed = false
        XCTAssertThrowsError(try reviewed(boundaries))
        boundaries = review(); boundaries.allLimitsRepresentedConfirmed = false
        XCTAssertThrowsError(try reviewed(boundaries))
        boundaries = review(); boundaries.rulesVersion = "invented-version"
        XCTAssertThrowsError(try boundaries.validate())
        boundaries = review(); boundaries.excludedExerciseIDs = ["invented-by-model"]
        XCTAssertThrowsError(try boundaries.validate())
    }

    func testFrozenInputsCannotOmitExclusionsWeekdaysOrTimeCaps() throws {
        var boundaries = review(); boundaries.excludedWeekdays = [3]
        boundaries.excludedExerciseIDs = ["builtin.goblet-squat"]; boundaries.maxSessionMinutes = 20
        let session = try reviewed(boundaries)
        let good = try session.profile.planningInput(at: now)
        var changed = good; changed.excludedExerciseIDs = []
        XCTAssertThrowsError(try changed.validate())
        changed = good; changed.weekdays = [1, 3, 5]
        XCTAssertThrowsError(try changed.validate())
        changed = good; changed.minutesPerSession = 30
        XCTAssertThrowsError(try changed.validate())
        changed = good; changed.safety = .noKnownRestrictions
        XCTAssertThrowsError(try changed.validate())
    }

    func testChangedRawRestrictionsAndLegacyProfileRequireNewReview() throws {
        var session = try reviewed()
        session.profile.restrictions.value = "新补充的不同安排"
        XCTAssertThrowsError(try session.profile.planningInput(at: now))
        let original = try reviewed()
        XCTAssertFalse(original.planningEligibility(legacyRestrictions: "旧档案的另一项限制", at: now).canGenerate)
        var snapshot = AppSnapshot(exportedAt: now, interview: original)
        snapshot.profile.restrictions = "旧档案的另一项限制"
        XCTAssertThrowsError(try PlanningDraft.make(input: original.profile.planningInput(at: now), snapshot: snapshot, at: now))
    }

    func testFreshnessStopsNewGenerationTomorrowButDoesNotInvalidateFrozenHistory() throws {
        let session = try reviewed()
        XCTAssertFalse(session.planningEligibility(at: now.addingTimeInterval(86_400)).canGenerate)
        XCTAssertThrowsError(try session.profile.planningInput(at: now.addingTimeInterval(86_400)))
        let snapshot = AppSnapshot(exportedAt: now, interview: session)
        let input = try session.profile.planningInput(at: now)
        let reply = PersonalizedPlanReply(choices: try PlannerEngine.candidatePool(input: input).mapValues { $0[0] }, explanation: "合成测试中只选合法池内动作", limitations: [])
        let draft = try PlanningDraft.makePersonalized(profile: session.profile, reply: reply, snapshot: snapshot, providerHost: "example.invalid", model: "fixture", at: now)
        let restored = try JSONDecoder().decode(PlanningDraft.self, from: JSONEncoder().encode(draft))
        try restored.validate()
        XCTAssertEqual(restored.personalization?.profile.constraintReview, session.profile.constraintReview)
    }

    func testNewNarrativeCannotBeSilencedByReusingEarlierReview() throws {
        var session = try reviewed()
        try session.addNarrative("合成测试：又补充了一项需要核对的安排", at: now.addingTimeInterval(60))
        XCTAssertTrue(session.needsSafetyReview)
        XCTAssertFalse(session.planningEligibility(at: now.addingTimeInterval(60)).canGenerate)
        XCTAssertThrowsError(try session.confirmConstraintReview(review(), at: now.addingTimeInterval(60)))
        XCTAssertEqual(session.profile.restrictions.value, profile().restrictions.value)
    }

    func testOldProfileAndInputJSONDecodeWithoutFabricatingAReview() throws {
        var old = profile(); old.restrictions = .init(value: "无", provenance: .stated, confirmedAt: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "constraintReview")
        let restored = try JSONDecoder().decode(StructuredProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.constraintReview)
        let input = try restored.planningInput(at: now)
        var inputObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        inputObject.removeValue(forKey: "constraintReview")
        let inputRestored = try JSONDecoder().decode(PlanningInput.self, from: JSONSerialization.data(withJSONObject: inputObject))
        XCTAssertEqual(inputRestored, input)
        XCTAssertNil(inputRestored.constraintReview)
    }

    func testRestDatesUseActualCivilDatesAndRejectImpossibleDates() throws {
        var boundaries = review()
        boundaries.restDateKeys = ["2026-10-29"]
        try boundaries.validate()
        let instant = ISO8601DateFormatter().date(from: "2026-10-28T16:30:00Z")!
        var shanghai = utc; shanghai.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        XCTAssertTrue(boundaries.isRestDate(instant, calendar: shanghai))
        XCTAssertFalse(boundaries.isRestDate(instant, calendar: utc))
        XCTAssertFalse(TrainingConstraintReview.isValidDateKey("2026-02-30"))
        boundaries.restDateKeys = ["2026-02-30"]
        XCTAssertThrowsError(try boundaries.validate())
    }

    func testExplicitRestDateReducesActualScheduledReviewDenominator() throws {
        func program(resting: Bool) throws -> WeeklyProgram {
            var boundaries = review()
            boundaries.restDateKeys = resting ? [TrainingConstraintReview.dateKey(now, calendar: utc)] : []
            var session = try reviewed(boundaries)
            session.profile.weekdays = .init(value: Array(1...7), provenance: .stated, confirmedAt: now)
            let input = try session.profile.planningInput(at: now)
            let draft = try PlanningDraft.make(input: input, snapshot: AppSnapshot(exportedAt: now, interview: session), at: now)
            let option = try XCTUnwrap(draft.options.first)
            let ids = Dictionary(uniqueKeysWithValues: option.days.filter { !$0.isRestDay }.map { ($0.weekday, UUID()) })
            let result = WeeklyProgram(confirmedAt: now, draft: draft, selectedOptionID: option.id, dayPlanVersionIDs: ids)
            try result.validate(); return result
        }
        let ordinary = try ReviewEngine.summarize(period: .week, sessions: [], checkIns: [], plan: nil, plannedDaysPerWeek: 7, now: now, weeklyProgram: program(resting: false), calendar: utc)
        let resting = try ReviewEngine.summarize(period: .week, sessions: [], checkIns: [], plan: nil, plannedDaysPerWeek: 7, now: now, weeklyProgram: program(resting: true), calendar: utc)
        XCTAssertEqual(ordinary.plannedSessionCount, 1)
        XCTAssertEqual(resting.plannedSessionCount, 0)
    }

    func testCurrentPainOrSafetyStopCannotBeOverwrittenByReviewedCheckboxes() throws {
        let session = try reviewed(); let input = try session.profile.planningInput(at: now)
        var snapshot = AppSnapshot(exportedAt: now, interview: session)
        snapshot.preWorkoutCheckIns = [.init(createdAt: now, painReported: true)]
        XCTAssertFalse(session.planningEligibility(at: now, snapshot: snapshot).canGenerate)
        XCTAssertThrowsError(try PlanningDraft.make(input: input, snapshot: snapshot, at: now))
        snapshot.preWorkoutCheckIns?.append(.init(createdAt: now.addingTimeInterval(1), painReported: nil))
        XCTAssertThrowsError(try PlanningDraft.make(input: input, snapshot: snapshot, at: now.addingTimeInterval(2)), "An unanswered newer row cannot erase an answered pain report")
        snapshot.preWorkoutCheckIns = [.init(createdAt: now.addingTimeInterval(-86_400), painReported: true)]
        XCTAssertNoThrow(try PlanningDraft.make(input: input, snapshot: snapshot, at: now))
        snapshot.latestReadiness = .init(createdAt: now, safety: "合成安全停止记录", safetyVerdict: .stop, confidence: "合成的明确停止依据", todaySuggestion: "先核对记录再安排", verdict: .stop)
        try snapshot.latestReadiness?.validate()
        XCTAssertThrowsError(try PlanningDraft.make(input: input, snapshot: snapshot, at: now))
        snapshot.latestReadiness?.createdAt = now.addingTimeInterval(-86_400)
        XCTAssertNoThrow(try PlanningDraft.make(input: input, snapshot: snapshot, at: now))
    }

    func testEligibilityIncludesOriginalProfileAdultGateAndOngoingWorkout() throws {
        let session = try reviewed()
        var snapshot = AppSnapshot(exportedAt: now, interview: session)
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        snapshot.profile.birthYear = year - 17
        XCTAssertFalse(session.planningEligibility(at: now, snapshot: snapshot).canGenerate)
        snapshot.profile.birthYear = nil
        let movement = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        snapshot.sessions = [WorkoutSession(name: "合成进行中训练", startedAt: now, exercises: [.init(exercise: movement, sets: [LoggedSet(reps: 8)])])]
        XCTAssertFalse(session.planningEligibility(at: now, snapshot: snapshot).canGenerate)
    }

    func testAnEmptyAllowedPoolIsNotReportedAsReadyAndARejectedReviewIsAtomic() throws {
        var boundaries = review(); boundaries.allowedExerciseIDs = ["builtin.bird-dog"]
        var session = try reviewed(boundaries)
        XCTAssertFalse(session.planningEligibility(at: now).canGenerate)
        let before = session
        boundaries.painFreeConfirmed = false
        XCTAssertThrowsError(try session.confirmConstraintReview(boundaries, at: now))
        XCTAssertEqual(session, before)
    }
}
