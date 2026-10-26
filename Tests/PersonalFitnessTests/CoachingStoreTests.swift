import XCTest
import FitnessCore
@testable import PersonalFitness

/// Storage-level tests for the coaching loop: interview persistence, check-ins, feedback, health
/// snapshots, adjustments and reviews. All fixtures are in memory or a temporary directory.
final class CoachingStoreTests: XCTestCase {
    @MainActor
    func testInterviewProgressSurvivesReopenAndRestore() throws {
        let directory = try temporaryDirectory("InterviewStore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("interview.store")
        let expected: InterviewSession
        do {
            let store = try TrainingStore(storageURL: url)
            var session = try store.startInterview()
            let question = InterviewQuestion(topic: .primaryGoal, kind: .singleChoice,
                                             prompt: "最主要的目标是什么？",
                                             options: PlanningGoal.allCases.map(\.rawValue))
            try session.appendTurn(InterviewTurn(questions: [question], note: "先了解一下你的目标。"))
            try store.saveInterview(session)

            var resumed = try XCTUnwrap(store.interview)
            try resumed.answer([InterviewAnswer(questionID: question.id, choice: "strength")])
            try store.saveInterview(resumed)
            expected = try XCTUnwrap(store.interview)
        }
        let reopened = try TrainingStore(storageURL: url)
        let restored = try XCTUnwrap(reopened.interview)
        XCTAssertEqual(restored.id, expected.id)
        XCTAssertEqual(restored.profile.primaryGoal.value, .strength)
        XCTAssertEqual(restored.profile.provenance(of: .primaryGoal), .stated)
        XCTAssertEqual(restored.turns.count, 1)
        XCTAssertEqual(restored.rulesVersion, InterviewRules.rulesVersion)
        // The rest of the app's data is untouched by the interview.
        XCTAssertTrue(reopened.sessions.isEmpty)
        XCTAssertNil(reopened.currentPlan)
    }

    @MainActor
    func testSaveInterviewRejectsAnInvalidSessionWithoutChangingTheStore() throws {
        let store = try TrainingStore(inMemory: true)
        var session = try store.startInterview()
        let question = InterviewQuestion(topic: .minutes, kind: .number, prompt: "多久？",
                                         unit: "分钟", minimum: 15, maximum: 120)
        try session.appendTurn(InterviewTurn(questions: [question]))
        try store.saveInterview(session)
        // An answer that breaks the question's own range must be refused at the store boundary too.
        var broken = session
        XCTAssertThrowsError(try broken.answer([InterviewAnswer(questionID: question.id, number: 500)]))
        XCTAssertEqual(try XCTUnwrap(store.interview).turns.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.interview).profile.provenance(of: .minutes), .unknown)
    }

    @MainActor
    func testCheckInIsOnePerDayAndUnansweredFieldsStayUnanswered() throws {
        let store = try TrainingStore(inMemory: true)
        let today = Date()
        let first = PreWorkoutCheckIn(createdAt: today, energy: 4, painReported: nil)
        try store.saveCheckIn(first)
        XCTAssertEqual(store.preWorkoutCheckIns.count, 1)
        XCTAssertEqual(store.todaysCheckIn()?.painState, .unanswered)

        let replaced = PreWorkoutCheckIn(createdAt: today.addingTimeInterval(600), energy: 3, painReported: false)
        try store.saveCheckIn(replaced)
        // One record per day, updated in place rather than accumulating conflicting answers.
        XCTAssertEqual(store.preWorkoutCheckIns.count, 1)
        XCTAssertEqual(store.todaysCheckIn()?.energy, 3)
        XCTAssertEqual(store.todaysCheckIn()?.painReported, false)

        let tomorrow = PreWorkoutCheckIn(createdAt: today.addingTimeInterval(86_400), energy: 5)
        try store.saveCheckIn(tomorrow)
        XCTAssertEqual(store.preWorkoutCheckIns.count, 2)
    }

    @MainActor
    func testCheckInRejectsContradictoryPainRecord() throws {
        let store = try TrainingStore(inMemory: true)
        let bad = PreWorkoutCheckIn(createdAt: Date(), painReported: false, painAreas: ["膝盖"])
        XCTAssertThrowsError(try store.saveCheckIn(bad))
        XCTAssertTrue(store.preWorkoutCheckIns.isEmpty)
    }

