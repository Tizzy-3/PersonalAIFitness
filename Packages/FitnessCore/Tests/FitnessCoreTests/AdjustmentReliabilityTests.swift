import XCTest
@testable import FitnessCore

final class AdjustmentReliabilityTests: XCTestCase {
    private func movement(sets: Int = 3) throws -> PlannedExercise {
        PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat")),
                        setCount: sets, targetReps: 10, restSeconds: 90)
    }

    private func assessment(at date: Date, verdict: ReadinessAssessment.Verdict = .conservative) -> ReadinessAssessment {
        ReadinessAssessment(createdAt: date, safety: "本人无疼痛", safetyVerdict: .normal,
                            confidence: "测试夹具已明确给出安全信息，其他数据有限",
                            todaySuggestion: "根据实际反馈保守训练", verdict: verdict,
                            evidence: [ReadinessEvidence(id: "profile", kind: .profile, label: "档案")])
    }

    func testSameProvenanceDifferentProfileContentChangesFingerprint() {
        var first = StructuredProfile()
        first.primaryGoal = ProfileField(value: .strength, provenance: .confirmed, confirmedAt: Date())
        var second = first
        second.primaryGoal.value = .endurance
        XCTAssertNotEqual(AdjustmentFingerprint.digest(of: first), AdjustmentFingerprint.digest(of: second))
        XCTAssertEqual(AdjustmentFingerprint.digest(of: first), AdjustmentFingerprint.digest(of: first))
    }

    func testChangingCheckInContentWithSameIDChangesFingerprint() {
        let checkIn = PreWorkoutCheckIn(energy: 5, painReported: false)
        var changed = checkIn
        changed.energy = 1
        let first = AdjustmentEngine.fingerprint(planVersionID: nil, sessions: [], checkIn: checkIn,
            health: nil, profile: StructuredProfile(), readiness: nil)
        let second = AdjustmentEngine.fingerprint(planVersionID: nil, sessions: [], checkIn: changed,
            health: nil, profile: StructuredProfile(), readiness: nil)
        XCTAssertNotEqual(first, second)
    }

    func testChangingPostWorkoutFeedbackChangesFingerprint() {
        let feedback = SessionFeedback(sessionID: UUID(), tooHard: false)
        var changed = feedback
        changed.tooHard = true
        let first = AdjustmentEngine.fingerprint(planVersionID: nil, sessions: [], checkIn: nil,
            health: nil, profile: StructuredProfile(), readiness: nil, sessionFeedback: [feedback])
        let second = AdjustmentEngine.fingerprint(planVersionID: nil, sessions: [], checkIn: nil,
            health: nil, profile: StructuredProfile(), readiness: nil, sessionFeedback: [changed])
        XCTAssertNotEqual(first, second)
    }

    func testAcceptedTodayOnlyProposalExpiresAtCalendarBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let created = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 59)))
        let fingerprint = AdjustmentFingerprint(profileDigest: "same")
        let proposal = AdjustmentProposal(createdAt: created, kind: .todayOnly, reason: "依据", summary: "仅本次",
            todayItems: [try movement()], decision: .accepted, basedOn: fingerprint)
        XCTAssertFalse(AdjustmentEngine.isStale(proposal, currently: fingerprint, now: created, calendar: calendar))
        XCTAssertTrue(AdjustmentEngine.isStale(proposal, currently: fingerprint,
            now: created.addingTimeInterval(120), calendar: calendar))
    }

    func testTimeBudgetReductionFitsEstimateAndChangesActualItems() throws {
        let now = Date()
        let exercises = try ["builtin.bodyweight-squat", "builtin.dead-bug", "builtin.knee-push-up"].map {
            PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: $0)), setCount: 3,
                            targetReps: 12, restSeconds: 120)
        }
        let plan = PlanVersion(name: "原训练", items: exercises, confirmedAt: now)
        let proposal = try AdjustmentEngine.proposeForToday(readiness: assessment(at: now), basePlan: plan,
            fingerprint: AdjustmentFingerprint(planVersionID: plan.id), createdAt: now, availableMinutes: 15)
        XCTAssertEqual(proposal.kind, .todayOnly)
        let shortened = try XCTUnwrap(proposal.todayItems)
        XCTAssertLessThan(shortened.count, exercises.count)
        let items = shortened.map { PlanningItem(exerciseID: $0.exercise.id, setCount: $0.setCount,
            targetReps: $0.targetReps, targetSeconds: $0.targetSeconds, restSeconds: $0.restSeconds, notes: []) }
        XCTAssertLessThanOrEqual(PlannerEngine.timeRange(items: items).upper, 15)
    }

    func testInsufficientTimeDoesNotPretendOriginalWorkoutFits() throws {
        let now = Date()
        let plan = PlanVersion(name: "原训练", items: [try movement()], confirmedAt: now)
        let proposal = try AdjustmentEngine.proposeForToday(readiness: assessment(at: now), basePlan: plan,
            fingerprint: AdjustmentFingerprint(planVersionID: plan.id), createdAt: now, availableMinutes: 5)
        XCTAssertEqual(proposal.kind, .keep)
        XCTAssertNil(proposal.todayItems)
        XCTAssertTrue(proposal.summary.contains("不自动安排"))
    }

    func testReviewWithoutManualScheduleDoesNotAssumeThreeDays() throws {
        let plan = PlanVersion(name: "未排期手动计划", items: [try movement()])
        let review = try ReviewEngine.summarize(period: .week, sessions: [], checkIns: [], plan: plan,
                                               plannedDaysPerWeek: 0)
        XCTAssertEqual(review.plannedSessionCount, 0)
        XCTAssertTrue(review.completionRateText.contains("无法计算"))
    }

    func testReviewKeepsLatestDailyCheckInRatherThanCountingEditsAsDays() throws {
        let now = Date()
        let first = PreWorkoutCheckIn(createdAt: now.addingTimeInterval(-120), energy: 4, painReported: true, painAreas: ["腰"])
        let edit = PreWorkoutCheckIn(createdAt: now.addingTimeInterval(-60), energy: 4, painReported: false)
        let review = try ReviewEngine.summarize(period: .week, sessions: [], checkIns: [first, edit],
                                               plan: nil, plannedDaysPerWeek: 0, now: now)
        XCTAssertEqual(review.checkInCount, 1)
        XCTAssertEqual(review.reportedPainCount, 0)
    }

    func testWeeklyReviewCountsOnlyConfirmedScheduledDatesAndMatchingTraining() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12)))
        let confirmed = now.addingTimeInterval(-3 * 86_400)
        let input = PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [1, 3, 5],
            minutesPerSession: 30, equipment: [.bodyweight], adultConfirmed: true,
            safety: .noKnownRestrictions, painToday: false)
        let draft = try PlanningDraft.make(input: input, snapshot: AppSnapshot(), at: confirmed.addingTimeInterval(-60))
        let option = try XCTUnwrap(draft.options.first)
        var versionIDs: [Int: UUID] = [:]
        for day in option.days where !day.isRestDay { versionIDs[day.weekday] = UUID() }
        let program = WeeklyProgram(confirmedAt: confirmed, draft: draft, selectedOptionID: option.id,
                                    dayPlanVersionIDs: versionIDs)
        let source = PlanVersion(id: try XCTUnwrap(versionIDs[1]), name: "周一", items: [try movement()], confirmedAt: confirmed)
        var session = try WorkoutSession.start(plan: source, at: now.addingTimeInterval(-60))
        let movementID = try XCTUnwrap(session.exercises.first?.id)
        let setID = try XCTUnwrap(session.exercises.first?.sets.first?.id)
        try session.completeSet(exerciseID: movementID, setID: setID, at: now.addingTimeInterval(-30))
        try session.finish(early: true, at: now)
        var free = WorkoutSession(name: "其他训练", startedAt: now.addingTimeInterval(-60))
        try free.finish(early: true, at: now)
        let review = try ReviewEngine.summarize(period: .week, sessions: [session, free], checkIns: [], plan: nil,
            plannedDaysPerWeek: 0, now: now, weeklyProgram: program, calendar: calendar)
        XCTAssertEqual(review.plannedSessionCount, 2) // Friday and Monday after confirmation.
        XCTAssertEqual(review.completedPlannedSessionCount, 1)
        XCTAssertTrue(review.completionRateText.contains("50%"))
    }
}
