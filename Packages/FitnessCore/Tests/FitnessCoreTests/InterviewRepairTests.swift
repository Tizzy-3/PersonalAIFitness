import Foundation
import XCTest
@testable import FitnessCore

/// Behavioural regression fixtures for the actual question/answer path; not real personal data.
final class InterviewRepairTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func question(_ topic: InterviewTopic, kind: InterviewQuestionKind = .text) -> InterviewQuestion {
        InterviewQuestion(topic: topic, kind: kind, prompt: "请说明\(topic.title)。")
    }

    private func readyProfile() -> StructuredProfile {
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: start)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .confirmed, confirmedAt: start)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: start)
        profile.weekdays = .init(value: [1, 3], provenance: .stated, confirmedAt: start)
        profile.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: start)
        profile.equipment = .init(value: [.bodyweight, .walkingSpace], provenance: .stated, confirmedAt: start)
        profile.restrictions = .init(value: "无", provenance: .stated, confirmedAt: start)
        return profile
    }

    func testAdultBooleanAnswersArePersistedAsStatedRatherThanRejected() throws {
        for flag in [true, false] {
            var session = InterviewSession(createdAt: start)
            let adult = question(.adultStatus, kind: .boolean)
            try session.appendTurn(InterviewTurn(questions: [adult]), at: start)
            try session.answer([InterviewAnswer(questionID: adult.id, boolean: flag, answeredAt: start)], at: start)
            XCTAssertEqual(session.profile.adultStatus.value, flag)
            XCTAssertEqual(session.profile.adultStatus.provenance, .stated)
            XCTAssertEqual(session.profile.adultStatus.confirmedAt, start)
            XCTAssertTrue(session.unansweredQuestions.isEmpty)
            try session.validate()
            if !flag {
                var complete = readyProfile()
                complete.adultStatus = session.profile.adultStatus
                XCTAssertThrowsError(try complete.planningInput())
            }
        }
    }

    func testPositiveRestrictionAnswerIsSavedAndBlocksPlanning() throws {
        var profile = readyProfile()
        profile.restrictions = .unknown
        var session = InterviewSession(createdAt: start, profile: profile)
        let restriction = question(.restrictions, kind: .boolean)
        try session.appendTurn(InterviewTurn(questions: [restriction]), at: start)
        try session.answer([InterviewAnswer(questionID: restriction.id, boolean: true, answeredAt: start)], at: start)
        XCTAssertEqual(session.profile.restrictions.provenance, .stated)
        XCTAssertTrue(session.profile.restrictions.value?.contains("存在运动限制") == true)
        XCTAssertTrue(session.unansweredQuestions.isEmpty)
        XCTAssertThrowsError(try session.profile.planningInput())
    }

    func testPartialAnswerCannotBeHiddenByAppendingAnotherTurn() throws {
        var session = InterviewSession(createdAt: start)
        let sleep = question(.sleep)
        let venue = question(.venue)
        try session.appendTurn(InterviewTurn(questions: [sleep, venue]), at: start)
        try session.answer([InterviewAnswer(questionID: sleep.id, text: "夜班，作息不固定", answeredAt: start)], at: start)
        let before = session
        XCTAssertThrowsError(try session.appendTurn(InterviewTurn(questions: [question(.capability)]), at: start))
        XCTAssertEqual(session, before)
        XCTAssertEqual(session.unansweredQuestions.map(\.id), [venue.id])
        try session.answer([InterviewAnswer(questionID: venue.id, outcome: .skipped, answeredAt: start)], at: start)
        XCTAssertNoThrow(try session.appendTurn(InterviewTurn(questions: [question(.capability)]), at: start))
    }

    func testOlderOrphanedQuestionCanStillBeAnsweredAfterReopen() throws {
        let sleep = question(.sleep)
        let venue = question(.venue)
        // Represents data produced by the older app, which allowed a new turn too early.
        var session = InterviewSession(createdAt: start, turns: [
            InterviewTurn(createdAt: start, questions: [sleep]),
            InterviewTurn(createdAt: start, questions: [venue])
        ])
        try session.validate()
        XCTAssertEqual(session.unansweredQuestions.map(\.id), [sleep.id, venue.id])
        try session.answer([InterviewAnswer(questionID: sleep.id, text: "睡眠不固定", answeredAt: start)], at: start)
        XCTAssertEqual(session.profile.sleepNote.value, "睡眠不固定")
        XCTAssertEqual(session.unansweredQuestions.map(\.id), [venue.id])
        XCTAssertThrowsError(try session.appendTurn(InterviewTurn(questions: []), at: start))
    }

    func testExtractionCannotOverwriteSettledFactOrPendingInference() throws {
        var session = InterviewSession(createdAt: start)
        try session.setValue(.minutes(30), for: .minutes, at: start)
        let before = session
        try session.applyExtraction(InterviewExtraction(topic: .minutes, rawValue: "60"), at: start)
        XCTAssertEqual(session, before)
        let accepted = try session.appendTurn(InterviewTurn(extractions: [
            InterviewExtraction(topic: .minutes, rawValue: "60")
        ]), at: start)
        XCTAssertTrue(accepted.extractions.isEmpty)
        XCTAssertEqual(session.profile.minutesPerSession.value, 30)
        XCTAssertEqual(session.profile.minutesPerSession.provenance, .confirmed)

        try session.applyExtraction(InterviewExtraction(topic: .sleep, rawValue: "约七小时"), at: start)
        try session.applyExtraction(InterviewExtraction(topic: .sleep, rawValue: "约九小时"), at: start)
        XCTAssertEqual(session.profile.sleepNote.value, "约七小时")
        XCTAssertEqual(session.profile.sleepNote.provenance, .inferred)
    }

    func testSkippedTopicCannotBeRepopulatedByModelUntilExplicitlyReopened() throws {
        var session = InterviewSession(createdAt: start)
        try session.markUnknown(.sleep, at: start)
        try session.applyExtraction(InterviewExtraction(topic: .sleep, rawValue: "睡眠良好"), at: start)
        XCTAssertEqual(session.profile.sleepNote.provenance, .unknown)
        XCTAssertFalse(session.openTopics.contains(.sleep))
        try session.reopenTopic(.sleep, at: start)
        XCTAssertTrue(session.openTopics.contains(.sleep))
        XCTAssertFalse(session.declinedTopics.contains(.sleep))
        try session.appendTurn(InterviewTurn(questions: [question(.sleep)]), at: start)
        XCTAssertEqual(session.unansweredQuestions.map(\.topic), [.sleep])
    }

    func testReopeningOneFieldPreservesOtherFactsAndLeavesPlanForSeparateConfirmation() throws {
        let oldPlan = UUID()
        var session = InterviewSession(createdAt: start, phase: .planConfirmed,
                                       profile: readyProfile(), appliedPlanVersionID: oldPlan)
        let oldProfile = session.profile
        try session.reopenTopic(.minutes, at: start)
        XCTAssertNil(session.profile.minutesPerSession.value)
        XCTAssertNil(session.appliedPlanVersionID)
        XCTAssertEqual(session.profile.primaryGoal, oldProfile.primaryGoal)
        XCTAssertEqual(session.profile.restrictions, oldProfile.restrictions)
        XCTAssertEqual(session.phase, .inProgress)
        XCTAssertTrue(session.openTopics.contains(.minutes))
        try session.validate()
    }

    func testRestartRetainsSettledProfileAndSkipPreferencesButNotUnconfirmedGuesses() throws {
        var profile = readyProfile()
        profile.sleepNote = .init(value: "模型推测", provenance: .inferred)
        profile.venue = .init(value: "家中", provenance: .confirmed, confirmedAt: start)
        let session = InterviewSession(createdAt: start, phase: .planConfirmed, profile: profile,
                                       turns: [InterviewTurn(createdAt: start, note: "旧访谈")],
                                       declinedTopics: [.adherence], appliedPlanVersionID: UUID())
        let restarted = try session.restartedPreservingProfile(at: start.addingTimeInterval(60))
        XCTAssertNotEqual(restarted.id, session.id)
        XCTAssertEqual(restarted.profile.primaryGoal, profile.primaryGoal)
        XCTAssertEqual(restarted.profile.venue, profile.venue)
        XCTAssertEqual(restarted.profile.sleepNote, .unknown)
        XCTAssertEqual(restarted.declinedTopics, [.adherence])
        XCTAssertTrue(restarted.turns.isEmpty)
        XCTAssertNil(restarted.appliedPlanVersionID)
        XCTAssertEqual(restarted.phase, .ready)
        try restarted.validate()
        // The source session remains untouched until storage commits the replacement.
        XCTAssertEqual(session.profile.sleepNote.provenance, .inferred)
    }

    func testReadyProfileMayContinueOptionalInterviewWithoutChangingKnownValues() throws {
        var session = InterviewSession(createdAt: start, phase: .ready, profile: readyProfile())
        XCTAssertTrue(session.canContinueInterview)
        let capability = question(.capability)
        try session.appendTurn(InterviewTurn(questions: [capability]), at: start)
        XCTAssertFalse(session.canContinueInterview)
        try session.answer([InterviewAnswer(questionID: capability.id, text: "可连续步行二十分钟", answeredAt: start)], at: start)
        XCTAssertTrue(session.canContinueInterview)
        XCTAssertEqual(session.profile.capabilityNote.value, "可连续步行二十分钟")
        XCTAssertTrue(session.profile.isReadyForPlanning)
    }

    func testAppendFailureDoesNotMutateSessionOnReusedQuestionIdentifier() throws {
        let first = question(.sleep)
        var session = InterviewSession(createdAt: start)
        try session.appendTurn(InterviewTurn(questions: [first]), at: start)
        try session.answer([InterviewAnswer(questionID: first.id, outcome: .unknown, answeredAt: start)], at: start)
        let before = session
        XCTAssertThrowsError(try session.appendTurn(InterviewTurn(questions: [first]), at: start))
        XCTAssertEqual(session, before)
    }
}
