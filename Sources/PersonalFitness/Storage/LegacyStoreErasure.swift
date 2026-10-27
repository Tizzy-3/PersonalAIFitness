import Foundation
import SwiftData
import CoreData

/// Explicit user-triggered physical erasure. Never called during automatic startup recovery.
@MainActor
enum LegacyStoreErasure {
    struct Location: Sendable {
        let legacyURL: URL
        let dedicatedURL: URL
        let applicationSupport: URL
    }
    struct Identity: Equatable, Sendable {
        let inode: UInt64
        let device: UInt64
        let bytes: Int64
        let modified: Date
    }
    struct FileEntry: Identifiable, Equatable, Sendable {
        var id: String { url.path }
        let url: URL
        let identity: Identity
        let isRecoveryCopy: Bool
    }
    struct Review: Identifiable, Sendable {
        let id = UUID()
        let location: Location
        let files: [FileEntry]
        let entities: [String]
        var totalBytes: Int64 { files.reduce(0) { $0 + $1.identity.bytes } }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func defaultLocation() throws -> Location {
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let legacy = ModelConfiguration(schema: schema, cloudKitDatabase: .none).url
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return Location(legacyURL: legacy, dedicatedURL: support.appendingPathComponent("PersonalFitness/Training.store"), applicationSupport: support)
    }

    static func prepare(location: Location) throws -> Review {
        try checkLocation(location)
        let base = location.legacyURL.resolvingSymlinksInPath().standardizedFileURL
        var entities: [String] = []
        if FileManager.default.fileExists(atPath: base.path),
           let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: base,
                options: [NSReadOnlyPersistentStoreOption: true]) {
            entities = (metadata[NSStoreModelVersionHashesKey] as? [String: Data] ?? [:]).keys.sorted()
        }
        let files = try entries(location)
        guard !files.isEmpty else { throw Failure(message: "原数据库及其配套文件已不存在，无需重复删除。") }
        return Review(location: location, files: files, entities: entities)
    }

    static func execute(_ review: Review, confirmed: Bool, liveContainer: ModelContainer? = nil, liveURL: URL? = nil) throws {
        guard confirmed else { throw Failure(message: "未确认永久删除，文件未清理。") }
        try checkLocation(review.location)
        let current = try entries(review.location)
        guard current == review.files else { throw Failure(message: "原库文件已变化，请刷新清单后重新确认。尚未开始删除。") }
        let base = review.location.legacyURL.resolvingSymlinksInPath().standardizedFileURL
        let active = liveURL?.resolvingSymlinksInPath().standardizedFileURL
        if active == base {
            guard let liveContainer,
                  liveContainer.configurations.count == 1,
                  liveContainer.configurations.first?.url.resolvingSymlinksInPath().standardizedFileURL == base else {
                throw Failure(message: "原库仍在使用，必须由应用先停止该数据容器后再清理。")
            }
            // SwiftData coordinates its own live contexts before the physical cleanup below.
            try liveContainer.erase()
        }
        if FileManager.default.fileExists(atPath: base.path) {
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: NSManagedObjectModel())
            do { try coordinator.destroyPersistentStore(at: base, ofType: NSSQLiteStoreType, options: nil) }
            catch { throw Failure(message: "原库销毁未完成：\(error.localizedDescription)。未报告成功，请保留当前错误。") }
        }
        guard !FileManager.default.fileExists(atPath: base.path) else {
            throw Failure(message: "销毁后原库仍存在或已被重新创建，已停止进一步清理；请刷新清单。")
        }
        for file in review.files where FileManager.default.fileExists(atPath: file.url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            guard (attributes[.systemFileNumber] as? NSNumber)?.uint64Value == file.identity.inode,
                  (attributes[.systemNumber] as? NSNumber)?.uint64Value == file.identity.device else {
                throw Failure(message: "文件已被替换，未删除新文件：\(file.url.lastPathComponent)。")
            }
            do { try FileManager.default.removeItem(at: file.url) }
            catch { throw Failure(message: "仍有文件未能删除：\(file.url.lastPathComponent)。\(error.localizedDescription)") }
        }
        let remaining = try entries(review.location)
        guard remaining.isEmpty else { throw Failure(message: "清理后仍检测到原库文件，可能被其他组件重新创建；未报告删除成功。") }
    }

    private static func checkLocation(_ location: Location) throws {
        let legacy = location.legacyURL
        let canonical = legacy.resolvingSymlinksInPath().standardizedFileURL
        let dedicated = location.dedicatedURL.resolvingSymlinksInPath().standardizedFileURL
        guard legacy.lastPathComponent == "default.store", canonical != dedicated,
              canonical.deletingLastPathComponent() != dedicated.deletingLastPathComponent() else {
            throw Failure(message: "清理目标不是原默认数据库，或指向当前独立健身库；已拒绝删除。")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: legacy.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw Failure(message: "原库路径是符号链接，无法安全确认目标；已拒绝删除。")
        }
    }

    private static func entries(_ location: Location) throws -> [FileEntry] {
        let manager = FileManager.default
        let base = location.legacyURL.resolvingSymlinksInPath().standardizedFileURL
        var urls: [(URL, Bool)] = ["", "-wal", "-shm", "-journal"].map { (URL(fileURLWithPath: base.path + $0), false) }
        // These are internal pre-restore copies of the old default store, never manual exports.
        if base.deletingLastPathComponent() == location.applicationSupport.resolvingSymlinksInPath().standardizedFileURL {
            for folder in ["RestoreRecovery", "Recovery"] {
                let directory = base.deletingLastPathComponent().appendingPathComponent(folder)
                if manager.fileExists(atPath: directory.path) {
                    let attributes = try manager.attributesOfItem(atPath: directory.path)
                    guard attributes[.type] as? FileAttributeType == .typeDirectory,
                          directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else {
                        throw Failure(message: "原库恢复目录存在路径链接，已拒绝自动清理。")
                    }
                    let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    for url in children where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("before-restore-") {
                        let stem = String(url.deletingPathExtension().lastPathComponent.dropFirst("before-restore-".count))
                        if UUID(uuidString: stem) != nil { urls.append((url, true)) }
                    }
                }
            }
        }
        return try urls.compactMap { url, recovery -> FileEntry? in
            guard manager.fileExists(atPath: url.path) else { return nil }
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let bytes = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else {
                throw Failure(message: "文件身份无法安全确认：\(url.lastPathComponent)。")
            }
            return FileEntry(url: url, identity: Identity(inode: inode.uint64Value, device: device.uint64Value,
                bytes: bytes.int64Value, modified: modified), isRecoveryCopy: recovery)
        }.sorted { $0.url.path < $1.url.path }
    }
}
