import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

private enum LegacyCacheFixture: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [CachedMessage.self, CachedSession.self] }
    @Model final class CachedMessage {
        var text: String
        init(text: String) { self.text = text }
    }
    @Model final class CachedSession {
        var name: String
        init(name: String) { self.name = name }
    }
}

final class LegacyStoreErasureTests: XCTestCase {
    @MainActor
    func testPhysicalErasurePreservesDedicatedPlansAndRemovesInternalLegacyRecoveryCopies() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        try writeLegacy(location)
        let dedicated = try TrainingStore(storageURL: location.dedicatedURL)
        let plan = try dedicated.confirmPlan(name: "保留新库计划", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])])
        let recovery = location.applicationSupport.appendingPathComponent("RestoreRecovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let automatic = recovery.appendingPathComponent("before-restore-\(UUID().uuidString).json")
        try Data("legacy-internal-recovery".utf8).write(to: automatic)
        let manual = location.applicationSupport.appendingPathComponent("manual-export.pafbackup")
        try Data("manual-backup-outside-scope".utf8).write(to: manual)
        let review = try LegacyStoreErasure.prepare(location: location)
        XCTAssertEqual(review.entities, ["CachedMessage", "CachedSession"])
        try LegacyStoreErasure.execute(review, confirmed: true)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: location.legacyURL.path + suffix))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: automatic.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
        XCTAssertEqual(try TrainingStore(storageURL: location.dedicatedURL).planVersions.first?.id, plan.id)
    }

    @MainActor
    func testWithoutConfirmationNothingIsDeleted() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        try writeLegacy(location)
        let review = try LegacyStoreErasure.prepare(location: location)
        XCTAssertThrowsError(try LegacyStoreErasure.execute(review, confirmed: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.legacyURL.path))
    }

    @MainActor
    func testChangedFileInvalidatesReviewedDeletion() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        try writeLegacy(location)
        let review = try LegacyStoreErasure.prepare(location: location)
        try Data("changed-sidecar".utf8).write(to: URL(fileURLWithPath: location.legacyURL.path + "-journal"))
        XCTAssertThrowsError(try LegacyStoreErasure.execute(review, confirmed: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.legacyURL.path))
    }

    @MainActor
    func testDedicatedStoreAndSymlinkCannotBeSelectedAsLegacy() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        let store = try TrainingStore(storageURL: location.dedicatedURL)
        XCTAssertTrue(store.sessions.isEmpty)
        try FileManager.default.createSymbolicLink(at: location.legacyURL, withDestinationURL: location.dedicatedURL)
        XCTAssertThrowsError(try LegacyStoreErasure.prepare(location: location))
        let unsafe = LegacyStoreErasure.Location(legacyURL: location.dedicatedURL, dedicatedURL: location.dedicatedURL, applicationSupport: location.applicationSupport)
        XCTAssertThrowsError(try LegacyStoreErasure.prepare(location: unsafe))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.dedicatedURL.path))
    }

    @MainActor
    func testActiveLegacyContainerIsCoordinatedBeforePhysicalRemoval() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        try autoreleasepool {
            let live = try TrainingStore(storageURL: location.legacyURL)
            let review = try LegacyStoreErasure.prepare(location: location)
            XCTAssertThrowsError(try LegacyStoreErasure.execute(review, confirmed: true, liveContainer: live.container, liveURL: location.legacyURL))
            try LegacyStoreErasure.scheduleForNextLaunch(review)
            live.retireForErasure()
            XCTAssertTrue(FileManager.default.fileExists(atPath: location.legacyURL.path))
        }
        XCTAssertTrue(try LegacyStoreErasure.processPending(location: location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.legacyURL.path))
        XCTAssertTrue(try TrainingStore(storageURL: location.dedicatedURL).sessions.isEmpty)
    }

    @MainActor
    func testRetiredStoreCannotRecreateDataFromDelayedWrites() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        try autoreleasepool {
            let live = try TrainingStore(storageURL: location.legacyURL)
            let originalSnapshot = try live.snapshot()
            let review = try LegacyStoreErasure.prepare(location: location)
            try LegacyStoreErasure.scheduleForNextLaunch(review)
            live.retireForErasure()
            XCTAssertThrowsError(try live.confirmPlan(name: "过期网络回调不能保存", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])]))
            XCTAssertThrowsError(try live.restore(originalSnapshot))
        }
        XCTAssertTrue(try LegacyStoreErasure.processPending(location: location))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.legacyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.applicationSupport.appendingPathComponent("Recovery").path))
    }

    @MainActor
    func testHardLinkToDedicatedStoreCannotBeErased() throws {
        let location = try fixture()
        defer { try? FileManager.default.removeItem(at: location.applicationSupport) }
        let dedicated = try TrainingStore(storageURL: location.dedicatedURL)
        XCTAssertTrue(dedicated.sessions.isEmpty)
        try FileManager.default.linkItem(at: location.dedicatedURL, to: location.legacyURL)
        XCTAssertThrowsError(try LegacyStoreErasure.prepare(location: location))
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.dedicatedURL.path))
    }

    @MainActor
    private func writeLegacy(_ location: LegacyStoreErasure.Location) throws {
      try autoreleasepool {
        let schema = Schema(versionedSchema: LegacyCacheFixture.self)
        let config = ModelConfiguration(schema: schema, url: location.legacyURL, cloudKitDatabase: .none)
        let legacy = try ModelContainer(for: schema, configurations: [config])
        legacy.mainContext.insert(LegacyCacheFixture.CachedMessage(text: "explicitly-disposable-cache-message"))
        legacy.mainContext.insert(LegacyCacheFixture.CachedSession(name: "explicitly-disposable-cache-session"))
        try legacy.mainContext.save()
      }
    }

    private func fixture() throws -> LegacyStoreErasure.Location {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LegacyErasure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LegacyStoreErasure.Location(legacyURL: root.appendingPathComponent("default.store"),
            dedicatedURL: root.appendingPathComponent("PersonalFitness/Training.store"), applicationSupport: root)
    }
}