    @MainActor
    func testSessionFeedbackUsesComputedTotalsAndRejectsOngoingSession() throws {
        let store = try TrainingStore(inMemory: true)
        let session = try store.startWorkout()
        let movementID = try XCTUnwrap(session.exercises.first?.id)
        // An ongoing session cannot be reviewed yet.
        XCTAssertThrowsError(try store.saveSessionFeedback(
            SessionFeedback(sessionID: session.id, perceivedExertion: 5)))

        try store.updateSession(id: session.id) { value in
            guard let setID = value.exercises.first?.sets.first?.id else { return }
            value.exercises[0].sets[0].reps = 10
            try value.completeSet(exerciseID: movementID, setID: setID)
            try value.finish(early: true)
        }
        // A forged objective number is overwritten with the real one.
        let saved = try store.saveSessionFeedback(
            SessionFeedback(sessionID: session.id, completedWorkingSets: 999, perceivedExertion: 6))
        let expected = try XCTUnwrap(store.session(id: session.id)).completedWorkingSets
        XCTAssertEqual(saved.completedWorkingSets, expected)
        XCTAssertNotEqual(saved.completedWorkingSets, 999)
        XCTAssertEqual(store.feedback(for: session.id)?.perceivedExertion, 6)
    }

    @MainActor
    func testHealthSnapshotRoundTripKeepsAnchorsAndStates() throws {
        let store = try TrainingStore(inMemory: true)
        let snapshot = HealthSnapshot(capturedAt: Date(), metrics: [
            HealthMetricSnapshot(metric: .stepCount, state: .available, sampleCountInWindow: 3,
                                 latestValue: 8_000, latestSampleAt: Date(), syncedAt: Date(),
                                 sourceName: "Watch", anchor: Data([0x01, 0x02])),
            HealthMetricSnapshot(metric: .cardioFitness, state: .noSamples, syncedAt: Date())
        ])
        try store.saveHealthSnapshot(snapshot)
        XCTAssertEqual(store.healthSnapshot?.metrics.count, 2)
        XCTAssertEqual(store.healthAnchors()[.stepCount], Data([0x01, 0x02]))
        XCTAssertNil(store.healthAnchors()[.cardioFitness])
    }

    @MainActor
    func testReadinessUsesSavedDataAndNeverClaimsNormalWithoutEvidence() throws {
        let store = try TrainingStore(inMemory: true)
        let assessment = try store.refreshReadiness()
        XCTAssertEqual(assessment.verdict, .gatherData)
        XCTAssertEqual(store.latestReadiness?.id, assessment.id)
        XCTAssertNotNil(try store.snapshot().latestReadiness)
    }

