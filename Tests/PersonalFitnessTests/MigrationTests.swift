import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

final class MigrationTests: XCTestCase {
    @MainActor
    func testVersionOneDiskStoreMigratesWithoutLosingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FitnessMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let original = try writeVersionOneStore(to: url)

        do {
            let migrated = try TrainingStore(storageURL: url)
            XCTAssertEqual(migrated.profile, original.profile)
            XCTAssertEqual(migrated.planVersions, original.planVersions)
            XCTAssertEqual(migrated.sessions, original.sessions)
            XCTAssertEqual(migrated.activePlanVersionID, original.activePlanVersionID)
            XCTAssertTrue(migrated.coachTurns.isEmpty)
            XCTAssertTrue(migrated.favoriteExerciseIDs.isEmpty)
            let exerciseID = try XCTUnwrap(original.planVersions.first?.items.first?.exercise.id)
            try migrated.toggleFavorite(exerciseID: exerciseID)
        }

        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.sessions, original.sessions)
        XCTAssertEqual(reopened.favoriteExerciseIDs, Set(original.planVersions.flatMap(\.items).map { $0.exercise.id }))
    }

    @MainActor
    func testCorruptLegacyProfileIsNotReplacedByAnEmptyProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FitnessCorruptMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.store")
        let corrupt = Data("not a valid profile".utf8)
        do {
            let schema = Schema(versionedSchema: FitnessSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.autosaveEnabled = false
            context.insert(FitnessSchemaV1.MetadataRecord(profileData: corrupt, customExercisesData: try RecordCodec.encode([Exercise]())))
            try context.save()
        }

        XCTAssertThrowsError(try TrainingStore(storageURL: url))
        let schema = Schema(versionedSchema: FitnessSchemaV3.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: FitnessMigrationPlan.self, configurations: [configuration])
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<FitnessSchemaV3.MetadataRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.profileData, corrupt)
    }

    @MainActor
    private func writeVersionOneStore(to url: URL) throws -> AppSnapshot {
        let schema = Schema(versionedSchema: FitnessSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var profile = PersonalProfile()
        profile.heightCM = 175
        profile.goal = "保存旧版本的实际资料"
        let exercise = try XCTUnwrap(ExerciseCatalog.exercises.first)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let plan = PlanVersion(name: "旧版手动计划", items: [PlannedExercise(exercise: exercise)], confirmedAt: date)
        var session = try WorkoutSession.start(plan: plan, at: date.addingTimeInterval(10))
        try session.finish(early: true, at: date.addingTimeInterval(130))
        let snapshot = AppSnapshot(formatVersion: 1, profile: profile, activePlanVersionID: plan.id, planVersions: [plan], sessions: [session])
        try snapshot.validate()
        context.insert(FitnessSchemaV1.MetadataRecord(profileData: try RecordCodec.encode(profile), customExercisesData: try RecordCodec.encode([Exercise]()), activePlanVersionID: plan.id))
        context.insert(FitnessSchemaV1.PlanVersionRecord(id: plan.id, planID: plan.planID, version: plan.version, confirmedAt: plan.confirmedAt, payload: try RecordCodec.encode(plan)))
        context.insert(FitnessSchemaV1.SessionRecord(id: session.id, startedAt: session.startedAt, status: session.status.rawValue, revision: session.revision, payload: try RecordCodec.encode(session)))
        try context.save()
        return snapshot
    }
}
