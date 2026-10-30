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
    public static func suggestedWalking(for constraint: TemporaryActivityConstraint,
                                        equipment: Set<PlanningEquipment>) throws -> PlanningItem {
        try constraint.validate()
        guard constraint.lightActivityAllowed == true, constraint.hasConcerningSymptoms == false else {
            throw CoreError.invalidState("先了解今天的身体状况和是否可以轻活动，再安排当天内容。")
        }
        let id = "builtin.walking"
        guard !constraint.excludedExerciseIDs.contains(id),
              PlannerEngine.isAvailable(exerciseID: id, equipment: equipment) else {
            throw CoreError.invalidInput("当前条件下无法安排步行，请继续了解适合的活动。")
        }
        return PlanningItem(exerciseID: id, setCount: 1, targetReps: nil,
                            targetSeconds: 300, restSeconds: 0,
                            notes: ["轻松活动，以舒适为准；出现疼痛或其他异常不适时停止。"])
    }
}
