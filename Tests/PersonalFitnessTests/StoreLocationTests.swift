import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

private enum CacheFixture: VersionedSchema {
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

final class StoreLocationTests: XCTestCase {
    @MainActor
    func testForeignDefaultReproducesFailureAndRequiresExplicitSeparateStoreChoice() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        try writeCache(to: legacy)
        XCTAssertThrowsError(try TrainingStore(storageURL: legacy)) { error in
            XCTAssertEqual((error as NSError).domain, "SwiftData.SwiftDataError")
        }
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertEqual(scan.candidates.first?.info.entities, ["CachedMessage", "CachedSession"])
        XCTAssertThrowsError(try StoreLocator.select(scan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicated.path))
        let selection = try StoreLocator.select(scan, explicitlyStartSeparate: true)
        XCTAssertEqual(selection, dedicated)
        let store = try TrainingStore(storageURL: selection)
        XCTAssertTrue(store.sessions.isEmpty)
        _ = try store.confirmPlan(name: "独立健身库", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])])
        try assertCacheUnchanged(at: legacy)
        let rescanned = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertEqual(try StoreLocator.select(rescanned), dedicated)
        XCTAssertEqual(try TrainingStore(storageURL: dedicated).planVersions.count, 1)
    }

    @MainActor
    func testFindsExistingFitnessHistoryInsteadOfStartingEmptyWhenDefaultIsForeign() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let previous = root.appendingPathComponent("Previous/actual-fitness.sqlite")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        try writeCache(to: legacy)
        try FileManager.default.createDirectory(at: previous.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ids = try writeFitnessHistory(to: previous)
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertEqual(try StoreLocator.select(scan), previous)
        let reopened = try TrainingStore(storageURL: StoreLocator.select(scan))
        XCTAssertEqual(reopened.planVersions.first?.id, ids.0)
        XCTAssertEqual(reopened.sessions.first?.id, ids.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicated.path))
        try assertCacheUnchanged(at: legacy)
    }

    @MainActor
    func testKnownLegacyStoreIsRetainedAndNeverBypassed() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        let ids = try writeFitnessHistory(to: legacy)
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertEqual(try StoreLocator.select(scan), legacy)
        XCTAssertThrowsError(try StoreLocator.select(scan, explicitlyStartSeparate: true))
        XCTAssertEqual(try TrainingStore(storageURL: legacy).sessions.first?.id, ids.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicated.path))
    }

    @MainActor
    func testTwoFitnessStoresBlockAmbiguousSelection() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        _ = try writeFitnessHistory(to: legacy)
        try FileManager.default.createDirectory(at: dedicated.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try writeFitnessHistory(to: dedicated)
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertThrowsError(try StoreLocator.select(scan))
        XCTAssertFalse(scan.canStartSeparate)
    }

    @MainActor
    func testCorruptDedicatedFileIsNeverReplaced() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        try FileManager.default.createDirectory(at: dedicated.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("not-a-database".utf8)
        try bytes.write(to: dedicated)
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertThrowsError(try StoreLocator.select(scan))
        XCTAssertThrowsError(try StoreLocator.select(scan, explicitlyStartSeparate: true))
        XCTAssertEqual(try Data(contentsOf: dedicated), bytes)
    }

    @MainActor
    func testKnownFitnessPayloadFailureDoesNotCreateReplacementStore() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("default.store")
        let dedicated = root.appendingPathComponent("PersonalFitness/Training.store")
        let corrupt = Data("original-corrupt-profile".utf8)
        do {
            let schema = Schema(versionedSchema: FitnessSchemaV4.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: legacy, cloudKitDatabase: .none)])
            container.mainContext.insert(FitnessSchemaV4.MetadataRecord(profileData: corrupt, customExercisesData: Data("[]".utf8)))
            try container.mainContext.save()
        }
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertEqual(try StoreLocator.select(scan), legacy)
        XCTAssertThrowsError(try TrainingStore(storageURL: StoreLocator.select(scan)))
        XCTAssertThrowsError(try StoreLocator.select(scan, explicitlyStartSeparate: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicated.path))
    }

    @MainActor
    func testFreshInstallUsesDedicatedPathAndDoesNotCreateDefaultStore() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let caches = root.appendingPathComponent("Caches")
        let reference = caches.appendingPathComponent("StartupModelReferences/interrupted-run/V1.store")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reference.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let schema = Schema(versionedSchema: FitnessSchemaV1.self)
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: reference, cloudKitDatabase: .none)])
            try container.mainContext.save()
        }
        let legacy = support.appendingPathComponent("default.store")
        let dedicated = support.appendingPathComponent("PersonalFitness/Training.store")
        let scan = StoreLocator.scan(roots: [("support", support), ("Caches", caches)], legacyURL: legacy, dedicatedURL: dedicated)
        XCTAssertTrue(scan.fitnessCandidates.isEmpty, "Diagnostic references must never be mistaken for recovered history")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.path), "Discovery must not delete leftover references")
        XCTAssertEqual(try StoreLocator.select(scan), dedicated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dedicated.path), "Selection must not create files")
    }

    @MainActor
    func testTruncatedDiscoveryDoesNotSilentlyStartEmpty() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scan = StoreLocator.scan(roots: [("support", root)], legacyURL: root.appendingPathComponent("default.store"),
                                    dedicatedURL: root.appendingPathComponent("PersonalFitness/Training.store"), maxEntries: 0)
        XCTAssertTrue(scan.truncated)
        XCTAssertThrowsError(try StoreLocator.select(scan))
        XCTAssertFalse(scan.canStartSeparate)
    }

    @MainActor
    func testFilesystemAliasIsNotMistakenForAnotherFitnessDatabase() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let physical = root.appendingPathComponent("physical")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let legacy = physical.appendingPathComponent("default.store")
        _ = try writeFitnessHistory(to: legacy)
        let scan = StoreLocator.scan(roots: [("physical", physical), ("alias", alias)],
            legacyURL: alias.appendingPathComponent("default.store"), dedicatedURL: physical.appendingPathComponent("PersonalFitness/Training.store"))
        XCTAssertEqual(scan.fitnessCandidates.count, 1)
        XCTAssertEqual(try StoreLocator.select(scan), legacy.resolvingSymlinksInPath())
    }

    @MainActor
    private func writeCache(to url: URL) throws {
        let schema = Schema(versionedSchema: CacheFixture.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        container.mainContext.insert(CacheFixture.CachedMessage(text: "original-cache-message"))
        container.mainContext.insert(CacheFixture.CachedSession(name: "original-cache-session"))
        try container.mainContext.save()
    }

    @MainActor
    private func assertCacheUnchanged(at url: URL) throws {
        let schema = Schema(versionedSchema: CacheFixture.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CacheFixture.CachedMessage>()).map(\.text), ["original-cache-message"])
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CacheFixture.CachedSession>()).map(\.name), ["original-cache-session"])
    }

    @MainActor
    private func writeFitnessHistory(to url: URL) throws -> (UUID, UUID) {
        let store = try TrainingStore(storageURL: url)
        let plan = try store.confirmPlan(name: "原有计划", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])])
        let session = try store.startWorkout(plan: plan)
        return (plan.id, session.id)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StoreRouting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
