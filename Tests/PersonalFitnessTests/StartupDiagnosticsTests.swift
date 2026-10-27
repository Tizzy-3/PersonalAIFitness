import XCTest
import SwiftData
import FitnessCore
@testable import PersonalFitness

final class StartupDiagnosticsTests: XCTestCase {
    @MainActor
    func testErrorChainNeverExportsDescriptionsOrUserInfo() throws {
        let secret = "private-profile-pain-and-api-key"
        let child = NSError(domain: "NSSQLiteErrorDomain", code: 11,
                            userInfo: [NSLocalizedDescriptionKey: secret, "SQL": secret])
        let error = NSError(domain: NSCocoaErrorDomain, code: 134504,
                            userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: child,
                                       "NSDebugDescription": secret])
        let result = StartupDiagnostics.errorInfo(error)
        XCTAssertEqual(result.code, 134504)
        XCTAssertEqual(result.underlying.first?.code, 11)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
    }

    @MainActor
    func testMissingStoreDiagnosticsDoNotCreateDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing.store")
        let report = StartupDiagnostics.capture(error: NSError(domain: NSCocoaErrorDomain, code: 4),
                                                phase: "test-missing", storeURL: url)
        XCTAssertTrue(report.files.isEmpty)
        XCTAssertTrue(report.modelHashes.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testMetadataDiagnosticsLeaveRecordPayloadIntactAndDoNotExportIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("private.store")
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let secret = Data("private-profile-content-not-for-diagnostics".utf8)
        context.insert(FitnessSchemaV4.MetadataRecord(profileData: secret, customExercisesData: secret))
        try context.save()
        let report = StartupDiagnostics.capture(error: NSError(domain: "SwiftData.SwiftDataError", code: 1),
                                                phase: "test-metadata", storeURL: url, includeReferences: true)
        XCTAssertFalse(report.modelHashes.isEmpty)
        XCTAssertEqual(report.referenceHashes.count, 4, "\(report.referenceErrors)")
        let text = StartupDiagnostics.text(report)
        XCTAssertFalse(text.contains(String(decoding: secret, as: UTF8.self)))
        XCTAssertFalse(text.contains(secret.base64EncodedString()))
        XCTAssertFalse(text.contains(NSHomeDirectory()))
        let records = try context.fetch(FetchDescriptor<FitnessSchemaV4.MetadataRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.profileData, secret)
    }
}
