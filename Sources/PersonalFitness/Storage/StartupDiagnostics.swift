import Foundation
import SwiftData
import CoreData

/// Metadata only. Never fetches model rows, exports payload blobs, clears a store, or retries
/// opening an existing store against a different schema after an error.
@MainActor
enum StartupDiagnostics {
    static let reportName = "latest-startup-diagnostic.json"

    struct ErrorInfo: Codable, Sendable {
        var domain: String
        var code: Int
        var summary: String
        var underlying: [ErrorInfo]
    }
    struct StoreFile: Codable {
        var name: String
        var bytes: Int64?
        var readable: Bool
        var writable: Bool
    }
    struct Report: Codable {
        var formatVersion = 1
        var attemptID = UUID()
        var capturedAt = Date()
        var status: String
        var phase: String
        var appVersion: String
        var build: String
        var bundleID: String
        var osVersion: String
        var availableBytes: Int64?
        var storeFileName: String
        var files: [StoreFile]
        var modelIdentifiers: [String]
        var modelHashes: [String: String]
        var metadataReadError: ErrorInfo?
        var referenceHashes: [String: [String: String]]
        var referenceErrors: [String: ErrorInfo]
        var error: ErrorInfo?
        var storageCandidates: [StoreLocator.CandidateInfo]?
        var storageScanTruncated: Bool?
        var storageScanErrors: [ErrorInfo]?
    }

    nonisolated static func errorInfo(_ error: Error, depth: Int = 0) -> ErrorInfo {
        let value = error as NSError
        var nested: [ErrorInfo] = []
        if depth < 4 {
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError {
                nested.append(errorInfo(underlying, depth: depth + 1))
            }
            if let details = value.userInfo[NSDetailedErrorsKey] as? [NSError] {
                nested.append(contentsOf: details.prefix(8).map { errorInfo($0, depth: depth + 1) })
            }
        }
        // App/domain errors may contain user-entered names. Do not serialize arbitrary userInfo,
        // validation objects, SQL bindings, profile text, URLs containing credentials, or payloads.
        let summary: String
        // NSError descriptions can include a validation object's values. Only classify codes;
        // neither localizedDescription nor arbitrary userInfo is safe to export here.
        if value.domain.hasPrefix("SwiftData") { summary = "SwiftData 存储错误" }
        else if value.domain == NSCocoaErrorDomain { summary = "Cocoa 存储或文件错误" }
        else if value.domain == NSPOSIXErrorDomain { summary = "POSIX 文件错误" }
        else if value.domain == "NSSQLiteErrorDomain" { summary = "SQLite 存储错误" }
        else { summary = "其他错误；详细数据未加入诊断。" }
        return ErrorInfo(domain: value.domain, code: value.code, summary: summary, underlying: nested)
    }

    static func capture(error: Error?, phase: String, storeURL: URL, includeReferences: Bool = false) -> Report {
        let manager = FileManager.default
        let candidates = [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")]
        let files = candidates.compactMap { url -> StoreFile? in
            guard manager.fileExists(atPath: url.path) else { return nil }
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return StoreFile(name: url.lastPathComponent, bytes: (attributes?[.size] as? NSNumber)?.int64Value,
                             readable: manager.isReadableFile(atPath: url.path), writable: manager.isWritableFile(atPath: url.path))
        }
        var identifiers: [String] = []
        var hashes: [String: String] = [:]
        var metadataError: ErrorInfo?
        if manager.fileExists(atPath: storeURL.path) {
            do {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType, at: storeURL, options: [NSReadOnlyPersistentStoreOption: true])
                identifiers = (metadata[NSStoreModelVersionIdentifiersKey] as? [String] ?? []).sorted()
                hashes = hashStrings(metadata)
            } catch { metadataError = errorInfo(error) }
        }
        let capacity = try? storeURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        var report = Report(status: error == nil ? "opened" : "failed", phase: phase,
                            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                            bundleID: Bundle.main.bundleIdentifier ?? "unknown", osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                            availableBytes: capacity?.volumeAvailableCapacityForImportantUsage,
                            storeFileName: storeURL.lastPathComponent, files: files, modelIdentifiers: identifiers,
                            modelHashes: hashes, metadataReadError: metadataError, referenceHashes: [:], referenceErrors: [:],
                            error: error.map { errorInfo($0) })
        if includeReferences, (report.availableBytes ?? 0) > 5 * 1_024 * 1_024 {
            // Separate, disposable empty reference stores only after the original open failed.
            // They identify the model this binary compiled; they never replace the user's store.
            do {
                let base = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    .appendingPathComponent("StartupModelReferences", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try manager.createDirectory(at: base, withIntermediateDirectories: true)
                defer { try? manager.removeItem(at: base) }
                let versions: [(String, Schema)] = [
                    ("V1", Schema(versionedSchema: FitnessSchemaV1.self)), ("V2", Schema(versionedSchema: FitnessSchemaV2.self)),
                    ("V3", Schema(versionedSchema: FitnessSchemaV3.self)), ("V4", Schema(versionedSchema: FitnessSchemaV4.self))]
                for (name, schema) in versions {
                    let url = base.appendingPathComponent(name + ".store")
                    do {
                        try autoreleasepool {
                            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
                            let reference = try ModelContainer(for: schema, configurations: [config])
                            try reference.mainContext.save()
                        }
                        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                            ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true])
                        report.referenceHashes[name] = hashStrings(metadata)
                    } catch { report.referenceErrors[name] = errorInfo(error) }
                }
            } catch { report.referenceErrors["reference-directory"] = errorInfo(error) }
        }
        return report
    }

    private static func hashStrings(_ metadata: [String: Any]) -> [String: String] {
        let values = metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]
        return values.mapValues { $0.map { String(format: "%02x", $0) }.joined() }
    }

    static func text(_ report: Report) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(report)).map { String(decoding: $0, as: UTF8.self) } ?? "诊断编码失败。"
    }

    @discardableResult
    static func save(_ report: Report) throws -> URL {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StartupDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(reportName)
        try Data(text(report).utf8).write(to: url, options: .atomic)
        return url
    }

    static var latestURL: URL? {
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = cache.appendingPathComponent("StartupDiagnostics").appendingPathComponent(reportName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
