import XCTest
import FitnessCore
@testable import PersonalFitness

/// Synthetic conversations: no private health statements or provider requests.
final class SimpleCoachPersistenceTests: XCTestCase {
    @MainActor private func conversation(_ store: TrainingStore, at date: Date) throws -> InterviewSession {
        var session = try store.startInterview(at: date.addingTimeInterval(-10))
        session.profile.restrictions = .init(value: "不喜欢跪姿，周五另有安排", provenance: .stated,
                                             confirmedAt: date.addingTimeInterval(-5))
        var chat = ConstraintChatSession(sourceText: session.profile.restrictions.value!,
                                         legacySourceText: store.profile.restrictions)
        try chat.appendUser("周五休息，避开跪姿，最多25分钟", at: date.addingTimeInterval(-3))
        try chat.receiveCandidate(.init(avoidedPositions: [.kneeling], excludedWeekdays: [5],
                                         maxSessionMinutes: 25), evidenceCount: 1, at: date.addingTimeInterval(-2))
        chat.setMode(.practicalOnly)
        chat.setPainFree(true, at: date.addingTimeInterval(-1))
        session.constraintChat = chat
        return session
    }

    @MainActor func testUnfinishedChatSurvivesBackupWithoutConfirmingOrReplacingManualPlan() throws {
        let date = Date()
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "现有手动计划", items: [PlannedExercise(exercise: XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.walking")))])
        let expected = try conversation(store, at: date)
        try store.saveInterview(expected)
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot())))
        XCTAssertEqual(restored.interview?.constraintChat, expected.constraintChat)
        XCTAssertNil(restored.interview?.profile.constraintReview)
        XCTAssertEqual(restored.currentPlan?.id, manual.id)
        XCTAssertTrue(restored.weeklyPrograms.isEmpty)
    }

    @MainActor func testExplicitReadbackConfirmationSavesBoundariesButDoesNotActivatePlan() throws {
        let date = Date()
        let store = try TrainingStore(inMemory: true)
        var session = try conversation(store, at: date)
        var chat = try XCTUnwrap(session.constraintChat)
        let original = session.profile.restrictions.value
        try session.confirmConstraintReview(chat.makeReview(at: date), at: date)
        chat.confirmedAt = date; session.constraintChat = chat
        try store.saveInterview(session)
        XCTAssertEqual(store.interview?.profile.restrictions.value, original)
        XCTAssertEqual(store.interview?.profile.constraintReview?.excludedWeekdays, [5])
        XCTAssertEqual(store.interview?.profile.constraintReview?.maxSessionMinutes, 25)
        XCTAssertTrue(store.planVersions.isEmpty)
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
    }

    @MainActor func testChatResumesFromRealSwiftDataStoreAndNewReplyRequiresNewReadback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SimpleCoach-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("fitness.store")
        let date = Date()
        let expected: InterviewSession
        do {
            let store = try TrainingStore(storageURL: url)
            expected = try conversation(store, at: date)
            try store.saveInterview(expected)
        }
        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.interview?.constraintChat, expected.constraintChat)
        var session = try XCTUnwrap(reopened.interview)
        var chat = try XCTUnwrap(session.constraintChat)
        try chat.appendUser("周六也需要休息", at: date.addingTimeInterval(1))
        session.constraintChat = chat
        try reopened.saveInterview(session)
        XCTAssertThrowsError(try chat.makeReview(at: date.addingTimeInterval(2)))
        XCTAssertEqual(reopened.interview?.constraintChat?.messages.count, 2)
        XCTAssertNil(reopened.interview?.constraintChat?.painFree)
        XCTAssertNil(reopened.interview?.profile.constraintReview)
    }
}
