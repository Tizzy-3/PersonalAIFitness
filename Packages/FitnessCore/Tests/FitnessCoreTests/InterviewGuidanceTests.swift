import XCTest
import Foundation
@testable import FitnessCore

final class InterviewGuidanceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func ready() -> InterviewSession {
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: now)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now)
        profile.weekdays = .init(value: [1, 3, 5], provenance: .stated, confirmedAt: now)
        profile.minutesPerSession = .init(value: 35, provenance: .stated, confirmedAt: now)
        profile.equipment = .init(value: [.bodyweight, .walkingSpace, .dumbbells, .bench], provenance: .stated, confirmedAt: now)
        profile.restrictions = .init(value: "无", provenance: .stated, confirmedAt: now)
        return InterviewSession(createdAt: now, profile: profile)
    }

    func testFirstVisitAsksCoachWithoutRequiringUserInventedIntroduction() {
        let step = InterviewSession(createdAt: now).nextGuidanceStep(at: now)
        XCTAssertEqual(step, .askCoach)
        XCTAssertTrue(step.shouldAskOnEntry(continueInDepth: false))
    }
    func testPlanButtonReportsMissingFactsInsteadOfAskingAnotherQuestion() {
        // Entering the interview should still ask (see the first test). The *button* must not.
        let empty = InterviewSession(createdAt: now)
        XCTAssertEqual(empty.nextGuidanceStep(at: now), .askCoach)
        guard case .blocked(let reason) = empty.planButtonStep(at: now) else {
            return XCTFail("按钮不能静默变成继续提问")
        }
        XCTAssertTrue(reason.contains("还缺这些资料"), reason)
        // The message names the actual blockers, not a generic refusal.
        XCTAssertTrue(reason.contains("主要目标"), reason)
    }

    func testPlanDumpedIntoTheTransitionNoteIsRejected() {
        // A model told not to write a plan sometimes writes one into `note`, which used to render
        // as a paragraph and never reached the app. It must be refused, not displayed.
        let prescription = "好的，这是你的一周安排：" + "\n1. 周一 哑铃卧推 3组×10次\n2. 周三 单臂划船 3组×12次\n3. 周五 肩推 3组×8次"
        XCTAssertTrue(InterviewTurn.looksLikeAPlan(prescription))
        XCTAssertThrowsError(try InterviewTurn(createdAt: now, questions: [], note: prescription).validate())

        // An ordinary transition sentence must not trip the detector.
        let normal = "好的，我明白了。接下来我想先确认一下你平时能连续走多久？"
        XCTAssertFalse(InterviewTurn.looksLikeAPlan(normal))
        XCTAssertNoThrow(try InterviewTurn(createdAt: now, questions: [], note: normal).validate())
    }

    func testPlanButtonStillGeneratesWhenFactsAreComplete() {
        XCTAssertEqual(ready().planButtonStep(at: now), .readyForPlan)
    }

    func testSkippedRestrictionsRouteToExplicitConfirmationAndKeepSafetyChecks() throws {
        var session = ready()
        try session.markUnknown(.restrictions, at: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .confirmMissingRestrictions)
        XCTAssertEqual(session.planButtonStep(at: now), .confirmMissingRestrictions)
        XCTAssertFalse(session.nextGuidanceStep(at: now).shouldAskOnEntry(continueInDepth: true))
        XCTAssertFalse(session.planningEligibility(at: now).canGenerate)

        var unrestricted = session
        try unrestricted.setValue(.text("无"), for: .restrictions, at: now)
        XCTAssertEqual(unrestricted.planButtonStep(at: now), .readyForPlan)
        XCTAssertEqual(unrestricted.planButtonStep(legacyRestrictions: "医生要求避免剧烈运动", at: now), .clarifyLimits)

        try session.setValue(.text("医生要求避免剧烈运动"), for: .restrictions, at: now)
        XCTAssertFalse(session.declinedTopics.contains(.restrictions))
        XCTAssertEqual(session.planButtonStep(at: now), .clarifyLimits)
    }

    func testWhenOnlyRestrictionsAreMissingAppOffersDirectConfirmation() {
        var session = ready()
        session.profile.restrictions = .unknown
        XCTAssertTrue(session.declinedTopics.isEmpty)
        XCTAssertEqual(session.planButtonStep(at: now), .confirmMissingRestrictions)
    }

    func testEnoughFactsOffersPlanAndStillAllowsAIInitiatedDepth() {
        let step = ready().nextGuidanceStep(at: now)
        XCTAssertEqual(step, .readyForPlan)
        XCTAssertFalse(step.shouldAskOnEntry(continueInDepth: false))
        XCTAssertTrue(step.shouldAskOnEntry(continueInDepth: true))
    }
    func testPendingFactsMustBeVisibleAndConfirmedBeforeNewAutomaticQuestion() {
        var session = ready()
        session.profile.minutesPerSession = .init(value: 40, provenance: .inferred)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .reviewFacts)
        XCTAssertFalse(session.nextGuidanceStep(at: now).shouldAskOnEntry(continueInDepth: true))
    }
    func testExistingUnansweredQuestionIsResumedInsteadOfSendingAnotherRequest() throws {
        var session = InterviewSession(createdAt: now)
        try session.appendTurn(.init(questions: [.init(topic: .capability, kind: .text, prompt: "现在能连续走多久？")]), at: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .answerQuestions)
        XCTAssertFalse(session.nextGuidanceStep(at: now).shouldAskOnEntry(continueInDepth: true))
    }
    func testPlanEntryCannotSilentlySkipAnOptionalOpenQuestion() throws {
        var session = ready()
        try session.appendTurn(.init(questions: [.init(topic: .capability, kind: .text, prompt: "哪些动作需要帮助？")]), at: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .answerQuestions)
        XCTAssertEqual(session.unansweredQuestions.count, 1)
        XCTAssertFalse(session.planningEligibility(at: now).canGenerate)
    }
    func testUnreviewedLimitsRouteToGuidedClarificationInsteadOfPlanOrGenericChat() {
        // A floor-work preference is not inferred: only the person can decide how far it reaches, so
        // it still routes into the guided clarification.
        var session = ready()
        session.profile.restrictions = .init(value: "不做地面动作", provenance: .stated, confirmedAt: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .clarifyLimits)
    }

    func testKneelingPreferenceIsPlannedAroundWithoutAClarificationRound() {
        // The one preference the planner can honour on its own: 「不能跪」 means exactly two movements.
        var session = ready()
        session.profile.restrictions = .init(value: "不能有跪姿动作", provenance: .stated, confirmedAt: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .readyForPlan)
        XCTAssertNoThrow(try session.profile.planningInput(at: now))
    }
    func testPausedConversationDoesNotAutoSendOrLoseExistingProgress() throws {
        var session = ready()
        try session.pause(at: now)
        XCTAssertEqual(session.nextGuidanceStep(at: now), .resume)
        XCTAssertFalse(session.nextGuidanceStep(at: now).shouldAskOnEntry(continueInDepth: true))
    }
    func testCurrentPainBlocksPlanEvenWhenFactsAreComplete() {
        let session = ready()
        var snapshot = AppSnapshot(exportedAt: now, interview: session)
        snapshot.preWorkoutCheckIns = [.init(createdAt: now, painReported: true)]
        guard case .blocked = session.nextGuidanceStep(snapshot: snapshot, at: now) else {
            return XCTFail("Actual safety evidence must block the plan entry")
        }
    }
}
