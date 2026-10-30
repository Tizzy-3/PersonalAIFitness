import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

/// Synthetic limitations only. No personal medical narratives or body measurements.
final class ConstraintPlanningPersistenceTests: XCTestCase {
    private var now: Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }

    @MainActor private func prepare(_ store: TrainingStore, at date: Date, restDate: String? = nil) throws -> InterviewSession {
        var session = try store.startInterview(at: date.addingTimeInterval(-5))
        let evidence = date.addingTimeInterval(-1)
        session.profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: evidence)
        session.profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: evidence)
        session.profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: evidence)
        session.profile.weekdays = .init(value: Array(1...7), provenance: .stated, confirmedAt: evidence)
        session.profile.minutesPerSession = .init(value: 35, provenance: .stated, confirmedAt: evidence)
        session.profile.equipment = .init(value: [.bodyweight, .dumbbells, .bench, .walkingSpace], provenance: .stated, confirmedAt: evidence)
        session.profile.restrictions = .init(value: "优先采用无需跪姿的动作，另留出指定休息日期", provenance: .stated, confirmedAt: evidence)
        let review = TrainingConstraintReview(sourceText: session.profile.restrictions.value!,
            legacySourceText: store.profile.restrictions, mode: .practicalOnly,
            excludedWeekdays: [], restDateKeys: restDate.map { [$0] } ?? [],
            excludedExerciseIDs: ["builtin.plank"], avoidedPositions: [.kneeling],
            allowedExerciseIDs: nil, maxSessionMinutes: 25, painFreeConfirmed: true,
            allLimitsRepresentedConfirmed: true, professionalGuidanceNote: "", confirmedAt: date)
        try session.confirmConstraintReview(review, at: date)
        try store.saveInterview(session)
        return try XCTUnwrap(store.interview)
    }

    private func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    @MainActor func testConstraintConfirmationAndBackupKeepOriginalTextAndCurrentPlan() throws {
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "原安排", items: [PlannedExercise(exercise: XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.walking")))])
        let session = try prepare(store, at: now)
        XCTAssertEqual(store.currentPlan?.id, manual.id)
        XCTAssertEqual(session.profile.restrictions.value, session.profile.constraintReview?.sourceText)
        XCTAssertNotEqual(session.profile.restrictions.value, "无")
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot()))
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(decoded)
        XCTAssertEqual(restored.interview, session)
        XCTAssertEqual(restored.currentPlan?.id, manual.id)
        let request = try PersonalizedPlanRequest.make(session: session, snapshot: restored.snapshot(), at: now)
        XCTAssertEqual(request.baseline.input.minutesPerSession, 25)
        XCTAssertFalse(request.pool.values.flatMap { $0 }.contains("builtin.knee-push-up"))
        XCTAssertFalse(request.pool.values.flatMap { $0 }.contains("builtin.bird-dog"))
        XCTAssertFalse(request.pool.values.flatMap { $0 }.contains("builtin.plank"))
    }

    @MainActor func testExplicitRestDateBlocksScheduleAndGeneratedWorkoutStart() throws {
        let date = now
        let store = try TrainingStore(inMemory: true)
        let session = try prepare(store, at: date, restDate: dateKey(date))
        let draft = try PlanningDraft.make(input: session.profile.planningInput(at: date), snapshot: store.snapshot(), at: date)
        try store.savePlanningDraft(draft)
        let option = try XCTUnwrap(draft.options.first)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: option.id, at: date)
        let weekday = ((Calendar.current.component(.weekday, from: date) + 5) % 7) + 1
        let planID = try XCTUnwrap(program.dayPlanVersionIDs[weekday])
        let plan = try XCTUnwrap(store.planVersions.first { $0.id == planID })
        XCTAssertTrue(store.isConstraintRestDay(on: date))
        XCTAssertNil(store.scheduledPlan(on: date))
        XCTAssertThrowsError(try store.startWorkout(plan: plan, at: date))
        XCTAssertTrue(store.sessions.isEmpty)
        let tomorrow = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: date))
        XCTAssertNotNil(store.scheduledPlan(on: tomorrow))
        XCTAssertNotNil(try store.startWorkout(plan: plan, at: tomorrow).id)
    }

    @MainActor func testConstraintTextChangeRejectsStalePersonalizedDraftWithoutChangingOldPlan() throws {
        let date = now
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "仍然生效", items: [PlannedExercise(exercise: XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.walking")))])
        let session = try prepare(store, at: date)
        let input = try session.profile.planningInput(at: date)
        let pool = try PlannerEngine.candidatePool(input: input)
        let reply = PersonalizedPlanReply(choices: pool.mapValues { $0[0] }, explanation: "依据核对的限制选择真实动作", limitations: [])
        let draft = try PlanningDraft.makePersonalized(profile: session.profile, reply: reply,
            snapshot: store.snapshot(), providerHost: "example.test", model: "synthetic", at: date)
        try store.savePlanningDraft(draft)
        var updated = try XCTUnwrap(store.interview)
        try updated.setValue(.text("又补充了一项尚未核对的限制"), for: .restrictions, at: date.addingTimeInterval(1))
        try store.saveInterview(updated)
        XCTAssertFalse(try XCTUnwrap(store.interview).planningEligibility(legacyRestrictions: store.profile.restrictions, at: date.addingTimeInterval(1)).canGenerate)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id, at: date.addingTimeInterval(1)))
        XCTAssertEqual(store.currentPlan?.id, manual.id)
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
    }

    @MainActor func testYesterdayStateConfirmationCannotEnableANewPlanToday() throws {
        let date = now
        let store = try TrainingStore(inMemory: true)
        let session = try prepare(store, at: date)
        let draft = try PlanningDraft.make(input: session.profile.planningInput(at: date), snapshot: store.snapshot(), at: date)
        try store.savePlanningDraft(draft)
        let nextDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: date))
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id, at: nextDay))
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        XCTAssertTrue(store.planVersions.isEmpty)
        XCTAssertEqual(store.planningDrafts.first?.decision, .pending)
        // Historical validation is anchored to creation, not the time a backup is read.
        XCTAssertNoThrow(try SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot())))
    }

    @MainActor func testConstraintReviewSurvivesRealStoreReopenWithoutRewritingRestrictions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ConstraintReview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fitness.store")
        let expected: InterviewSession
        do {
            let store = try TrainingStore(storageURL: url)
            expected = try prepare(store, at: now)
        }
        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.interview, expected)
        XCTAssertNotEqual(reopened.interview?.profile.restrictions.value, "无")
        XCTAssertTrue(reopened.weeklyPrograms.isEmpty)
    }

    @MainActor func testNewPainRecordBlocksReadyBadgeAndPendingPlanConfirmation() throws {
        let date = now
        let store = try TrainingStore(inMemory: true)
        let session = try prepare(store, at: date)
        let draft = try PlanningDraft.make(input: session.profile.planningInput(at: date), snapshot: store.snapshot(), at: date)
        try store.savePlanningDraft(draft)
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: date.addingTimeInterval(1), energy: 3, painReported: true))
        let snapshot = try store.snapshot()
        XCTAssertFalse(session.planningEligibility(legacyRestrictions: store.profile.restrictions,
            at: date.addingTimeInterval(2), snapshot: snapshot).canGenerate)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id,
            optionID: XCTUnwrap(draft.options.first).id, at: date.addingTimeInterval(2)))
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        XCTAssertTrue(store.planVersions.isEmpty)
    }
    @MainActor func testSpecificGentleDateIsConfirmedDisplayedAndActuallyExecuted() throws {
        let date = now
        let key = dateKey(date)
        let store = try TrainingStore(inMemory: true)
        var session = try store.startInterview(at: date.addingTimeInterval(-5))
        let evidence = date.addingTimeInterval(-1)
        session.profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: evidence)
        session.profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: evidence)
        session.profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: evidence)
        session.profile.weekdays = .init(value: Array(1...7), provenance: .stated, confirmedAt: evidence)
        session.profile.minutesPerSession = .init(value: 35, provenance: .stated, confirmedAt: evidence)
        session.profile.equipment = .init(value: [.bodyweight, .dumbbells, .bench, .walkingSpace], provenance: .stated, confirmedAt: evidence)
        session.profile.restrictions = .init(value: "合成：指定一天不能剧烈活动", provenance: .stated, confirmedAt: evidence)
        let activity = TemporaryActivityConstraint(dateKey: key, lightActivityAllowed: true, hasConcerningSymptoms: false)
        let review = TrainingConstraintReview(sourceText: session.profile.restrictions.value!, legacySourceText: store.profile.restrictions,
            mode: .gentleActivity, painFreeConfirmed: true, allLimitsRepresentedConfirmed: true,
            confirmedAt: date, temporaryActivity: activity)
        try session.confirmConstraintReview(review, at: date)
        try store.saveInterview(session)
        let saved = try XCTUnwrap(store.interview)
        let draft = try PlanningDraft.make(input: saved.profile.planningInput(at: date), snapshot: store.snapshot(), at: date)
        try store.savePlanningDraft(draft)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id, at: date)
        let temporaryID = try XCTUnwrap(program.temporaryPlanVersionIDs?[key])
        let plan = try XCTUnwrap(store.scheduledPlan(on: date))
        XCTAssertEqual(plan.id, temporaryID)
        XCTAssertEqual(plan.items.first?.exercise.id, "builtin.walking")
        XCTAssertThrowsError(try store.startWorkout(plan: plan, at: date))
        let weekday = ((Calendar.current.component(.weekday, from: date) + 5) % 7) + 1
        let regular = try XCTUnwrap(store.planVersions.first { $0.id == program.dayPlanVersionIDs[weekday] })
        XCTAssertThrowsError(try store.startWorkout(plan: regular, at: date))
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: date, painReported: false))
        try store.continuePlanning(from: "合成：出现新的训练注意事项", at: date.addingTimeInterval(1))
        XCTAssertThrowsError(try store.startWorkout(plan: plan, at: date.addingTimeInterval(2)))
        try store.saveInterview(saved) // Restore the earlier synthetic snapshot for the happy path.
        let executed = try store.startWorkout(plan: plan, at: date.addingTimeInterval(2))
        XCTAssertEqual(executed.exercises.first?.exercise.id, "builtin.walking")
        let nextWeek = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 7, to: date))
        XCTAssertEqual(store.scheduledPlan(on: nextWeek)?.id, regular.id)
        let backup = try SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot()))
        XCTAssertEqual(backup.weeklyPrograms?.first?.temporaryPlanVersionIDs?[key], temporaryID)
    }

    @MainActor func testCoachFeedbackEntersInterviewWithoutReplacingCurrentPlan() throws {
        let date = now
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "原安排", items: [PlannedExercise(exercise: XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.walking")))])
        let before = try prepare(store, at: date)
        try store.continuePlanning(from: "合成反馈：最近时间减少", at: date.addingTimeInterval(1))
        let after = try XCTUnwrap(store.interview)
        XCTAssertEqual(after.narratives?.last?.text, "合成反馈：最近时间减少")
        XCTAssertTrue(after.needsSafetyReview)
        XCTAssertEqual(after.profile.restrictions.value, before.profile.restrictions.value)
        XCTAssertEqual(store.currentPlan?.id, manual.id)
        XCTAssertThrowsError(try store.continuePlanning(from: "  ", at: date.addingTimeInterval(2)))
    }

}
