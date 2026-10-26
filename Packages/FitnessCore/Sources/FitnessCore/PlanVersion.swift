import Foundation

public struct PlannedExercise: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var exercise: Exercise
    public var setCount: Int
    public var targetReps: Int?
    public var targetSeconds: Double?
    public var restSeconds: Double

    public init(id: UUID = UUID(), exercise: Exercise, setCount: Int = 3,
                targetReps: Int? = 10, targetSeconds: Double? = nil, restSeconds: Double = 90) {
        self.id = id; self.exercise = exercise; self.setCount = setCount
        self.targetReps = targetReps; self.targetSeconds = targetSeconds; self.restSeconds = restSeconds
    }

    public func validate() throws {
        try exercise.validate()
        guard (1...100).contains(setCount) else { throw CoreError.invalidInput("每个动作的组数应在 1 至 100 之间。") }
        if let targetReps, !(1...10_000).contains(targetReps) { throw CoreError.invalidInput("目标次数应在 1 至 10000 之间。") }
        if let targetSeconds { try CoreValidation.finite(targetSeconds, name: "目标时间", strictlyPositive: true) }
        try CoreValidation.finite(restSeconds, name: "组间休息")
        guard restSeconds <= 86_400 else { throw CoreError.invalidInput("单次组间休息不能超过 24 小时。") }
    }
}

public struct PlanVersion: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var planID: UUID
    public var version: Int
    public var parentVersionID: UUID?
    public var name: String
    public var items: [PlannedExercise]
    public var confirmedAt: Date

    public init(id: UUID = UUID(), planID: UUID = UUID(), version: Int = 1,
                parentVersionID: UUID? = nil, name: String, items: [PlannedExercise], confirmedAt: Date = Date()) {
        self.id = id; self.planID = planID; self.version = version; self.parentVersionID = parentVersionID
        self.name = name; self.items = items; self.confirmedAt = confirmedAt
    }

    public func validate() throws {
        try CoreValidation.nonempty(name, name: "计划名称", maxLength: 100)
        try CoreValidation.date(confirmedAt, name: "计划确认时间")
        guard version >= 1, version < Int.max else { throw CoreError.invalidInput("计划版本无效。") }
        guard (version == 1) == (parentVersionID == nil), parentVersionID != id else {
            throw CoreError.invalidInput("计划版本的父版本关联无效。")
        }
        guard !items.isEmpty, items.count <= 100 else { throw CoreError.invalidInput("一个计划需要 1 至 100 个动作。") }
        try CoreValidation.unique(items.map(\.id), name: "计划动作 ID")
        for item in items { try item.validate() }
    }

    public func revised(name: String, items: [PlannedExercise], at: Date = Date()) throws -> PlanVersion {
        try validate()
        guard at >= confirmedAt else { throw CoreError.invalidInput("新版本确认时间早于原计划，请检查系统时间。") }
        let result = PlanVersion(planID: planID, version: version + 1, parentVersionID: id,
                                 name: name, items: items, confirmedAt: at)
        try result.validate()
        return result
    }
}
