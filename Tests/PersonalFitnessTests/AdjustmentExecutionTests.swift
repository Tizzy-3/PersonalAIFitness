import XCTest
import FitnessCore
@testable import PersonalFitness

final class AdjustmentExecutionTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (TrainingStore, PlanVersion, AdjustmentProposal, Date) {
        let store = try TrainingStore(inMemory: true)
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        let plan = try store.confirmPlan(name: "临时调整测试", items: [PlannedExercise(exercise: exercise, setCount: 3)])
        let now = Date()
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: now, energy: 1, painReported: false))
        let assessment = try store.refreshReadiness(now: now)
        let proposal = try store.proposeAdjustment(readiness: assessment, at: now)
        XCTAssertEqual(proposal.kind, .todayOnly)
        return (store, plan, proposal, now)
    }

    @MainActor
    func testAcceptedTodayAdjustmentChangesActualWorkoutExactlyOnceAndKeepsPlan() throws {
        let (store, plan, proposal, now) = try fixture()
        XCTAssertNil(try store.acceptAdjustment(id: proposal.id, at: now))
        let first = try store.startWorkout(plan: plan, at: now)
        XCTAssertEqual(first.exercises.first?.sets.count, 2)
        XCTAssertEqual(first.sourcePlanVersionID, plan.id)
        XCTAssertEqual(store.currentPlan?.items.first?.setCount, 3)
        XCTAssertEqual(store.adjustments.first { $0.id == proposal.id }?.appliedSessionID, first.id)
        try store.updateSession(id: first.id) { try $0.finish(early: true) }
        let second = try store.startWorkout(plan: plan)
        XCTAssertEqual(second.exercises.first?.sets.count, 3)
        XCTAssertEqual(store.planVersions, [plan])
    }

    @MainActor
    func testAcceptedAdjustmentDoesNotApplyToNextDay() throws {
        let (store, plan, proposal, now) = try fixture()
        try store.acceptAdjustment(id: proposal.id, at: now)
        let next = try store.startWorkout(plan: plan, at: now.addingTimeInterval(86_400))
        XCTAssertEqual(next.exercises.first?.sets.count, 3)
        XCTAssertNil(store.adjustments.first { $0.id == proposal.id }?.appliedSessionID)
    }

    @MainActor
    func testPendingAdjustmentCannotBeAcceptedNextDay() throws {
        let (store, _, proposal, now) = try fixture()
        XCTAssertThrowsError(try store.acceptAdjustment(id: proposal.id, at: now.addingTimeInterval(86_400)))
        XCTAssertEqual(store.adjustments.first?.decision, .pending)
    }

    @MainActor
    func testEditingCheckInKeepsCitedEvidenceAndInvalidatesOldProposal() throws {
        let (store, _, proposal, now) = try fixture()
        let old = try XCTUnwrap(store.todaysCheckIn(now: now))
        let edited = PreWorkoutCheckIn(createdAt: now.addingTimeInterval(1), energy: 5, painReported: false)
        try store.saveCheckIn(edited)
        XCTAssertEqual(store.preWorkoutCheckIns.count, 2)
        XCTAssertTrue(store.preWorkoutCheckIns.contains(old))
        XCTAssertEqual(store.todaysCheckIn(now: now.addingTimeInterval(2))?.id, edited.id)
        XCTAssertThrowsError(try store.acceptAdjustment(id: proposal.id, at: now.addingTimeInterval(2)))
        try store.snapshot().validate()
    }

    @MainActor
    func testChangingManualProfileWithSameProvenanceInvalidatesProposal() throws {
        let (store, _, proposal, now) = try fixture()
        var profile = store.profile
        profile.goal = "已修改目标"
        try store.saveProfile(profile)
        XCTAssertThrowsError(try store.acceptAdjustment(id: proposal.id, at: now))
    }

    @MainActor
    func testOldReadinessCannotBeReusedAfterNewCheckIn() throws {
        let (store, _, _, now) = try fixture()
        let old = try XCTUnwrap(store.latestReadiness)
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: now.addingTimeInterval(1), energy: 4, painReported: true, painAreas: ["膝盖"]))
        XCTAssertThrowsError(try store.proposeAdjustment(readiness: old, at: now.addingTimeInterval(2)))
    }

    @MainActor
    func testAcceptanceDuringActiveSessionLeavesDecisionAndPlanUntouched() throws {
        let (store, plan, proposal, now) = try fixture()
        _ = try store.startWorkout(plan: plan, at: now)
        let before = try store.snapshot()
        XCTAssertThrowsError(try store.acceptAdjustment(id: proposal.id, at: now))
        XCTAssertEqual(try store.snapshot().planVersions, before.planVersions)
        XCTAssertEqual(store.adjustments, before.adjustments ?? [])
    }

    @MainActor
    func testConsumedAdjustmentAndExecutionSurviveBackupRoundTrip() throws {
        let (store, plan, proposal, now) = try fixture()
        try store.acceptAdjustment(id: proposal.id, at: now)
        let session = try store.startWorkout(plan: plan, at: now)
        let copy = try TrainingStore(inMemory: true)
        try copy.restore(SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot())))
        XCTAssertEqual(copy.adjustments.first?.appliedSessionID, session.id)
        XCTAssertEqual(copy.activeSession?.exercises.first?.sets.count, 2)
        XCTAssertEqual(copy.currentPlan?.items.first?.setCount, 3)
    }

    @MainActor
    func testWeeklyProgramAdjustmentUsesTodaysPlanAndActuallyChangesItsExecution() throws {
        let store = try TrainingStore(inMemory: true)
        let weekday = ((Calendar.current.component(.weekday, from: Date()) + 5) % 7) + 1
        let input = PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [weekday],
            minutesPerSession: 30, equipment: [.bodyweight], adultConfirmed: true,
            safety: .noKnownRestrictions, painToday: false)
        let draft = try PlanningDraft.make(input: input, snapshot: store.snapshot())
        try store.savePlanningDraft(draft)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id)
        let now = Date()
        let scheduled = try XCTUnwrap(store.scheduledPlan(on: now))
        XCTAssertNil(store.currentPlan)
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: now, energy: 1, painReported: false))
        let readiness = try store.refreshReadiness(now: now)
        let proposal = try store.proposeAdjustment(readiness: readiness, at: now)
        XCTAssertEqual(proposal.basePlanVersionID, scheduled.id)
        XCTAssertEqual(proposal.kind, .todayOnly)
        try store.acceptAdjustment(id: proposal.id, at: now)
        let execution = try store.startWorkout(plan: scheduled, at: now)
        XCTAssertEqual(execution.exercises.map { $0.sets.count }, proposal.todayItems?.map(\.setCount))
        XCTAssertEqual(store.currentWeeklyProgram?.id, program.id)
        XCTAssertEqual(store.planVersions.first { $0.id == scheduled.id }, scheduled)
        let review = try store.refreshReview(.week, now: now)
        XCTAssertEqual(review.plannedSessionCount, 1)
    }

    @MainActor
    func testWeeklyRestDayDoesNotBorrowAnotherDayForAdjustment() throws {
        let store = try TrainingStore(inMemory: true)
        let weekday = ((Calendar.current.component(.weekday, from: Date()) + 5) % 7) + 1
        let nextWeekday = weekday % 7 + 1
        let input = PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [nextWeekday],
            minutesPerSession: 30, equipment: [.bodyweight], adultConfirmed: true,
            safety: .noKnownRestrictions, painToday: false)
        let draft = try PlanningDraft.make(input: input, snapshot: store.snapshot())
        try store.savePlanningDraft(draft)
        _ = try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id)
        let now = Date()
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: now, energy: 1, painReported: false))
        let readiness = try store.refreshReadiness(now: now)
        let proposal = try store.proposeAdjustment(readiness: readiness, at: now)
        XCTAssertNil(store.scheduledPlan(on: now))
        XCTAssertNil(proposal.basePlanVersionID)
        XCTAssertEqual(proposal.kind, .keep)
        XCTAssertNil(proposal.todayItems)
    }

    @MainActor
    func testReviewIncludesARealCustomExerciseAndBackupStillValidates() throws {
        let store = try TrainingStore(inMemory: true)
        var custom = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        custom.id = "custom.review-squat"; custom.name = "本人自定义动作"; custom.isCustom = true
        try store.addCustomExercise(custom)
        let plan = try store.confirmPlan(name: "自定义训练", items: [PlannedExercise(exercise: custom)])
        let session = try store.startWorkout(plan: plan)
        let movementID = try XCTUnwrap(session.exercises.first?.id)
        let setID = try XCTUnwrap(session.exercises.first?.sets.first?.id)
        try store.updateSession(id: session.id) {
            try $0.completeSet(exerciseID: movementID, setID: setID)
            try $0.finish(early: true)
        }
        let review = try store.refreshReview(.week)
        XCTAssertEqual(review.exerciseProgress.first?.exerciseID, custom.id)
        XCTAssertEqual(review.exerciseProgress.first?.isCustom, true)
        try store.snapshot().validate()
    }

    @MainActor
    func testPersonalizedWeeklyConfirmationCommitsInterviewStateWithTheProgram() throws {
        let store = try TrainingStore(inMemory: true)
        let date = Date()
        var interview = try store.startInterview(at: date)
        interview.profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: date)
        interview.profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .stated, confirmedAt: date)
        interview.profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: date)
        interview.profile.weekdays = ProfileField(value: [1, 3, 5], provenance: .stated, confirmedAt: date)
        interview.profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: date)
        interview.profile.equipment = ProfileField(value: [.bodyweight], provenance: .stated, confirmedAt: date)
        interview.profile.restrictions = ProfileField(value: "无已知限制", provenance: .stated, confirmedAt: date)
        try store.saveInterview(interview)
        interview = try XCTUnwrap(store.interview)
        let pool = try PlannerEngine.candidatePool(input: interview.profile.planningInput())
        let choices = pool.compactMapValues(\.first)
        let reply = PersonalizedPlanReply(choices: choices, explanation: "测试夹具：按本人档案选择动作", limitations: ["负荷尚未校准"])
        let draft = try PlanningDraft.makePersonalized(profile: interview.profile, reply: reply,
            snapshot: store.snapshot(), providerHost: "example.invalid", model: "test-model")
        try store.savePlanningDraft(draft)
        let option = try XCTUnwrap(draft.options.first)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: option.id)
        XCTAssertEqual(store.interview?.phase, .planConfirmed)
        let applied = try XCTUnwrap(store.interview?.appliedPlanVersionID)
        XCTAssertTrue(program.dayPlanVersionIDs.values.contains(applied))
        XCTAssertEqual(store.interview?.profile, interview.profile)
        let resumed = try store.startInterview()
        XCTAssertEqual(resumed.id, interview.id)
        XCTAssertEqual(resumed.profile, interview.profile)
        XCTAssertEqual(resumed.phase, .planConfirmed)
        XCTAssertEqual(resumed.appliedPlanVersionID, applied)
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot())))
        XCTAssertEqual(restored.interview?.appliedPlanVersionID, applied)
        XCTAssertEqual(restored.currentWeeklyProgram?.id, program.id)
    }
}
