import Foundation

/// One-off limits explicitly confirmed by the person; absence of an answer is not permission.
public struct TemporaryActivityConstraint: Codable, Equatable, Sendable {
    public let dateKey: String
    public let lightActivityAllowed: Bool?
    public let hasConcerningSymptoms: Bool?
    public let excludedExerciseIDs: [String]

    public init(dateKey: String, lightActivityAllowed: Bool?, hasConcerningSymptoms: Bool?,
                excludedExerciseIDs: [String] = []) {
        self.dateKey = dateKey
        self.lightActivityAllowed = lightActivityAllowed
        self.hasConcerningSymptoms = hasConcerningSymptoms
        self.excludedExerciseIDs = excludedExerciseIDs
    }

    public func applies(on date: Date, calendar: Calendar = .current) -> Bool {
        TrainingConstraintReview.dateKey(date, calendar: calendar) == dateKey
    }

    /// ISO calendar weekday (Monday = 1), interpreted as a civil date rather than an instant.
    public var weekday: Int? {
        guard TrainingConstraintReview.isValidDateKey(dateKey) else { return nil }
        let parts = dateKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        return ((calendar.component(.weekday, from: date) + 5) % 7) + 1
    }

    public func validate() throws {
        guard TrainingConstraintReview.isValidDateKey(dateKey) else {
            throw CoreError.invalidInput("请先确认受影响的具体日期。")
        }
        try CoreValidation.unique(excludedExerciseIDs, name: "需要避开的动作")
        for id in excludedExerciseIDs where ExerciseCatalog.exercise(id: id) == nil {
            throw CoreError.missingReference("训练约束动作 \(id)")
        }
    }
}

/// A deterministic candidate, not a clinical assessment or permission to exercise.
public enum GentleDayPlanner {
    public static func suggestedActivity(for constraint: TemporaryActivityConstraint,
                                         equipment: Set<PlanningEquipment>, preferredID: String? = nil,
                                         excludedExerciseIDs: [String] = [], allowedExerciseIDs: [String]? = nil) throws -> PlanningItem {
        try constraint.validate()
        guard constraint.lightActivityAllowed == true, constraint.hasConcerningSymptoms == false else {
            throw CoreError.invalidState("先了解今天的身体状况和是否可以轻活动，再安排当天内容。")
        }
        let supported = ["builtin.walking", "builtin.stationary-cycling"]
        let preferred = preferredID.flatMap { supported.contains($0) ? $0 : nil }
        let candidates = (preferred.map { [$0] } ?? []) + supported.filter { $0 != preferred }
        guard let id = candidates.first(where: {
            !constraint.excludedExerciseIDs.contains($0) && !excludedExerciseIDs.contains($0)
                && (allowedExerciseIDs?.contains($0) ?? true)
                && PlannerEngine.isAvailable(exerciseID: $0, equipment: equipment)
        }) else {
            throw CoreError.invalidInput("当前条件下没有可用的轻活动，请继续了解适合的活动。")
        }
        return PlanningItem(exerciseID: id, setCount: 1, targetReps: nil,
                            targetSeconds: 300, restSeconds: 0,
                            notes: ["轻松活动，以舒适为准；出现疼痛或其他异常不适时停止。"])
    }

    public static func suggestedWalking(for constraint: TemporaryActivityConstraint,
                                        equipment: Set<PlanningEquipment>) throws -> PlanningItem {
        try suggestedActivity(for: constraint, equipment: equipment, allowedExerciseIDs: ["builtin.walking"])
    }
}