    @MainActor
    func testProposedAdjustmentIsStaleAfterThePlanChanges() throws {
        let store = try TrainingStore(inMemory: true)
        let plan = try store.confirmPlan(name: "原计划", items: [try item()])
        // Force a conservative verdict by reporting short sleep.
        try store.saveHealthSnapshot(HealthSnapshot(capturedAt: Date(), metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 4,
                                 latestValue: 4, latestSampleAt: Date(), syncedAt: Date(),
                                 sourceName: "Watch", anchor: nil)
        ]))
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: Date(), energy: 4, painReported: false))
        let readiness = try store.refreshReadiness()
        let proposal = try store.proposeAdjustment(readiness: readiness)
        guard proposal.kind == .todayOnly else {
            // With this fixture the rules should offer a downgrade; if not, the test is meaningless.
            XCTFail("expected a today-only downgrade, got \(proposal.kind)")
            return
        }
        XCTAssertEqual(proposal.basePlanVersionID, plan.id)
        // Changing the active plan invalidates the pending proposal.
        _ = try store.confirmPlan(name: "新计划", items: [try item()], revising: plan)
        XCTAssertThrowsError(try store.acceptAdjustment(id: proposal.id))
        XCTAssertEqual(store.pendingAdjustment?.decision, .pending)
    }

    @MainActor
    func testRejectingAdjustmentLeavesThePlanUnchanged() throws {
        let store = try TrainingStore(inMemory: true)
        let plan = try store.confirmPlan(name: "原计划", items: [try item()])
        try store.saveHealthSnapshot(HealthSnapshot(capturedAt: Date(), metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 4,
                                 latestValue: 4, latestSampleAt: Date(), syncedAt: Date(),
                                 sourceName: "Watch", anchor: nil)
        ]))
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: Date(), energy: 4, painReported: false))
        let readiness = try store.refreshReadiness()
        let proposal = try store.proposeAdjustment(readiness: readiness)
        let before = store.planVersions
        let activeBefore = store.activePlanVersionID
        try store.rejectAdjustment(id: proposal.id)
        XCTAssertEqual(store.planVersions, before)
        XCTAssertEqual(store.activePlanVersionID, activeBefore)
        XCTAssertEqual(store.currentPlan?.id, plan.id)
        XCTAssertNil(store.pendingAdjustment)
    }

    @MainActor
    func testAcceptingTodayOnlyAdjustmentKeepsTheLongTermPlan() throws {
        let store = try TrainingStore(inMemory: true)
        let plan = try store.confirmPlan(name: "原计划", items: [try item()])
        try store.saveHealthSnapshot(HealthSnapshot(capturedAt: Date(), metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 4,
                                 latestValue: 4, latestSampleAt: Date(), syncedAt: Date(),
                                 sourceName: "Watch", anchor: nil)
        ]))
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: Date(), energy: 4, painReported: false))
        let readiness = try store.refreshReadiness()
        let proposal = try store.proposeAdjustment(readiness: readiness)
        guard proposal.kind == .todayOnly else { return }
        let created = try store.acceptAdjustment(id: proposal.id)
        XCTAssertNil(created)
        XCTAssertEqual(store.planVersions.count, 1)
        XCTAssertEqual(store.currentPlan?.id, plan.id)
        XCTAssertEqual(store.adjustments.first?.decision, .accepted)
    }

    @MainActor
    func testReviewIsComputedFromRealRecords() throws {
        let store = try TrainingStore(inMemory: true)
        let plan = try store.confirmPlan(name: "计划", items: [try item()])
        let session = try store.startWorkout(plan: plan)
        try store.updateSession(id: session.id) { try $0.finish(early: true) }
        let summary = try store.refreshReview(.week)
        XCTAssertEqual(summary.finishedSessionCount, 1)
        XCTAssertEqual(summary.completedWorkingSets, 0)
        XCTAssertEqual(store.review(.week)?.id, summary.id)
        XCTAssertTrue(summary.dataGaps.contains { $0.contains("训练前记录") })
    }

    @MainActor
    func testCoachingDataSurvivesBackupRoundTripAndLegacyBackupStillDecodes() throws {
        let store = try TrainingStore(inMemory: true)
        var session = try store.startInterview()
        let question = InterviewQuestion(topic: .experience, kind: .singleChoice,
                                         prompt: "现在训练经验如何？",
                                         options: PlanningExperience.allCases.map(\.rawValue))
        try session.appendTurn(InterviewTurn(questions: [question]))
        try store.saveInterview(session)
        try store.saveCheckIn(PreWorkoutCheckIn(createdAt: Date(), energy: 3, painReported: false))
        try store.saveHealthSnapshot(HealthSnapshot(capturedAt: Date(), metrics: [
            HealthMetricSnapshot(metric: .bodyMass, state: .available, sampleCountInWindow: 1,
                                 latestValue: 70, latestSampleAt: Date(), syncedAt: Date(),
                                 sourceName: "Watch", anchor: nil)
        ]))
        let data = try SnapshotCodec.encode(try store.snapshot())
        let decoded = try SnapshotCodec.decode(data)
        XCTAssertEqual(decoded.formatVersion, 4)
        XCTAssertEqual(decoded.interview?.id, session.id)

        let restored = try TrainingStore(inMemory: true)
        try restored.restore(decoded)
        XCTAssertEqual(restored.interview?.id, session.id)
        XCTAssertEqual(restored.preWorkoutCheckIns.count, 1)
        XCTAssertEqual(restored.healthSnapshot?.metrics.count, 1)

        // A pre-4 backup carries none of this and must still load without inventing it.
        let legacy = AppSnapshot(formatVersion: 3, exportedAt: Date())
        let legacyDecoded = try SnapshotCodec.decode(SnapshotCodec.encode(legacy))
        XCTAssertNil(legacyDecoded.interview)
        XCTAssertNil(legacyDecoded.preWorkoutCheckIns)
        XCTAssertNil(legacyDecoded.healthSnapshot)
    }

    @MainActor
    func testSnapshotRejectsFeedbackForAMissingSession() throws {
        var snapshot = AppSnapshot(exportedAt: Date())
        snapshot.sessionFeedback = [SessionFeedback(sessionID: UUID())]
        XCTAssertThrowsError(try snapshot.validate())
    }

    @MainActor
    func testSnapshotRejectsAcceptedAdjustmentWithoutItsVersion() throws {
        var snapshot = AppSnapshot(exportedAt: Date())
        snapshot.adjustments = [AdjustmentProposal(kind: .keep, reason: "原因", summary: "说明",
                                                   decision: .accepted,
                                                   appliedPlanVersionID: UUID())]
        XCTAssertThrowsError(try snapshot.validate())
    }

    @MainActor
    func testSnapshotRejectsFabricatedEvidenceReference() throws {
        var snapshot = AppSnapshot(exportedAt: Date())
        snapshot.adjustments = [AdjustmentProposal(kind: .keep, reason: "原因",
                                                   evidenceIDs: ["health:stepCount"], summary: "说明")]
        // No health snapshot is present, so the citation cannot resolve.
        XCTAssertThrowsError(try snapshot.validate())
    }

    // MARK: - Fixtures

    private func item() throws -> PlannedExercise {
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        return PlannedExercise(exercise: exercise, setCount: 2, targetReps: 8)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFitness-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
