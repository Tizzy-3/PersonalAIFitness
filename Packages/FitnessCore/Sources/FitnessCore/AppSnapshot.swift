import Foundation

public struct AppSnapshot: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var profile: PersonalProfile
    public var activePlanVersionID: UUID?
    public var planVersions: [PlanVersion]
    public var sessions: [WorkoutSession]
    public var customExercises: [Exercise]

    public init(formatVersion: Int = 1, exportedAt: Date = Date(), profile: PersonalProfile = PersonalProfile(),
                activePlanVersionID: UUID? = nil, planVersions: [PlanVersion] = [],
                sessions: [WorkoutSession] = [], customExercises: [Exercise] = []) {
        self.formatVersion = formatVersion; self.exportedAt = exportedAt; self.profile = profile
        self.activePlanVersionID = activePlanVersionID; self.planVersions = planVersions
        self.sessions = sessions; self.customExercises = customExercises
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw CoreError.unsupportedFormat(formatVersion) }
        try CoreValidation.date(exportedAt, name: "导出时间")
        try profile.validate()
        guard planVersions.count <= 100_000, sessions.count <= 100_000, customExercises.count <= 10_000 else {
            throw CoreError.invalidInput("备份记录数量超出当前版本支持范围。")
        }
        try CoreValidation.unique(planVersions.map(\.id), name: "计划版本 ID")
        try CoreValidation.unique(sessions.map(\.id), name: "训练 ID")
        try CoreValidation.unique(customExercises.map(\.id), name: "自定义动作 ID")
        try CoreValidation.unique(sessions.flatMap(\.exercises).map(\.id), name: "训练动作 ID")
        try CoreValidation.unique(sessions.flatMap(\.exercises).flatMap(\.sets).map(\.id), name: "组 ID")
        guard sessions.filter({ $0.status.isOngoing }).count <= 1 else {
            throw CoreError.invalidState("备份中存在多次未结束训练，不能自动选择或合并。")
        }
        let builtInIDs = Set(ExerciseCatalog.exercises.map(\.id))
        let customByID = Dictionary(uniqueKeysWithValues: customExercises.map { ($0.id, $0) })
        for exercise in customExercises {
            try exercise.validate()
            guard exercise.isCustom, !builtInIDs.contains(exercise.id) else {
                throw CoreError.invalidInput("自定义动作不能覆盖内置动作 ID。")
            }
        }
        let versions = Dictionary(uniqueKeysWithValues: planVersions.map { ($0.id, $0) })
        if let activePlanVersionID, versions[activePlanVersionID] == nil { throw CoreError.missingReference("生效计划版本") }
        var versionNumbers: [UUID: Set<Int>] = [:]
        for version in planVersions {
            try version.validate()
            guard versionNumbers[version.planID, default: []].insert(version.version).inserted else {
                throw CoreError.duplicateIdentifier("同一计划的版本号")
            }
            if let parentID = version.parentVersionID {
                guard let parent = versions[parentID], parent.planID == version.planID,
                      parent.version == version.version - 1, parent.confirmedAt <= version.confirmedAt else {
                    throw CoreError.missingReference("连续的计划父版本")
                }
            }
            for item in version.items { try validateReference(item.exercise, builtInIDs: builtInIDs, customByID: customByID) }
        }
        for session in sessions {
            try session.validate()
            if let sourceID = session.sourcePlanVersionID {
                guard let version = versions[sourceID], version.confirmedAt <= session.startedAt else {
                    throw CoreError.missingReference("训练开始时的计划版本")
                }
            }
            for entry in session.exercises { try validateReference(entry.exercise, builtInIDs: builtInIDs, customByID: customByID) }
        }
    }

    private func validateReference(_ exercise: Exercise, builtInIDs: Set<String>, customByID: [String: Exercise]) throws {
        if exercise.isCustom {
            guard let original = customByID[exercise.id] else { throw CoreError.missingReference("自定义动作 \(exercise.name)") }
            guard original.kind == exercise.kind, original.metric == exercise.metric,
                  original.loadConvention == exercise.loadConvention else {
                throw CoreError.invalidInput("自定义动作的训练类型或记录口径与动作目录不一致，不能导入。")
            }
        } else {
            guard builtInIDs.contains(exercise.id) else { throw CoreError.missingReference("内置动作 \(exercise.name)") }
            guard let original = ExerciseCatalog.exercise(id: exercise.id),
                  original.kind == exercise.kind, original.metric == exercise.metric,
                  original.loadConvention == exercise.loadConvention else {
                throw CoreError.invalidInput("内置动作的训练类型或记录口径被改变，不能导入。")
            }
        }
    }
}

public enum SnapshotCodec {
    public static let maximumDataBytes = 64 * 1_024 * 1_024

    public static func encode(_ snapshot: AppSnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumDataBytes else { throw CoreError.invalidInput("备份超过 64 MB，请缩小导出范围。") }
        return data
    }

    public static func decode(_ data: Data) throws -> AppSnapshot {
        guard !data.isEmpty, data.count <= maximumDataBytes else { throw CoreError.invalidInput("备份为空或超过 64 MB。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot: AppSnapshot
        do { snapshot = try decoder.decode(AppSnapshot.self, from: data) }
        catch { throw CoreError.invalidInput("备份内容无法读取或格式不完整。") }
        try snapshot.validate()
        return snapshot
    }
}
