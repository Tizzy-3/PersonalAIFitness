import Foundation
import XCTest
@testable import FitnessCore

final class CoachCoreTests: XCTestCase {
    private func fixture() throws -> (AppSnapshot, CoachContext, CoachProposal) {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let plan = PlanVersion(name: "已确认计划", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])],
                               confirmedAt: now.addingTimeInterval(-60))
        let snapshot = AppSnapshot(activePlanVersionID: plan.id, planVersions: [plan])
        let context = try CoachContext.make(snapshot: snapshot, at: now)
        let proposal = CoachProposal(reason: "减少一组并观察后续记录", targetPlanVersionID: plan.id,
                                     items: [CoachProposedItem(exerciseID: plan.items[0].exercise.id, setCount: 2,
                                                               targetReps: 10, targetSeconds: nil, restSeconds: 90)])
        return (snapshot, context, proposal)
    }

    func testContextUsesSavedQuantitiesAndRedactsInjuryAndWorkoutNotes() throws {
        var snapshot = AppSnapshot()
        snapshot.profile.restrictions = "secret injury detail"
        var session = WorkoutSession(name: "真实训练", startedAt: Date().addingTimeInterval(-120),
                                     exercises: [WorkoutExercise(exercise: ExerciseCatalog.exercises[0], note: "secret note")])
        try session.finish(early: true, at: Date().addingTimeInterval(-60))
        snapshot.sessions = [session]
        let context = try CoachContext.make(snapshot: snapshot)
        XCTAssertEqual(context.statistics.completedSessions, 1)
        XCTAssertEqual(context.statistics.completedSets, 0)
        XCTAssertEqual(context.statistics.totalTrainingSeconds, 60, accuracy: 0.1)
        let json = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(json.contains("secret injury")); XCTAssertFalse(json.contains("secret note"))
        XCTAssertFalse(context.profile.restrictions.isEmpty)
    }

    func testContextCapsHistoryAndPreservesUnknownMetrics() throws {
        var snapshot = AppSnapshot()
        snapshot.sessions = try (0..<20).map {
            var session = WorkoutSession(name: "训练", startedAt: Date().addingTimeInterval(Double(-$0 * 60 - 120)))
            try session.finish(early: true, at: session.startedAt.addingTimeInterval(60))
            return session
        }
        let context = try CoachContext.make(snapshot: snapshot)
        XCTAssertEqual(context.recentSessions.count, 10)
        XCTAssertNil(context.profile.weightKG)
        XCTAssertEqual(context.statistics.completedSessions, 20)
    }

    func testMovementQuestionRetrievesOnlyRealCatalogKnowledge() throws {
        let context = try CoachContext.make(snapshot: AppSnapshot()).withMovementKnowledge(for: "哑铃卧推怎样做？")
        let item = try XCTUnwrap(context.movementKnowledge?.first)
        XCTAssertEqual(item.exercise.id, "builtin.dumbbell-bench-press")
        XCTAssertTrue(context.evidenceIDs.contains("exercise:builtin.dumbbell-bench-press"))
        XCTAssertFalse(item.commonMistakes.isEmpty)
        XCTAssertNoThrow(try context.validate())
        let reply = CoachReply(answer: "根据本地动作提示进行说明", evidence: ["exercise:builtin.dumbbell-bench-press"], limitations: ["不是个体动作评估"])
        XCTAssertNoThrow(try reply.validate(context: context))
    }

    func testConservativeProposalPreservesExerciseAndItemIdentities() throws {
        let (_, context, proposal) = try fixture()
        let result = try proposal.validatedItems(context: context)
        XCTAssertEqual(result[0].setCount, 2)
        XCTAssertEqual(result[0].id, context.plan?.items[0].id)
        XCTAssertEqual(result[0].exercise, context.plan?.items[0].exercise)
        XCTAssertEqual(context.plan?.items[0].setCount, 3)
    }

    func testUnknownExerciseIncreasedDoseOrShortenedRestAreRejected() throws {
        let (_, context, proposal) = try fixture()
        var invalid = proposal
        invalid.items[0].exerciseID = "invented"
        XCTAssertThrowsError(try invalid.validatedItems(context: context))
        invalid = proposal; invalid.items[0].setCount = 4
        XCTAssertThrowsError(try invalid.validatedItems(context: context))
        invalid = proposal; invalid.items[0].targetReps = 11
        XCTAssertThrowsError(try invalid.validatedItems(context: context))
        invalid = proposal; invalid.items[0].restSeconds = 60
        XCTAssertThrowsError(try invalid.validatedItems(context: context))
        invalid = proposal; invalid.items[0].restSeconds = .infinity
        XCTAssertThrowsError(try invalid.validatedItems(context: context))
    }

    func testRestrictionsBlockAnyProposalAndUnknownTargetsStayUnknown() throws {
        var (snapshot, _, proposal) = try fixture()
        snapshot.profile.restrictions = "人工限制"
        XCTAssertThrowsError(try proposal.validatedItems(context: CoachContext.make(snapshot: snapshot)))
        snapshot.profile.restrictions = ""
        snapshot.planVersions[0].items[0].targetReps = nil
        XCTAssertThrowsError(try proposal.validatedItems(context: CoachContext.make(snapshot: snapshot)))
    }

    func testFakeEvidenceAndNoChangeProposalAreRejected() throws {
        let (_, context, proposal) = try fixture()
        var reply = CoachReply(answer: "说明", evidence: ["invented-sleep-score"], limitations: [])
        XCTAssertThrowsError(try reply.validate(context: context))
        reply = CoachReply(answer: "说明", evidence: [], limitations: [], proposal: proposal)
        XCTAssertThrowsError(try reply.validate(context: context))
        var noChange = proposal; noChange.items[0].setCount = 3
        XCTAssertThrowsError(try noChange.validatedItems(context: context))
    }

    func testStrictJSONRejectsUnknownFieldsAndWrongTypes() throws {
        let (_, context, _) = try fixture()
        let good = #"{"answer":"说明","evidence":["statistics"],"limitations":["无健康数据"],"proposal":null}"#
        XCTAssertEqual(try CoachReply.decode(data: Data(good.utf8), context: context).answer, "说明")
        let extra = good.replacingOccurrences(of: #""proposal":null"#, with: #""proposal":null,"directWrite":true"#)
        XCTAssertThrowsError(try CoachReply.decode(data: Data(extra.utf8), context: context))
        let bad = good.replacingOccurrences(of: #""answer":"说明""#, with: #""answer":7"#)
        XCTAssertThrowsError(try CoachReply.decode(data: Data(bad.utf8), context: context))
    }

    func testContextInvalidatesAfterProfilePlanOrRecordedTrainingChanges() throws {
        var (snapshot, context, _) = try fixture()
        XCTAssertTrue(context.matches(snapshot: snapshot))
        snapshot.profile.goal = "变更的目标"
        XCTAssertFalse(context.matches(snapshot: snapshot))
        snapshot.profile = context.profile
        snapshot.sessions.append(WorkoutSession(name: "刚开始的训练"))
        XCTAssertFalse(context.matches(snapshot: snapshot))
    }

    func testOldContextExpiresWithoutPretendingFreshEvidence() throws {
        let (snapshot, _, _) = try fixture()
        let context = try CoachContext.make(snapshot: snapshot, at: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertFalse(context.matches(snapshot: snapshot))
    }

    func testLegacyBackupDecodesWithoutNewFieldsAndModernBackupKeepsCoachAndFavorites() throws {
        let (snapshot, context, _) = try fixture()
        var old = snapshot; old.formatVersion = 1
        let decodedLegacy = try SnapshotCodec.decode(SnapshotCodec.encode(old))
        XCTAssertEqual(decodedLegacy.planVersions, old.planVersions)
        XCTAssertNil(decodedLegacy.coachTurns)
        var modern = snapshot
        modern.favoriteExerciseIDs = [ExerciseCatalog.exercises[0].id]
        modern.coachTurns = [CoachTurn(question: "解释当前计划", context: context,
                                      reply: CoachReply(answer: "基于当前计划的解释", evidence: ["plan"], limitations: ["未发送健康数据"]))]
        let decoded = try SnapshotCodec.decode(SnapshotCodec.encode(modern))
        XCTAssertEqual(decoded.coachTurns?.first?.question, modern.coachTurns?.first?.question)
        XCTAssertEqual(decoded.favoriteExerciseIDs, modern.favoriteExerciseIDs)
        XCTAssertEqual(decoded.coachTurns?.first?.context.profile, modern.profile)
    }

    func testSnapshotRejectsUnknownFavoriteAndAcceptedTurnWithoutPlan() throws {
        var (snapshot, context, proposal) = try fixture()
        snapshot.favoriteExerciseIDs = ["does-not-exist"]
        XCTAssertThrowsError(try snapshot.validate())
        snapshot.favoriteExerciseIDs = nil
        var turn = CoachTurn(question: "减量", context: context,
                             reply: CoachReply(answer: "减量建议", evidence: ["plan"], limitations: [], proposal: proposal))
        turn.decision = .accepted; turn.appliedPlanVersionID = UUID()
        snapshot.coachTurns = [turn]
        XCTAssertThrowsError(try snapshot.validate())
    }
}
