import Foundation
import SwiftData
import CoreData

/// Discover metadata before opening a container. Never move, delete, replace, or merge stores.
@MainActor
enum StoreLocator {
    struct CandidateInfo: Codable, Sendable {
        var location: String
        var entities: [String]
        var metadataError: StartupDiagnostics.ErrorInfo?
    }
    struct Candidate: Sendable {
        var url: URL
        var info: CandidateInfo
        var isFitness: Bool { Set(info.entities) == ["MetadataRecord", "PlanVersionRecord", "SessionRecord"] }
    }
    struct Scan: Sendable {
        var legacyURL: URL
        var dedicatedURL: URL
        var candidates: [Candidate]
        var truncated: Bool
        var scanErrors: [StartupDiagnostics.ErrorInfo]
        var fitnessCandidates: [Candidate] { candidates.filter(\.isFitness) }
        var canStartSeparate: Bool {
            !truncated && scanErrors.isEmpty && fitnessCandidates.isEmpty
                && !candidates.contains { $0.url == dedicatedURL }
        }
        var diagnosticURL: URL {
            candidates.first { $0.url == legacyURL }?.url
                ?? candidates.first { $0.url == dedicatedURL }?.url ?? candidates.first?.url ?? legacyURL
        }
    }

    static func scanDefault() throws -> Scan {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let legacy = ModelConfiguration(schema: schema, cloudKitDatabase: .none).url
        var roots: [(String, URL)] = [("ApplicationSupport", support)]
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first { roots.append(("Documents", documents)) }
        if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first { roots.append(("Caches", caches)) }
        if !roots.contains(where: { legacy.path.hasPrefix($0.1.path + "/") }) {
            roots.append(("LegacyDefaultDirectory", legacy.deletingLastPathComponent()))
        }
        return scan(roots: roots, legacyURL: legacy, dedicatedURL: support.appendingPathComponent("PersonalFitness/Training.store"))
    }

    static func scan(roots: [(String, URL)], legacyURL: URL, dedicatedURL: URL, maxEntries: Int = 4_000) -> Scan {
        // /var and /private/var can name the same iOS container. Never count aliases as two stores.
        let legacyURL = legacyURL.resolvingSymlinksInPath().standardizedFileURL
        let dedicatedURL = dedicatedURL.resolvingSymlinksInPath().standardizedFileURL
        let roots = roots.map { ($0.0, $0.1.resolvingSymlinksInPath().standardizedFileURL) }
        let manager = FileManager.default
        var urls: [String: (URL, String)] = [:]
        var truncated = maxEntries <= 0
        let failures = StoreScanFailures()
        for (url, label) in [(legacyURL, "LegacyDefault/default.store"), (dedicatedURL, "PersonalFitness/Training.store")] {
            if manager.fileExists(atPath: url.path) { urls[url.standardizedFileURL.path] = (url, label) }
        }
        var visited = 0
        for (name, root) in roots {
            guard manager.fileExists(atPath: root.path) else { continue }
            guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                    failures.append(error); return true
                }) else { truncated = true; continue }
            while let url = enumerator.nextObject() as? URL {
                guard visited < maxEntries else { truncated = true; break }
                visited += 1
                // Deliberately scoped to four levels, not an unrestricted device-wide search.
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard values.isRegularFile == true, ["store", "sqlite", "db"].contains(url.pathExtension.lowercased()) else { continue }
                    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                    let key = resolved.path
                    if urls[key] == nil {
                        guard urls.count < 64 else { truncated = true; break }
                        let relative = String(url.path.dropFirst(root.path.count + 1))
                        urls[key] = (resolved, name + "/" + relative)
                    }
                } catch { failures.append(error) }
            }
        }
        let candidates = urls.values.sorted { $0.1 < $1.1 }.map { url, label in
            do {
                let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                    ofType: NSSQLiteStoreType, at: url, options: [NSReadOnlyPersistentStoreOption: true])
                let entities = (metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]).keys.sorted()
                return Candidate(url: url, info: CandidateInfo(location: label, entities: entities))
            } catch {
                return Candidate(url: url, info: CandidateInfo(location: label, entities: [], metadataError: StartupDiagnostics.errorInfo(error)))
            }
        }
        return Scan(legacyURL: legacyURL, dedicatedURL: dedicatedURL, candidates: candidates, truncated: truncated, scanErrors: failures.values)
    }

    static func select(_ scan: Scan, explicitlyStartSeparate: Bool = false) throws -> URL {
        guard !scan.truncated, scan.scanErrors.isEmpty else { throw StorageSelectionRequired(scan: scan) }
        let fitness = scan.fitnessCandidates
        if explicitlyStartSeparate {
            guard scan.canStartSeparate else { throw StorageSelectionRequired(scan: scan) }
            return scan.dedicatedURL
        }
        if fitness.count == 1 { return fitness[0].url }
        if fitness.isEmpty, scan.candidates.isEmpty { return scan.dedicatedURL }
        throw StorageSelectionRequired(scan: scan)
    }
}

private final class StoreScanFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [StartupDiagnostics.ErrorInfo] = []
    func append(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        if errors.count < 8 { errors.append(StartupDiagnostics.errorInfo(error)) }
    }
    var values: [StartupDiagnostics.ErrorInfo] {
        lock.lock()
        defer { lock.unlock() }
        return errors
    }
}

struct StorageSelectionRequired: LocalizedError {
    let scan: StoreLocator.Scan
    var errorDescription: String? {
        if scan.truncated || !scan.scanErrors.isEmpty { return "本地数据查找未完整完成，已停止打开。请导出诊断，原文件全部保留。" }
        if scan.fitnessCandidates.count > 1 { return "发现多个健身数据库，暂未选择或合并。请导出诊断确认原计划所在位置。" }
        return "原默认位置中的数据库不符合健身数据模型，原计划尚未恢复。所有原文件均已保留，请先导出诊断。"
    }
}

struct StoreOpenFailure: LocalizedError {
    let url: URL
    let original: any Error
    var errorDescription: String? { original.localizedDescription }
}
