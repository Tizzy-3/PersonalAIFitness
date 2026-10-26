import Foundation
import SwiftData

enum FitnessSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [MetadataRecord.self, PlanVersionRecord.self, SessionRecord.self]
    }

    @Model
    final class MetadataRecord {
        @Attribute(.unique) var id: String
        var profileData: Data
        var customExercisesData: Data
        var activePlanVersionID: UUID?
        var revision: Int

        init(profileData: Data, customExercisesData: Data, activePlanVersionID: UUID? = nil) {
            id = "personal-fitness"
            self.profileData = profileData
            self.customExercisesData = customExercisesData
            self.activePlanVersionID = activePlanVersionID
            revision = 1
        }
    }

    @Model
    final class PlanVersionRecord {
        @Attribute(.unique) var id: UUID
        var planID: UUID
        var version: Int
        var confirmedAt: Date
        var payload: Data

        init(id: UUID, planID: UUID, version: Int, confirmedAt: Date, payload: Data) {
            self.id = id
            self.planID = planID
            self.version = version
            self.confirmedAt = confirmedAt
            self.payload = payload
        }
    }

    @Model
    final class SessionRecord {
        @Attribute(.unique) var id: UUID
        var startedAt: Date
        var status: String
        var revision: Int
        var payload: Data

        init(id: UUID, startedAt: Date, status: String, revision: Int, payload: Data) {
            self.id = id
            self.startedAt = startedAt
            self.status = status
            self.revision = revision
            self.payload = payload
        }
    }
}

enum FitnessMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [FitnessSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum StorageError: LocalizedError {
    case invalidStore(String)
    case stalePlan
    case activeSessionExists
    case missingSession
    case closedSession
    case immutableSessionIdentity
    case invalidCustomExercise
    case restoreWhileTraining
    case persistence(String)
    case backup(String)

    var errorDescription: String? {
        switch self {
        case .invalidStore(let reason): return "本地数据无法完整读取：\(reason)。原数据未清空，请保留文件并使用备份恢复。"
        case .stalePlan: return "计划已经发生变化，请重新打开当前版本后再确认。"
        case .activeSessionExists: return "还有未结束的训练，请先恢复或结束该次训练。"
        case .missingSession: return "没有找到这次训练。"
        case .closedSession: return "这次训练已经结束，当前版本只允许查看历史。"
        case .immutableSessionIdentity: return "不能修改训练身份或移除已存在的记录。"
        case .invalidCustomExercise: return "自定义动作的 ID、名称或类型无效，或已与现有动作重复。"
        case .restoreWhileTraining: return "请先结束正在进行或暂停的训练，再恢复备份。"
        case .persistence(let reason): return "保存失败，已保留原记录：\(reason)"
        case .backup(let reason): return reason
        }
    }
}

enum RecordCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
