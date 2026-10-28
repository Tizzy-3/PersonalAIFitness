import Foundation
import XCTest
@testable import FitnessCore

final class AdaptiveInterviewTests: XCTestCase {
    func testCurrentAndHistoricalRuleVersionsRemainLoadableButUnknownVersionsFail() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        for version in ["interview-1", "interview-2", InterviewRules.rulesVersion] {
            let session = InterviewSession(createdAt: date, rulesVersion: version)
            let restored = try JSONDecoder().decode(InterviewSession.self, from: JSONEncoder().encode(session))
            try restored.validate()
            XCTAssertEqual(restored.rulesVersion, version)
        }
        XCTAssertThrowsError(try InterviewSession(createdAt: date, rulesVersion: "interview-future").validate())
    }
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private func ready() -> StructuredProfile {
        var value = StructuredProfile()
        value.adultStatus = .init(value: true, provenance: .stated, confirmedAt: start)
        value.primaryGoal = .init(value: .generalFitness, provenance: .confirmed, confirmedAt: start)
        value.experience = .init(value: .beginner, provenance: .stated, confirmedAt: start)
        value.weekdays = .init(value: [1, 3], provenance: .stated, confirmedAt: start)
        value.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: start)
        value.equipment = .init(value: [.bodyweight, .walkingSpace], provenance: .stated, confirmedAt: start)
        value.restrictions = .init(value: "无", provenance: .stated, confirmedAt: start)
        return value
    }
    func testSettledTopicAcceptsSpecificFollowUpWithoutOverwritingItsFact() throws {
        var session = InterviewSession(createdAt: start, phase: .ready, profile: ready())
        let question = InterviewQuestion(topic: .primaryGoal, kind: .text, prompt: "想改善哪一种日常活动？", detailKey: "primaryGoal.daily_outcome")
        let accepted = try session.appendTurn(.init(questions: [question]), at: start)
        XCTAssertEqual(accepted.questions.count, 1)
        try session.answer([.init(questionID: question.id, text: "希望抱孩子上楼不再气喘", answeredAt: start)], at: start)
        XCTAssertEqual(session.profile.primaryGoal, ready().primaryGoal)
        XCTAssertEqual(session.dialogueEvidence.first?.answer.text, "希望抱孩子上楼不再气喘")
        XCTAssertTrue(session.canContinueInterview)
        XCTAssertTrue(try session.appendTurn(.init(questions: [InterviewQuestion(topic: .primaryGoal, kind: .text, prompt: "重复问题", detailKey: "primaryGoal.daily_outcome")]), at: start).questions.isEmpty)
    }
    func testSkippedDetailDoesNotCloseWholeTopicOrLoopSameDetail() throws {
        var session = InterviewSession(createdAt: start)
        let first = InterviewQuestion(topic: .capability, kind: .text, prompt: "俯卧撑能做多少？", detailKey: "capability.push_ups")
        try session.appendTurn(.init(questions: [first]), at: start)
        try session.answer([.init(questionID: first.id, outcome: .skipped, answeredAt: start)], at: start)
        XCTAssertFalse(session.declinedTopics.contains(.capability))
        XCTAssertTrue(try session.appendTurn(.init(questions: [.init(topic: .capability, kind: .text, prompt: "重复", detailKey: "capability.push_ups")]), at: start).questions.isEmpty)
        XCTAssertEqual(try session.appendTurn(.init(questions: [.init(topic: .capability, kind: .text, prompt: "步行耐力呢？", detailKey: "capability.walking")]), at: start).questions.count, 1)
    }
    func testNaturalGoalAndEquipmentAreEvidenceNotInvalidEnumAssignments() throws {
        var session = InterviewSession(createdAt: start)
        let goal = InterviewQuestion(topic: .primaryGoal, kind: .text, prompt: "用自己的话说说目标")
        let gear = InterviewQuestion(topic: .equipment, kind: .multiChoice, prompt: "有什么器械？", options: ["家里那对可调哑铃", "小区步道"])
        try session.appendTurn(.init(questions: [goal, gear]), at: start)
        try session.answer([.init(questionID: goal.id, text: "想让腰围小一点，爬山轻松一些", answeredAt: start),
                            .init(questionID: gear.id, choices: ["家里那对可调哑铃"], answeredAt: start)], at: start)
        XCTAssertEqual(session.profile.primaryGoal.provenance, .unknown)
        XCTAssertEqual(session.profile.equipment.provenance, .unknown)
        XCTAssertEqual(session.dialogueEvidence.count, 2)
        try session.applyExtraction(.init(topic: .primaryGoal, rawValue: "generalFitness"), at: start)
        XCTAssertEqual(session.profile.primaryGoal.provenance, .inferred)
        XCTAssertFalse(session.profile.primaryGoal.isUsable)
    }
    func testPauseResumeAndRestartPreserveAllDialogueAndOwnWords() throws {
        var session = InterviewSession(createdAt: start)
        try session.addNarrative("夜班工作，想提高爬山能力", at: start)
        let question = InterviewQuestion(topic: .capability, kind: .text, prompt: "现在上山情况怎样？", detailKey: "capability.hiking")
        try session.appendTurn(.init(questions: [question]), at: start)
        try session.answer([.init(questionID: question.id, text: "半小时要休息一次", answeredAt: start)], at: start)
        try session.pause(at: start)
        XCTAssertFalse(session.canContinueInterview)
        let decoded = try JSONDecoder().decode(InterviewSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded, session)
        try session.resume(at: start)
        XCTAssertTrue(session.canContinueInterview)
        let restarted = try session.restartedPreservingProfile(at: start.addingTimeInterval(10))
        XCTAssertTrue(restarted.turns.isEmpty)
        XCTAssertEqual(restarted.allTurns, session.allTurns)
        XCTAssertEqual(restarted.narratives, session.narratives)
        XCTAssertEqual(restarted.dialogueEvidence.first?.answer.text, "半小时要休息一次")
    }
    func testAllKnownTopicsStillAllowDeeperInterviewAndNoForcedEnding() throws {
        var session = InterviewSession(createdAt: start, phase: .ready, profile: ready())
        XCTAssertTrue(session.canContinueInterview)
        let question = InterviewQuestion(topic: .equipment, kind: .text, prompt: "器械使用上有什么困难？", detailKey: "equipment.access_barriers")
        try session.appendTurn(.init(questions: [question]), at: start)
        try session.skipUnansweredForReview(at: start)
        XCTAssertTrue(session.unansweredQuestions.isEmpty)
        XCTAssertTrue(session.profile.isReadyForPlanning)
        XCTAssertTrue(session.canContinueInterview)
    }
    func testNewSafetyDetailRequiresExplicitReviewAndPreservesExistingFact() throws {
        var session = InterviewSession(createdAt: start, phase: .ready, profile: ready())
        let question = InterviewQuestion(topic: .restrictions, kind: .text, prompt: "有没有近期需要补充的不适？", detailKey: "restrictions.recent_change")
        try session.appendTurn(.init(questions: [question]), at: start)
        try session.answer([.init(questionID: question.id, text: "最近膝盖不舒服", answeredAt: start.addingTimeInterval(1))], at: start.addingTimeInterval(1))
        XCTAssertEqual(session.profile.restrictions.value, "无")
        XCTAssertTrue(session.needsSafetyReview)
        try session.setValue(.text("膝盖疼痛，等待专业建议"), for: .restrictions, at: start.addingTimeInterval(2))
        XCTAssertFalse(session.needsSafetyReview)
        XCTAssertThrowsError(try session.profile.planningInput())
    }
    func testOptionalBodyMeasurementsAreBoundedAndAgeCannotBypassAdultGate() throws {
        var session = InterviewSession(createdAt: start, phase: .ready, profile: ready())
        try session.setValue(.age(17), for: .age, at: start)
        XCTAssertThrowsError(try session.profile.planningInput())
        XCTAssertThrowsError(try session.setValue(.height(.infinity), for: .height, at: start))
        XCTAssertThrowsError(try session.setValue(.weight(0), for: .weight, at: start))
        try session.setValue(.height(175), for: .height, at: start)
        XCTAssertEqual(session.profile.weightKG.provenance, .unknown)
    }
    func testPreAdaptiveJSONDecodesNewFieldsAsUnknownWithoutChangingOldFacts() throws {
        let old = InterviewSession(createdAt: start, profile: ready(), rulesVersion: "interview-1")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        var profile = try XCTUnwrap(object["profile"] as? [String: Any])
        for key in ["ageYears", "heightCM", "weightKG"] { profile.removeValue(forKey: key) }
        object["profile"] = profile
        for key in ["narratives", "archivedTurns", "pausedAt", "reopenedTopicOffsets"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(InterviewSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.profile.primaryGoal, old.profile.primaryGoal)
        XCTAssertEqual(decoded.profile.ageYears.provenance, .unknown)
        XCTAssertNil(decoded.narratives)
        try decoded.validate()
        let snapshot = AppSnapshot(interview: decoded)
        let restored = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        XCTAssertEqual(restored.interview, decoded)
    }
    func testDetailKeyMustRemainBoundToItsSupportedTopic() {
        XCTAssertThrowsError(try InterviewQuestion(topic: .sleep, kind: .text, prompt: "问题", detailKey: "medical.diagnosis").validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .sleep, kind: .text, prompt: "问题", detailKey: "sleep.秘密").validate())
    }

    func testExplicitReopenChangesClosedQuestionContextWithoutLosingEarlierAnswers() throws {
        var session = InterviewSession(createdAt: start)
        let capability = InterviewQuestion(topic: .capability, kind: .text, prompt: "目前能力？", detailKey: "capability.current")
        let sleep = InterviewQuestion(topic: .sleep, kind: .text, prompt: "睡眠如何？", detailKey: "sleep.schedule")
        try session.appendTurn(.init(questions: [capability, sleep]), at: start)
        try session.answer([.init(questionID: capability.id, text: "能走30分钟", answeredAt: start),
                            .init(questionID: sleep.id, text: "作息不固定", answeredAt: start)], at: start)
        XCTAssertEqual(session.closedQuestionKeys, [capability.stableKey, sleep.stableKey].sorted())
        try session.reopenTopic(.capability, at: start.addingTimeInterval(1))
        XCTAssertEqual(session.closedQuestionKeys, [sleep.stableKey])
        XCTAssertEqual(session.dialogueEvidence.count, 2)
        var reopened = capability
        reopened.id = UUID()
        XCTAssertEqual(try session.appendTurn(.init(questions: [reopened]), at: start.addingTimeInterval(2)).questions.count, 1)
    }
}
