import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

final class MigrationV3Tests: XCTestCase {
    @MainActor
    func testVersionTwoDiskStoreMigratesThenPersistsPlanningAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FitnessV3Migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("version-two.store")
        let original = try writeVersionTwoStore(to: url)
        let expectedDraftID: UUID
        let originalPlan = try XCTUnwrap(original.planVersions.first)

        do {
            let migrated = try TrainingStore(storageURL: url)
            XCTAssertEqual(migrated.profile, original.profile)
            XCTAssertEqual(migrated.planVersions, original.planVersions)
            XCTAssertEqual(migrated.sessions, original.sessions)
            XCTAssertEqual(migrated.coachTurns, original.coachTurns ?? [])
            XCTAssertEqual(migrated.favoriteExerciseIDs, Set(original.favoriteExerciseIDs ?? []))
            XCTAssertEqual(migrated.activePlanVersionID, original.activePlanVersionID)
            XCTAssertTrue(migrated.planningDrafts.isEmpty)
            XCTAssertTrue(migrated.weeklyPrograms.isEmpty)
            XCTAssertTrue(migrated.deletedPlanIDs.isEmpty)
            XCTAssertTrue(migrated.deletedWeeklyProgramIDs.isEmpty)
            XCTAssertNil(migrated.activeWeeklyProgramID)

            let input = PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [1, 3, 5], minutesPerSession: 30,
                                      equipment: [.bodyweight, .walkingSpace, .dumbbells, .bench], adultConfirmed: true,
                                      safety: .noKnownRestrictions, painToday: false)
            let draft = try PlanningDraft.make(input: input, snapshot: migrated.snapshot())
            try migrated.savePlanningDraft(draft)
            expectedDraftID = draft.id
            try migrated.deletePlan(planID: originalPlan.planID)
        }

        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.profile, original.profile)
        XCTAssertEqual(reopened.planVersions, original.planVersions)
        XCTAssertEqual(reopened.sessions, original.sessions)
        XCTAssertEqual(reopened.coachTurns, original.coachTurns ?? [])
        XCTAssertEqual(reopened.favoriteExerciseIDs, Set(original.favoriteExerciseIDs ?? []))
        XCTAssertEqual(reopened.deletedPlanIDs, [originalPlan.planID])
        XCTAssertEqual(reopened.planningDrafts.map(\.id), [expectedDraftID])
        XCTAssertEqual(reopened.planningDrafts.first?.decision, .pending)
        XCTAssertNil(reopened.currentPlan)
        XCTAssertNil(reopened.currentWeeklyProgram)
        try reopened.snapshot().validate()
    }

    @MainActor
    private func writeVersionTwoStore(to url: URL) throws -> AppSnapshot {
        let schema = Schema(versionedSchema: FitnessSchemaV2.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var profile = PersonalProfile()
        profile.birthYear = 1988
        profile.heightCM = 175
        profile.goal = "保留原版资料与真实记录"
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let plan = PlanVersion(name: "V2手动计划", items: [PlannedExercise(exercise: exercise, setCount: 2, targetReps: 8)], confirmedAt: date)
        var session = try WorkoutSession.start(plan: plan, at: date.addingTimeInterval(10))
        let movementID = try XCTUnwrap(session.exercises.first?.id)
        let setID = try XCTUnwrap(session.exercises.first?.sets.first?.id)
        try session.completeSet(exerciseID: movementID, setID: setID, at: date.addingTimeInterval(30))
        try session.finish(early: true, at: date.addingTimeInterval(80))
        var snapshot = AppSnapshot(formatVersion: 2, exportedAt: date.addingTimeInterval(300), profile: profile,
                                   activePlanVersionID: plan.id, planVersions: [plan], sessions: [session],
                                   favoriteExerciseIDs: [exercise.id])
        // Protocol fixture: this test never calls a remote model or claims AI output quality.
        let evidence = try CoachContext.make(snapshot: snapshot, at: date.addingTimeInterval(100))
        let reply = CoachReply(answer: "本地存在一条已结束的训练记录，不能据此判断长期进步。", evidence: ["statistics"], limitations: ["没有健康数据。"])
        let turn = CoachTurn(question: "现有记录是什么？", context: evidence, reply: reply, at: date.addingTimeInterval(101))
        snapshot.coachTurns = [turn]
        try snapshot.validate()

        let metadata = FitnessSchemaV2.MetadataRecord(profileData: try RecordCodec.encode(profile),
            customExercisesData: try RecordCodec.encode([Exercise]()), activePlanVersionID: plan.id)
        metadata.coachData = try RecordCodec.encode([turn])
        metadata.favoriteIDsData = try RecordCodec.encode([exercise.id])
        context.insert(metadata)
        context.insert(FitnessSchemaV2.PlanVersionRecord(id: plan.id, planID: plan.planID, version: plan.version,
            confirmedAt: plan.confirmedAt, payload: try RecordCodec.encode(plan)))
        context.insert(FitnessSchemaV2.SessionRecord(id: session.id, startedAt: session.startedAt,
            status: session.status.rawValue, revision: session.revision, payload: try RecordCodec.encode(session)))
        try context.save()
        return snapshot
    }
}
