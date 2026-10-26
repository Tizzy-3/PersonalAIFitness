import Foundation
import XCTest
@testable import FitnessCore

final class CoachFollowUpContextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))

    private func profile() -> StructuredProfile {
        var value = StructuredProfile()
        value.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        value.primaryGoal = .init(value: .strength, provenance: .confirmed, confirmedAt: now.addingTimeInterval(-60))
        value.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        value.weekdays = .init(value: [1, 3], provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        value.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        value.equipment = .init(value: [.bodyweight], provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        value.restrictions = .init(value: "无", provenance: .stated, confirmedAt: now.addingTimeInterval(-60))
        return value
    }

    private func snapshot() throws -> AppSnapshot {
        var session = WorkoutSession(name: "协议夹具训练", startedAt: now.addingTimeInterval(-120))
        try session.finish(early: true, at: now.addingTimeInterval(-60))
        let checkIn = PreWorkoutCheckIn(createdAt: now, energy: 3, painReported: false, availableMinutes: 25)
        // Objective feedback values are deliberately incorrect, to check the outbound DTO recomputes them.
        let feedback = SessionFeedback(sessionID: session.id, createdAt: now, completedWorkingSets: 999,
                                       totalSeconds: 999, perceivedExertion: 8, tooHard: true)
        return AppSnapshot(sessions: [session], interview: InterviewSession(createdAt: now.addingTimeInterval(-60), profile: profile()),
                           preWorkoutCheckIns: [checkIn], sessionFeedback: [feedback])
    }

    func testFollowUpUsesSavedUserFactsAndRecomputedObjectiveResults() throws {
        let source = try snapshot()
        let context = try CoachContext.make(snapshot: source, at: now)
        let value = try XCTUnwrap(context.followUp)
        XCTAssertEqual(value.confirmedProfile?.primaryGoal, .strength)
        XCTAssertNil(value.confirmedProfile?.secondaryGoals)
        XCTAssertEqual(value.todayCheckIn?.energy, 3)
        XCTAssertEqual(value.todayCheckIn?.painReported, false)
        XCTAssertEqual(value.recentFeedback.first?.completedWorkingSets, 0)
        XCTAssertEqual(value.recentFeedback.first?.totalSeconds, 60)
        XCTAssertTrue(value.readiness.recoveryEvidence.contains { $0.contains("过难") })
        XCTAssertTrue(context.evidenceIDs.contains("coach-profile"))
        XCTAssertTrue(context.evidenceIDs.contains("readiness"))
        XCTAssertTrue(context.evidenceIDs.contains("checkin:\(source.preWorkoutCheckIns![0].id.uuidString)"))
        XCTAssertTrue(context.evidenceIDs.contains("feedback:\(source.sessionFeedback![0].id.uuidString)"))
        try context.validate()
    }

    func testPrivateFreeTextInferredValuesAndHealthTokensNeverReachPayload() throws {
        var source = try snapshot()
        source.interview?.profile.capabilityNote = .init(value: "PRIVATE-CAPABILITY", provenance: .confirmed, confirmedAt: now)
        source.interview?.profile.venue = .init(value: "PRIVATE-ADDRESS", provenance: .confirmed, confirmedAt: now)
        source.interview?.profile.equipmentLoads = .init(value: ["PRIVATE-LOAD-NOTE"], provenance: .confirmed, confirmedAt: now)
        source.interview?.profile.restrictions = .init(value: "PRIVATE-INJURY-PROSE", provenance: .confirmed, confirmedAt: now)
        source.interview?.profile.secondaryGoals = .init(value: [.endurance], provenance: .inferred, note: "PRIVATE-INFERENCE")
        source.preWorkoutCheckIns?[0].note = "PRIVATE-DAILY-NOTE"
        source.preWorkoutCheckIns?[0].painReported = true
        source.preWorkoutCheckIns?[0].painAreas = ["PRIVATE-PAIN-AREA"]
        source.sessionFeedback?[0].barrierNote = "PRIVATE-BARRIER"
        source.sessionFeedback?[0].painReported = true
        source.sessionFeedback?[0].painAreas = ["PRIVATE-FEEDBACK-AREA"]
        source.healthSnapshot = HealthSnapshot(capturedAt: now, metrics: [
            HealthMetricSnapshot(metric: .heartRateVariabilitySDNN, state: .available, sampleCountInWindow: 4,
                                 latestValue: 55, latestSampleAt: now.addingTimeInterval(-60), syncedAt: now,
                                 sourceName: "测试健康来源", anchor: Data("PRIVATE-ANCHOR".utf8))
        ])
        let context = try CoachContext.make(snapshot: source, at: now)
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE-"))
        XCTAssertFalse(json.contains("anchor"))
        XCTAssertFalse(json.contains("cachedSamples"))
        XCTAssertFalse(json.contains("questionID"))
        XCTAssertNil(context.followUp?.confirmedProfile?.secondaryGoals)
        XCTAssertEqual(context.followUp?.confirmedProfile?.restrictionStatus, .reported)
        XCTAssertEqual(context.followUp?.readiness.safetyVerdict, .stop)
        XCTAssertEqual(context.followUp?.healthMetrics.first?.latestValue, 55)
    }

    func testHealthAgesAtRequestTimeAndOldReadinessIsNotTrusted() throws {
        var source = try snapshot()
        source.preWorkoutCheckIns?[0].painReported = nil
        source.healthSnapshot = HealthSnapshot(capturedAt: now.addingTimeInterval(-10 * 86_400), metrics: [
            HealthMetricSnapshot(metric: .restingHeartRate, state: .available, sampleCountInWindow: 8,
                                 latestValue: 60, latestSampleAt: now.addingTimeInterval(-10 * 86_400), syncedAt: now.addingTimeInterval(-10 * 86_400))
        ])
        source.latestReadiness = ReadinessAssessment(createdAt: now.addingTimeInterval(-10 * 86_400),
            safety: "历史夹具", confidence: "历史夹具", todaySuggestion: "历史夹具", verdict: .normal,
            evidence: [ReadinessEvidence(id: "old-evidence", kind: .checkIn, label: "旧证据")])
        let value = try XCTUnwrap(CoachContext.make(snapshot: source, at: now).followUp)
        XCTAssertEqual(value.healthMetrics.first?.state, .stale)
        XCTAssertEqual(value.readiness.safetyVerdict, .gatherData)
        XCTAssertEqual(value.readiness.verdict, .gatherData)
        XCTAssertFalse(value.readiness.evidenceIDs.contains("old-evidence"))
    }

    func testSameSourceProfileValueChangeAndSameIDCheckInEditInvalidateOldSuggestion() throws {
        let source = try snapshot()
        let context = try CoachContext.make(snapshot: source, at: now)
        XCTAssertTrue(context.matches(snapshot: source))
        var changedProfile = source
        // Even a private, omitted field changes the fingerprint without sending its contents.
        changedProfile.interview?.profile.venue = .init(value: "PRIVATE-NEW-VENUE", provenance: .confirmed, confirmedAt: now)
        XCTAssertFalse(context.matches(snapshot: changedProfile))
        var changedCheckIn = source
        changedCheckIn.preWorkoutCheckIns?[0].energy = 1
        XCTAssertFalse(context.matches(snapshot: changedCheckIn))
        var changedFeedback = source
        changedFeedback.sessionFeedback?[0].perceivedExertion = 10
        XCTAssertFalse(context.matches(snapshot: changedFeedback))
    }

    func testSameInputsProduceStableFollowUpDespiteAssessmentUUIDs() throws {
        let source = try snapshot()
        let first = try CoachContext.make(snapshot: source, at: now)
        let second = try CoachContext.make(snapshot: source, at: now)
        XCTAssertEqual(first.followUp, second.followUp)
        XCTAssertEqual(first.evidenceIDs, second.evidenceIDs)
    }

    func testOldContextJSONWithoutFollowUpStillDecodesAndMatchesLegacySnapshot() throws {
        let source = AppSnapshot()
        let old = try CoachContext.make(snapshot: source, at: now)
        XCTAssertNil(old.followUp)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "followUp")
        let decoded = try JSONDecoder().decode(CoachContext.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.followUp)
        XCTAssertTrue(decoded.matches(snapshot: source))
        try decoded.validate()
    }

    func testUnknownSafetyBlocksSpecificProposalEvenWhenLegacyProfileHasNoRestriction() throws {
        var source = try snapshot()
        source.preWorkoutCheckIns?[0].painReported = nil
        let plan = PlanVersion(name: "已有单日计划", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])],
                               confirmedAt: now.addingTimeInterval(-180))
        source.planVersions = [plan]; source.activePlanVersionID = plan.id
        let context = try CoachContext.make(snapshot: source, at: now)
        XCTAssertTrue(context.profile.restrictions.isEmpty)
        let proposal = CoachProposal(reason: "夹具：保守减量", targetPlanVersionID: plan.id, items: [
            CoachProposedItem(exerciseID: plan.items[0].exercise.id, setCount: 2,
                              targetReps: plan.items[0].targetReps, targetSeconds: plan.items[0].targetSeconds,
                              restSeconds: plan.items[0].restSeconds)
        ])
        XCTAssertThrowsError(try CoachReply(answer: "仍返回具体调整", evidence: ["plan"], limitations: [], proposal: proposal).validate(context: context))
        XCTAssertNoThrow(try CoachReply(answer: "请先确认今天疼痛状态", evidence: ["readiness"], limitations: []).validate(context: context))
    }

    func testSavedReviewStatisticsKeepTheirOriginalWindowAndDoNotSendGapProse() throws {
        var source = try snapshot()
        let review = ReviewSummary(createdAt: now.addingTimeInterval(-60), period: .week,
            windowStart: now.addingTimeInterval(-7 * 86_400), windowEnd: now.addingTimeInterval(-60),
            finishedSessionCount: 1, plannedSessionCount: 3, completedWorkingSets: 0,
            totalTrainingSeconds: 60, dataGaps: ["PRIVATE-REVIEW-NOTE"], completedPlannedSessionCount: 1)
        source.reviewSummaries = [review]
        let context = try CoachContext.make(snapshot: source, at: now)
        let sent = try XCTUnwrap(context.followUp?.savedReviews.first)
        XCTAssertEqual(sent.finishedSessionCount, 1)
        XCTAssertEqual(sent.completedPlannedSessionCount, 1)
        XCTAssertEqual(sent.windowEnd, review.windowEnd)
        XCTAssertEqual(sent.recordedDataGapCount, 1)
        XCTAssertTrue(context.evidenceIDs.contains("review:\(review.id.uuidString)"))
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE-REVIEW-NOTE"))
    }
}
