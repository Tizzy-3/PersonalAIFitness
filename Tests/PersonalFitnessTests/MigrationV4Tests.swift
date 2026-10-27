import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

final class MigrationV4Tests: XCTestCase {
    @MainActor
    func testVersionThreeMigratesNonemptyHistoryAndDeletionThenReopens() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("v3.store")
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var profile = PersonalProfile()
        profile.goal = "真实升级保留档案"
        let plan = PlanVersion(name: "V3保留计划", items: [PlannedExercise(exercise: exercise)], confirmedAt: date)
        var session = try WorkoutSession.start(plan: plan, at: date.addingTimeInterval(10))
        try session.finish(early: true, at: date.addingTimeInterval(60))
        do {
            let schema = Schema(versionedSchema: FitnessSchemaV3.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let root = FitnessSchemaV3.MetadataRecord(profileData: try RecordCodec.encode(profile),
                customExercisesData: try RecordCodec.encode([Exercise]()))
            root.favoriteIDsData = try RecordCodec.encode([exercise.id])
            root.deletedPlanIDsData = try RecordCodec.encode([plan.planID])
            context.insert(root)
            context.insert(FitnessSchemaV3.PlanVersionRecord(id: plan.id, planID: plan.planID, version: plan.version,
                confirmedAt: plan.confirmedAt, payload: try RecordCodec.encode(plan)))
            context.insert(FitnessSchemaV3.SessionRecord(id: session.id, startedAt: session.startedAt,
                status: session.status.rawValue, revision: session.revision, payload: try RecordCodec.encode(session)))
            try context.save()
        }
        for _ in 0..<2 {
            let store = try TrainingStore(storageURL: url)
            XCTAssertEqual(store.profile, profile)
            XCTAssertEqual(store.planVersions, [plan])
            XCTAssertEqual(store.sessions, [session])
            XCTAssertEqual(store.deletedPlanIDs, [plan.planID])
            XCTAssertEqual(store.favoriteExerciseIDs, [exercise.id])
            XCTAssertNil(store.interview)
            XCTAssertTrue(store.preWorkoutCheckIns.isEmpty)
            XCTAssertNil(store.healthSnapshot)
            try store.snapshot().validate()
        }
    }
}
