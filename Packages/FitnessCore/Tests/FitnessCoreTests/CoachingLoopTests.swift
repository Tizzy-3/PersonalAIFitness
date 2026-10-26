import Foundation
import XCTest
@testable import FitnessCore

/// Plan synthesis from a confirmed profile, readiness rules, adjustments and reviews.
final class CoachingLoopTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func input(goal: PlanningGoal = .generalFitness,
                       experience: PlanningExperience = .beginner,
                       weekdays: [Int] = [1, 3, 5], minutes: Int = 30,
                       equipment: Set<PlanningEquipment> = [.bodyweight, .walkingSpace]) -> PlanningInput {
        PlanningInput(goal: goal, experience: experience, weekdays: weekdays,
                      minutesPerSession: minutes, equipment: equipment,
                      adultConfirmed: true, safety: .noKnownRestrictions, painToday: false)
    }

    // MARK: - Synthesis

    func testSynthesizedWeekPassesTheSameValidatorAsTemplates() throws {
        let option = try PlannerEngine.synthesize(input: input())
        XCTAssertEqual(option.id, PlannerEngine.profileOptionID)
        XCTAssertEqual(option.days.map(\.weekday), Array(1...7))
        XCTAssertNoThrow(try option.validate(input: input()))
        XCTAssertFalse(option.days.filter { !$0.isRestDay }.isEmpty)
    }

    func testSynthesisRejectsAnExerciseOutsideTheAllowedPool() {
        XCTAssertThrowsError(try PlannerEngine.synthesize(
            input: input(),
            choices: ["squat": "builtin.lat-pulldown"]))
        // An id that does not exist at all is equally refused.
        XCTAssertThrowsError(try PlannerEngine.synthesize(
            input: input(),
            choices: ["squat": "invented.exercise"]))
    }

    func testSynthesisNeverPrescribesAKilogramValue() throws {
        let option = try PlannerEngine.synthesize(input: input())
        // `PlanningItem` has no load field at all, so a generated week cannot carry a guessed weight.
        let plan = PlanVersion(name: "测试", items: option.days.filter { !$0.isRestDay }.first.map { day in
            day.items.compactMap { item in
                ExerciseCatalog.exercise(id: item.exerciseID).map { exercise in
                    PlannedExercise(exercise: exercise, setCount: item.setCount,
                                    targetReps: item.targetReps, targetSeconds: item.targetSeconds,
                                    restSeconds: item.restSeconds)
                }
            }
        } ?? [], confirmedAt: now)
        try plan.validate()
        let session = try WorkoutSession.start(plan: plan, at: now.addingTimeInterval(60))
        XCTAssertTrue(session.exercises.allSatisfy { $0.sets.allSatisfy { $0.loadKG == nil } })
    }

    func testSynthesisRespectsExclusionsAndEquipment() throws {
        // With a real alternative available, the exclusion is honoured.
        let excluded = try PlannerEngine.synthesize(input: {
            var value = input(equipment: [.bodyweight, .walkingSpace, .dumbbells, .bench])
            value.excludedExerciseIDs = ["builtin.incline-push-up", "builtin.glute-bridge"]
            return value
        }())
        for day in excluded.days {
            for item in day.items {
                XCTAssertNotEqual(item.exerciseID, "builtin.incline-push-up")
                XCTAssertNotEqual(item.exerciseID, "builtin.glute-bridge")
            }
        }
        // Bodyweight-only must never produce a machine movement.
        let bodyweightOnly = try PlannerEngine.synthesize(input: input(equipment: [.bodyweight, .walkingSpace]))
        for day in bodyweightOnly.days {
            for item in day.items {
                XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: item.exerciseID,
                                                        equipment: [.bodyweight, .walkingSpace]))
            }
        }
    }

    func testSynthesisFailsExplicitlyWhenEveryMovementIsExcluded() {
        // Excluding the only bodyweight squat pattern leaves nothing to prescribe; the engine must
        // refuse rather than silently invent a substitute.
        XCTAssertThrowsError(try PlannerEngine.synthesize(input: {
            var value = input()
            value.excludedExerciseIDs = ["builtin.bodyweight-squat"]
            return value
        }()))
    }

    func testSynthesisRejectsASubMinimumTimeBudget() {
        // 10 minutes is below the supported floor, so the input itself is refused.
        XCTAssertThrowsError(try PlannerEngine.synthesize(input: input(minutes: 10)))
    }

    func testCandidatePoolContainsOnlyRealAvailableMovements() throws {
        let pool = try PlannerEngine.candidatePool(input: input())
        XCTAssertFalse(pool.isEmpty)
        for (_, ids) in pool {
            for id in ids {
                XCTAssertNotNil(ExerciseCatalog.exercise(id: id))
                XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: id,
                                                        equipment: [.bodyweight, .walkingSpace]))
            }
        }
    }

    func testProfileFittedDraftIsAcceptedAndStillValidated() throws {
        let option = try PlannerEngine.synthesize(input: input())
        let snapshot = AppSnapshot(exportedAt: now)
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, option: option, at: now)
        XCTAssertEqual(draft.options.count, 1)
        XCTAssertTrue(draft.matches(snapshot: snapshot, at: now))
        // A tampered option is refused by the draft validator itself.
        var tampered = draft.options[0]
        tampered.title = "被改过的标题"
        var badDraft = draft
        badDraft.options = [tampered]
        XCTAssertThrowsError(try badDraft.validate())
    }

    // MARK: - Readiness

    private func checkIn(energy: Int?, pain: Bool?, painAreas: [String] = []) -> PreWorkoutCheckIn {
        PreWorkoutCheckIn(createdAt: now, energy: energy, painReported: pain, painAreas: painAreas)
    }

    func testNoDataProducesGatherDataNotAHealthyVerdict() throws {
        let assessment = try ReadinessEngine.assess(checkIn: nil, health: nil, sessions: [],
                                                   profile: StructuredProfile(), now: now)
        XCTAssertEqual(assessment.verdict, .gatherData)
        XCTAssertNotEqual(assessment.verdict, .normal)
        XCTAssertTrue(assessment.evidence.isEmpty)
        XCTAssertLessThanOrEqual(assessment.confidenceLevel, 2)
    }

    func testReportedPainForcesStopRegardlessOfGoodRecovery() throws {
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 10,
                                 latestValue: 9, latestSampleAt: now.addingTimeInterval(-3_600),
                                 syncedAt: now, sourceName: "Watch", anchor: nil),
            HealthMetricSnapshot(metric: .heartRateVariabilitySDNN, state: .available,
                                 sampleCountInWindow: 20, latestValue: 90,
                                 latestSampleAt: now.addingTimeInterval(-3_600), syncedAt: now,
                                 sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 5, pain: true, painAreas: ["左肩"]),
                                                   health: health, sessions: [],
                                                   profile: StructuredProfile(), now: now)
        XCTAssertEqual(assessment.safetyVerdict, .stop)
        XCTAssertEqual(assessment.verdict, .stop)
        // Good sleep and HRV must not override reported pain.
        XCTAssertNotEqual(assessment.verdict, .normal)
    }

    func testUnansweredPainIsNotTreatedAsNoPain() throws {
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: nil), health: nil,
                                                   sessions: [], profile: StructuredProfile(), now: now)
        XCTAssertEqual(assessment.safetyVerdict, .gatherData)
        XCTAssertTrue(assessment.safety.contains("没有回答"))
        XCTAssertNotEqual(assessment.safetyVerdict, .normal)
    }

    func testShortSleepLeadsToConservativeSuggestion() throws {
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 5,
                                 latestValue: 4.5, latestSampleAt: now.addingTimeInterval(-3_600),
                                 syncedAt: now, sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: false), health: health,
                                                   sessions: [], profile: StructuredProfile(), now: now)
        XCTAssertTrue(assessment.recoveryEvidence.contains { $0.contains("低于") })
        XCTAssertEqual(assessment.verdict, .conservative)
    }

    func testHrvWithoutBaselineIsNotUsedForAVerdict() throws {
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .heartRateVariabilitySDNN, state: .available,
                                 sampleCountInWindow: 2, latestValue: 55,
                                 latestSampleAt: now.addingTimeInterval(-3_600), syncedAt: now,
                                 sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: false), health: health,
                                                   sessions: [], profile: StructuredProfile(), now: now)
        XCTAssertTrue(assessment.recoveryEvidence.contains { $0.contains("还没形成个人基线") })
        XCTAssertTrue(assessment.recoveryEvidence.contains { $0.contains("SDNN") })
    }

    func testStaleHealthDataIsFlaggedNotUsedSilently() throws {
        let old = now.addingTimeInterval(-60 * 86_400)
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .restingHeartRate, state: .stale, sampleCountInWindow: 3,
                                 latestValue: 62, latestSampleAt: old, syncedAt: now,
                                 sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: false), health: health,
                                                   sessions: [], profile: StructuredProfile(), now: now)
        XCTAssertTrue(assessment.limitations.contains { $0.contains("已过期") })
    }

    func testNormalVerdictRequiresRealEvidence() throws {
        // With a full picture the engine may say "normal", but never with zero evidence.
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: now)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now)
        profile.weekdays = .init(value: [1, 3], provenance: .stated, confirmedAt: now)
        profile.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: now)
        profile.equipment = .init(value: [.bodyweight], provenance: .stated, confirmedAt: now)
        profile.restrictions = .init(value: "无", provenance: .stated, confirmedAt: now)
        let finished = try finishedSession(start: now.addingTimeInterval(-2 * day))
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 6,
                                 latestValue: 8, latestSampleAt: now.addingTimeInterval(-3_600),
                                 syncedAt: now, sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: false),
                                                   health: health, sessions: [finished],
                                                   profile: profile, now: now)
        XCTAssertEqual(assessment.verdict, .normal)
        XCTAssertFalse(assessment.evidence.isEmpty)
        XCTAssertThrowsError(try ReadinessAssessment(safety: "测试", todaySuggestion: "继续",
                                                     confidence: "测试", verdict: .normal,
                                                     evidence: []).validate())
    }

    private func finishedSession(start: Date) throws -> WorkoutSession {
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        var session = WorkoutSession(name: "测试训练", startedAt: start,
                                     exercises: [WorkoutExercise(exercise: exercise,
                                                                 sets: [LoggedSet(reps: 10)])])
        try session.completeSet(exerciseID: session.exercises[0].id,
                                setID: session.exercises[0].sets[0].id,
                                at: start.addingTimeInterval(60))
        try session.finish(early: false, at: start.addingTimeInterval(600))
        return session
    }

    // MARK: - Adjustments

    private func fingerprint(planID: UUID? = nil) -> AdjustmentFingerprint {
        AdjustmentFingerprint(planVersionID: planID, profileDigest: "x")
    }

    func testStopVerdictNeverProposesAWORKOUTChange() throws {
        let plan = PlanVersion(name: "计划", items: [
            PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat")))
        ], confirmedAt: now)
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 2, pain: true, painAreas: ["腰"]),
                                                   health: nil, sessions: [],
                                                   profile: StructuredProfile(), now: now)
        let proposal = try AdjustmentEngine.proposeForToday(readiness: assessment, basePlan: plan,
                                                            fingerprint: fingerprint(planID: plan.id),
                                                            createdAt: now)
        XCTAssertEqual(proposal.kind, .keep)
        XCTAssertNil(proposal.todayItems)
        XCTAssertNil(proposal.proposedItems)
    }

    func testConservativeVerdictProducesATodayOnlyDowngrade() throws {
        let plan = PlanVersion(name: "计划", items: [
            PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat")),
                            setCount: 2, targetReps: 10)
        ], confirmedAt: now)
        let health = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .sleepAnalysis, state: .available, sampleCountInWindow: 5,
                                 latestValue: 4, latestSampleAt: now.addingTimeInterval(-3_600),
                                 syncedAt: now, sourceName: "Watch", anchor: nil)
        ])
        let assessment = try ReadinessEngine.assess(checkIn: checkIn(energy: 4, pain: false), health: health,
                                                   sessions: [], profile: StructuredProfile(), now: now)
        XCTAssertEqual(assessment.verdict, .conservative)
        let proposal = try AdjustmentEngine.proposeForToday(readiness: assessment, basePlan: plan,
                                                            fingerprint: fingerprint(planID: plan.id),
                                                            createdAt: now)
        XCTAssertEqual(proposal.kind, .todayOnly)
        XCTAssertEqual(proposal.todayItems?.first?.setCount, 1)
        XCTAssertNil(proposal.proposedItems)
    }

    func testStaleProposalIsDetected() {
        let proposal = AdjustmentProposal(kind: .todayOnly, reason: "测试", summary: "测试",
                                          todayItems: [PlannedExercise(
                                            exercise: ExerciseCatalog.exercise(id: "builtin.bodyweight-squat")!)],
                                          basedOn: fingerprint())
        XCTAssertFalse(AdjustmentEngine.isStale(proposal, currently: fingerprint()))
        XCTAssertTrue(AdjustmentEngine.isStale(proposal, currently: fingerprint(planID: UUID())))
    }

    func testAcceptedAdjustmentMustRecordAVersion() {
        var proposal = AdjustmentProposal(kind: .keep, reason: "原因", summary: "说明")
        XCTAssertThrowsError(try proposal.validate())
        proposal.decision = .accepted
        XCTAssertThrowsError(try proposal.validate())
        proposal.appliedPlanVersionID = UUID()
        XCTAssertNoThrow(try proposal.validate())
    }

    // MARK: - Health snapshot

    func testNoSamplesIsNotReportedAsDeniedPermission() {
        let snapshot = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .stepCount, state: .noSamples, syncedAt: now)
        ])
        let text = snapshot.userFacingSummary
        XCTAssertTrue(text.contains("暂无样本"))
        XCTAssertFalse(text.contains("拒绝"))
        XCTAssertTrue(text.contains("系统不单独告知"))
    }

    func testHealthMetricStateConsistency() {
        XCTAssertThrowsError(try HealthMetricSnapshot(metric: .stepCount, state: .available,
                                                      latestValue: nil, latestSampleAt: now,
                                                      syncedAt: now).validate())
        XCTAssertThrowsError(try HealthMetricSnapshot(metric: .stepCount, state: .noSamples,
                                                      latestValue: 10).validate())
        XCTAssertThrowsError(try HealthMetricSnapshot(metric: .stepCount, state: .unreadable,
                                                      failureReason: nil).validate())
        XCTAssertNoThrow(try HealthMetricSnapshot(metric: .stepCount, state: .unreadable,
                                                  failureReason: "查询失败").validate())
    }

    // MARK: - Reviews

    func testReviewCountsOnlyFinishedSessionsWithResults() throws {
        let finished = try finishedSession(start: now.addingTimeInterval(-2 * day))
        var ongoing = WorkoutSession(name: "未结束", startedAt: now.addingTimeInterval(-600))
        try ongoing.validate()
        let summary = try ReviewEngine.summarize(period: .week, sessions: [finished, ongoing],
                                                 checkIns: [], plan: nil, plannedDaysPerWeek: 3, now: now)
        XCTAssertEqual(summary.finishedSessionCount, 1)
        XCTAssertEqual(summary.completedWorkingSets, 1)
        XCTAssertTrue(summary.dataGaps.contains { $0.contains("训练前记录") })
        XCTAssertEqual(summary.completionRateText, "这段时间没有排期，无法计算完成率。")
    }

    func testReviewReportsUnansweredPainInsteadOfAssumingNone() throws {
        let checkIn = PreWorkoutCheckIn(createdAt: now.addingTimeInterval(-day), energy: 3, painReported: nil)
        let summary = try ReviewEngine.summarize(period: .week, sessions: [], checkIns: [checkIn],
                                                 plan: nil, plannedDaysPerWeek: 0, now: now)
        XCTAssertEqual(summary.checkInCount, 1)
        XCTAssertEqual(summary.answeredPainCount, 0)
        XCTAssertTrue(summary.dataGaps.contains { $0.contains("没有回答疼痛") })
    }

    func testWeeklyReviewProgressNeverInventsLoad() throws {
        let finished = try finishedSession(start: now.addingTimeInterval(-day))
        let summary = try ReviewEngine.summarize(period: .week, sessions: [finished],
                                                 checkIns: [], plan: nil, plannedDaysPerWeek: 0, now: now)
        let entry = try XCTUnwrap(summary.exerciseProgress.first)
        XCTAssertNil(entry.bestLoadKG)
        XCTAssertEqual(entry.bestReps, 10)
    }
}
