import Foundation
import XCTest
@testable import FitnessCore

/// Synthetic preferences and schedules only; no private health narrative belongs in these fixtures.
final class SimpleCoachConversationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func ready() throws -> ConstraintChatSession {
        var chat = ConstraintChatSession(sourceText: "合成偏好：不安排地面动作", legacySourceText: "合成旧偏好")
        try chat.appendUser("合成回复：安排以站姿为主", at: now)
        try chat.receiveCandidate(.init(avoidedPositions: [.floorWork], excludedWeekdays: [2],
            restDateKeys: ["2026-11-12"], maxSessionMinutes: 25), evidenceCount: 1, at: now)
        chat.setMode(.practicalOnly); chat.setPainFree(true, at: now)
        return chat
    }

    func testConversationAndUnfinishedCandidateResumeFromSavedJSON() throws {
        var chat = try ready()
        try chat.appendCoach("合成问题：还有需要补充的安排吗？", at: now)
        var session = InterviewSession(createdAt: now, constraintChat: chat)
        session.profile.restrictions = .init(value: chat.sourceText, provenance: .stated, confirmedAt: now)
        session.constraintChat = chat
        let restored = try JSONDecoder().decode(InterviewSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)
        XCTAssertEqual(restored.constraintChat?.readbackLines, chat.readbackLines)
        XCTAssertEqual(try restored.constraintChat?.makeReview(at: now).sourceText, chat.sourceText)
    }

    func testClosingWithoutConfirmationLeavesOnlyDraftAndNoActiveReview() throws {
        let chat = try ready()
        let session = InterviewSession(createdAt: now, constraintChat: chat)
        let restored = try JSONDecoder().decode(InterviewSession.self, from: JSONEncoder().encode(session))
        XCTAssertNil(restored.profile.constraintReview)
        XCTAssertNil(restored.constraintChat?.confirmedAt)
        XCTAssertEqual(restored.constraintChat?.candidateEvidenceCount, 1)
    }

    func testOldInterviewJSONWithoutChatStillDecodes() throws {
        let data = try JSONEncoder().encode(InterviewSession(createdAt: now))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "constraintChat")
        let restored = try JSONDecoder().decode(InterviewSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.constraintChat)
        XCTAssertNoThrow(try restored.validate())
    }

    func testOlderChatWithoutAnswerTimestampDecodesButCannotReuseHealthAnswer() throws {
        let data = try JSONEncoder().encode(ready())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "painFreeAnsweredAt")
        let restored = try JSONDecoder().decode(ConstraintChatSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.painFreeAnsweredAt)
        XCTAssertThrowsError(try restored.makeReview(at: now))
    }

    func testNewUserReplyInvalidatesReadbackAndHealthAnswerButKeepsHistory() throws {
        var chat = try ready(); chat.confirmedAt = now
        let oldCandidate = chat.candidate
        try chat.appendUser("合成补充：另一天需要休息", at: now.addingTimeInterval(1))
        XCTAssertEqual(chat.candidate, oldCandidate)
        XCTAssertNil(chat.candidateEvidenceCount); XCTAssertNil(chat.painFree)
        XCTAssertNil(chat.painFreeAnsweredAt); XCTAssertNil(chat.confirmedAt)
        XCTAssertEqual(chat.messages.count, 2)
        XCTAssertThrowsError(try chat.makeReview(at: now.addingTimeInterval(2)))
        XCTAssertTrue(chat.readbackLines[0].contains("旧整理"))
    }

    func testAsyncStaleResponseCannotOverwriteNewReplyAtomically() throws {
        var chat = try ready()
        try chat.appendUser("合成补充", at: now.addingTimeInterval(1))
        let before = chat
        XCTAssertThrowsError(try chat.receiveCandidate(.init(), evidenceCount: 1, at: now.addingTimeInterval(2)))
        XCTAssertEqual(chat, before)
        try chat.appendCoach("合成说明", at: now.addingTimeInterval(2))
        try chat.receiveCandidate(.init(), evidenceCount: 2, at: now.addingTimeInterval(3))
        XCTAssertEqual(chat.candidateEvidenceCount, 2, "Evidence counts user replies, not all messages")
    }

    func testInvalidMessageOrCandidateLeavesConversationUnchanged() throws {
        var chat = try ready(); let before = chat
        XCTAssertThrowsError(try chat.appendUser("  ", at: now))
        XCTAssertEqual(chat, before)
        XCTAssertThrowsError(try chat.appendCoach("合成倒序消息", at: now.addingTimeInterval(-1)))
        XCTAssertEqual(chat, before)
        XCTAssertThrowsError(try chat.receiveCandidate(.init(excludedWeekdays: [8]), evidenceCount: 1, at: now))
        XCTAssertEqual(chat, before)
    }

    func testCandidateOnlyAcceptsRealSupportedPlanningIDsAndStrictDates() throws {
        XCTAssertThrowsError(try ConstraintChatCandidate(excludedExerciseIDs: ["imaginary.exercise"]).validate())
        let unsupported = try XCTUnwrap(ExerciseCatalog.exercises.first { !PlannerEngine.supportedMovementIDs.contains($0.id) })
        XCTAssertThrowsError(try ConstraintChatCandidate(allowedExerciseIDs: [unsupported.id]).validate())
        for value in ["2026-02-30", "2026-2-03", "2026-11-12T00:00:00Z"] {
            XCTAssertThrowsError(try ConstraintChatCandidate(restDateKeys: [value]).validate())
        }
        XCTAssertThrowsError(try ConstraintChatCandidate(excludedWeekdays: [2, 2]).validate())
        XCTAssertThrowsError(try ConstraintChatCandidate(maxSessionMinutes: 14).validate())
        XCTAssertThrowsError(try ConstraintChatCandidate(allowedExerciseIDs: []).validate())
        XCTAssertThrowsError(try ConstraintChatCandidate(avoidedPositions: [.kneeling], allowedExerciseIDs: ["builtin.bird-dog"]).validate())
    }

    func testModelWhitelistNeverAuthorizesHealthOrMode() throws {
        var chat = ConstraintChatSession(sourceText: "合成限制")
        try chat.receiveCandidate(.init(allowedExerciseIDs: ["builtin.walking"]), evidenceCount: 0, at: now)
        XCTAssertNil(chat.mode); XCTAssertNil(chat.painFree)
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.setMode(.professionalBoundaries)
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.setPainFree(true, at: now)
        XCTAssertThrowsError(try chat.makeReview(at: now), "Professional note must come from the human")
        chat.professionalNote = "合成指导：只安排已明确列出的活动"
        XCTAssertEqual(try chat.makeReview(at: now).allowedExerciseIDs, ["builtin.walking"])
    }

    func testProfessionalModeRequiresBothHumanNoteAndWhitelist() throws {
        var chat = try ready(); chat.setMode(.professionalBoundaries)
        chat.professionalNote = "合成指导"
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.candidate?.allowedExerciseIDs = ["builtin.walking"]
        XCTAssertNoThrow(try chat.makeReview(at: now))
        chat.professionalNote = " "
        XCTAssertThrowsError(try chat.makeReview(at: now))
    }

    func testQuestionsUnknownsAndNonaffirmativeHumanAnswersBlockConfirmation() throws {
        var chat = try ready()
        chat.candidate?.questions = ["合成待问"]
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.candidate?.questions = []; chat.candidate?.unresolved = ["合成未知"]
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.candidate?.unresolved = []; chat.setPainFree(false, at: now)
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.setPainFree(nil, at: now)
        XCTAssertThrowsError(try chat.makeReview(at: now))
    }

    func testYesterdayOrFutureHealthAnswerCannotCreateTodayReview() throws {
        var chat = try ready()
        XCTAssertThrowsError(try chat.makeReview(at: now.addingTimeInterval(86_400)))
        chat.setPainFree(true, at: now.addingTimeInterval(1))
        XCTAssertThrowsError(try chat.makeReview(at: now))
    }

    func testSourceEditsInvalidateButPreserveUnfinishedConversation() throws {
        for legacy in [false, true] {
            var chat = try ready(); let messages = chat.messages
            if legacy { chat.legacySourceText = "合成更新的旧档案" } else { chat.sourceText = "合成更新的限制" }
            XCTAssertEqual(chat.messages, messages); XCTAssertNotNil(chat.candidate)
            XCTAssertNil(chat.candidateEvidenceCount); XCTAssertNil(chat.painFree)
            XCTAssertThrowsError(try chat.makeReview(at: now))
        }
        var session = InterviewSession(createdAt: now, constraintChat: try ready())
        session.profile.restrictions = .init(value: "合成新原文", provenance: .stated, confirmedAt: now)
        XCTAssertNotNil(session.constraintChat?.candidate)
        XCTAssertNil(session.constraintChat?.candidateEvidenceCount)
        XCTAssertNoThrow(try session.validate(), "Stale conversation remains resumable and never blocks raw profile edits")
    }

    func testReadbackRepresentsEveryExecutableLimitWithRealNamesDeterministically() throws {
        var chat = try ready()
        chat.candidate?.excludedExerciseIDs = ["builtin.goblet-squat"]
        chat.candidate?.allowedExerciseIDs = ["builtin.walking"]
        let readback = chat.readbackLines.joined(separator: "\n")
        XCTAssertTrue(readback.contains("周二")); XCTAssertTrue(readback.contains("2026-11-12"))
        XCTAssertTrue(readback.contains("25分钟")); XCTAssertTrue(readback.contains(ConstraintAvoidance.floorWork.title))
        for id in ["builtin.goblet-squat", "builtin.walking", "builtin.bird-dog"] {
            XCTAssertTrue(readback.contains(try XCTUnwrap(ExerciseCatalog.exercise(id: id)).name))
        }
        XCTAssertEqual(chat.readbackLines, chat.readbackLines)
        let review = try chat.makeReview(at: now)
        XCTAssertTrue(review.allLimitsRepresentedConfirmed); XCTAssertTrue(review.painFreeConfirmed)
        XCTAssertEqual(review.sourceText, chat.sourceText); XCTAssertEqual(review.legacySourceText, chat.legacySourceText)
        XCTAssertNil(chat.confirmedAt, "Creating a review cannot silently persist consent or apply a plan")
    }

    func testVisibleInferenceBatchRejectsMissingDuplicateOrNewHiddenFactsAtomically() throws {
        var profile = StructuredProfile()
        profile.ageYears = .init(value: 33, provenance: .inferred)
        profile.minutesPerSession = .init(value: 30, provenance: .inferred)
        var session = InterviewSession(createdAt: now, profile: profile)
        let before = session
        let invalidTopicSets: [[InterviewTopic]] = [[.age], [.age, .age], [.age, .minutes, .height]]
        for topics in invalidTopicSets {
            XCTAssertThrowsError(try session.confirmVisibleInferences(topics, at: now))
            XCTAssertEqual(session, before)
        }
        XCTAssertThrowsError(try session.confirmVisibleInferences([.age, .minutes], at: now.addingTimeInterval(-1)))
        XCTAssertEqual(session, before)
        try session.confirmVisibleInferences([.minutes, .age], at: now)
        XCTAssertTrue(session.pendingInferences.isEmpty)
        XCTAssertEqual(session.profile.ageYears.provenance, .confirmed)
        XCTAssertEqual(session.profile.minutesPerSession.provenance, .confirmed)
    }
}
