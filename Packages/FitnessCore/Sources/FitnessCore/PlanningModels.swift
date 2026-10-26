import Foundation

public enum PlanningGoal: String, CaseIterable, Codable, Sendable {
    case generalFitness, strength, muscleGain, fatLoss, endurance
    public var title: String {
        switch self {
        case .generalFitness: return "改善体能与坚持训练"
        case .strength: return "提高基础力量"
        case .muscleGain: return "增肌"
        case .fatLoss: return "减脂期间保持活动"
        case .endurance: return "提高有氧耐力"
        }
    }
}

public enum PlanningExperience: String, CaseIterable, Codable, Sendable {
    case beginner, regular, returning
    public var title: String {
        switch self { case .beginner: return "初学或能力未校准"; case .regular: return "近期有规律训练"; case .returning: return "中断后重新适应" }
    }
}

public enum PlanningSafety: String, CaseIterable, Codable, Sendable {
    case unknown, noKnownRestrictions, hasRestrictions, acuteSymptoms
    public var title: String {
        switch self { case .unknown: return "尚未确认"; case .noKnownRestrictions: return "无已知运动限制"; case .hasRestrictions: return "存在伤病或运动限制"; case .acuteSymptoms: return "存在急性或异常不适" }
    }
}

public enum PlanningEquipment: String, CaseIterable, Codable, Hashable, Sendable {
    case bodyweight, dumbbells, bench, adjustableBench, barbell, squatRack, cableMachine, latPulldown
    case legPress, legCurl, pullupBar, stationaryBike, rowingErgometer, elliptical, resistanceBand, stableSupport, walkingSpace, runningSpace
    public var title: String {
        switch self {
        case .bodyweight: return "徒手/地面空间"; case .dumbbells: return "哑铃"; case .bench: return "平板训练凳"
        case .adjustableBench: return "可调训练凳"; case .barbell: return "杠铃"; case .squatRack: return "深蹲架"
        case .cableMachine: return "绳索器械"; case .latPulldown: return "高位下拉器械"; case .legPress: return "腿举器械"
        case .legCurl: return "腿弯举器械"; case .pullupBar: return "单杠"; case .stationaryBike: return "固定单车"
        case .rowingErgometer: return "划船机"; case .elliptical: return "椭圆机"; case .resistanceBand: return "弹力带"
        case .stableSupport: return "经本人确认稳固的支撑台"; case .walkingSpace: return "安全步行空间"; case .runningSpace: return "安全跑步空间"
        }
    }
}

public struct PlanningInput: Codable, Equatable, Sendable {
    public var goal: PlanningGoal
    public var experience: PlanningExperience
    public var weekdays: [Int]
    public var minutesPerSession: Int
    public var equipment: Set<PlanningEquipment>
    public var adultConfirmed: Bool
    public var safety: PlanningSafety
    public var painToday: Bool?
    public var excludedExerciseIDs: [String]
    public var completedSessionsLast28Days: Int
    public var daysSinceLastTraining: Int?

    public init(goal: PlanningGoal, experience: PlanningExperience, weekdays: [Int], minutesPerSession: Int,
                equipment: Set<PlanningEquipment>, adultConfirmed: Bool, safety: PlanningSafety, painToday: Bool?,
                excludedExerciseIDs: [String] = [], completedSessionsLast28Days: Int = 0, daysSinceLastTraining: Int? = nil) {
        self.goal = goal; self.experience = experience; self.weekdays = weekdays.sorted()
        self.minutesPerSession = minutesPerSession; self.equipment = equipment; self.adultConfirmed = adultConfirmed
        self.safety = safety; self.painToday = painToday; self.excludedExerciseIDs = excludedExerciseIDs.sorted()
        self.completedSessionsLast28Days = completedSessionsLast28Days; self.daysSinceLastTraining = daysSinceLastTraining
    }

    public func validate() throws {
        guard adultConfirmed else { throw CoreError.invalidInput("本批自动计划仅面向已明确确认年满18岁的健康成人。未确认时仍可手动记录。") }
        guard safety == .noKnownRestrictions else {
            throw CoreError.invalidInput(safety == .acuteSymptoms ? "存在急性或异常不适时不生成训练处方，请先停止相关活动并寻求适当专业帮助。" : "请先明确运动限制；存在伤病/限制时，本批不自动安排，仍可按专业建议手动编辑。")
        }
        guard painToday == false else { throw CoreError.invalidInput("请明确今日没有疼痛或异常不适；未知或有不适时不自动制定训练计划。") }
        guard !weekdays.isEmpty, weekdays.count <= 7, weekdays == weekdays.sorted(), weekdays.allSatisfy({ (1...7).contains($0) }) else {
            throw CoreError.invalidInput("请选择1至7个实际可训练日。")
        }
        try CoreValidation.unique(weekdays, name: "训练星期")
        guard (15...120).contains(minutesPerSession), !equipment.isEmpty else {
            throw CoreError.invalidInput("单次时间需为15至120分钟；请选择可用器械或明确选择徒手空间。")
        }
        guard completedSessionsLast28Days >= 0, completedSessionsLast28Days <= 100_000,
              daysSinceLastTraining == nil || (0...1_000_000).contains(daysSinceLastTraining!) else {
            throw CoreError.invalidInput("训练历史摘要无效。")
        }
        try CoreValidation.unique(excludedExerciseIDs, name: "排除动作 ID")
        for id in excludedExerciseIDs where ExerciseCatalog.exercise(id: id) == nil {
            throw CoreError.missingReference("排除动作 \(id)")
        }
    }
}

public struct PlanningItem: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var setCount: Int
    public var targetReps: Int?
    public var targetSeconds: Double?
    public var restSeconds: Double
    public var notes: [String]
    public init(exerciseID: String, setCount: Int, targetReps: Int?, targetSeconds: Double?, restSeconds: Double, notes: [String]) {
        self.exerciseID = exerciseID; self.setCount = setCount; self.targetReps = targetReps
        self.targetSeconds = targetSeconds; self.restSeconds = restSeconds; self.notes = notes
    }
}

public struct PlanningDay: Identifiable, Codable, Equatable, Sendable {
    public var id: Int { weekday }
    public var weekday: Int
    public var title: String
    public var items: [PlanningItem]
    public var estimatedMinutesLower: Int
    public var estimatedMinutesUpper: Int
    public var notes: [String]
    public var isRestDay: Bool { items.isEmpty }
    public init(weekday: Int, title: String, items: [PlanningItem], estimatedMinutesLower: Int, estimatedMinutesUpper: Int, notes: [String]) {
        self.weekday = weekday; self.title = title; self.items = items
        self.estimatedMinutesLower = estimatedMinutesLower; self.estimatedMinutesUpper = estimatedMinutesUpper; self.notes = notes
    }
}

public struct WeeklyPlanOption: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var days: [PlanningDay]
    public var rationale: [String]
    public var limitations: [String]
    public var rulesVersion: String
    public init(id: String, title: String, days: [PlanningDay], rationale: [String], limitations: [String], rulesVersion: String) {
        self.id = id; self.title = title; self.days = days; self.rationale = rationale; self.limitations = limitations; self.rulesVersion = rulesVersion
    }
    public func validate(input: PlanningInput) throws { try PlannerEngine.validate(option: self, input: input) }
}

public struct AISelection: Codable, Equatable, Sendable {
    public var optionID: String
    public var explanation: String
    public var evidence: [String]
    public var limitations: [String]
    public init(optionID: String, explanation: String, evidence: [String], limitations: [String]) {
        self.optionID = optionID; self.explanation = explanation; self.evidence = evidence; self.limitations = limitations
    }
    public func validate(options: [WeeklyPlanOption]) throws {
        try CoreValidation.nonempty(explanation, name: "AI计划说明", maxLength: 12_000)
        let allowed = Set(["request", "history", "rules"] + options.map { "option:\($0.id)" })
        guard options.contains(where: { $0.id == optionID }), evidence.count <= 30, Set(evidence).isSubset(of: allowed),
              limitations.count <= 20, limitations.allSatisfy({ $0.count <= 2_000 }) else {
            throw CoreError.invalidInput("AI只能选择已通过本地规则的现有方案，且只能引用实际发送的依据。")
        }
    }
    public static func decode(data: Data, options: [WeeklyPlanOption]) throws -> AISelection {
        guard !data.isEmpty, data.count <= 128 * 1_024 else { throw CoreError.invalidInput("AI计划选择为空或超长。") }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == Set(["optionID", "explanation", "evidence", "limitations"]) else {
                throw CoreError.invalidInput("AI计划选择包含不允许的字段，未应用。")
            }
            let value = try JSONDecoder().decode(AISelection.self, from: data)
            try value.validate(options: options)
            return value
        } catch let error as CoreError { throw error }
        catch { throw CoreError.invalidInput("AI没有返回约定的计划选择格式，原计划未变。") }
    }
}

public struct PlanningDraft: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var input: PlanningInput
    public var options: [WeeklyPlanOption]
    public var sourceProfile: PersonalProfile
    public var sourceActivePlanVersionID: UUID?
    public var sourceActiveWeeklyProgramID: UUID?
    public var sourceSessionRevisions: [String: Int]
    public var selection: AISelection?
    public var providerHost: String?
    public var model: String?
    public var decision: CoachDecision
    public var appliedProgramID: UUID?

    public static func make(input: PlanningInput, snapshot: AppSnapshot, at: Date = Date()) throws -> PlanningDraft {
        try CoreValidation.date(at, name: "计划草案时间")
        try snapshot.validate()
        try validateProfile(snapshot.profile, input: input, at: at)
        let normalized = normalizedHistory(input: input, snapshot: snapshot, at: at)
        try normalized.validate()
        let recent = Array(snapshot.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(10))
        try CoreValidation.unique(recent.map(\.id), name: "计划依据训练 ID")
        let draft = PlanningDraft(id: UUID(), createdAt: at, input: normalized, options: try PlannerEngine.options(for: normalized),
                                  sourceProfile: snapshot.profile, sourceActivePlanVersionID: snapshot.activePlanVersionID,
                                  sourceActiveWeeklyProgramID: snapshot.activeWeeklyProgramID,
                                  sourceSessionRevisions: Dictionary(uniqueKeysWithValues: recent.map { ($0.id.uuidString, $0.revision) }),
                                  selection: nil, providerHost: nil, model: nil, decision: .pending, appliedProgramID: nil)
        try draft.validate()
        return draft
    }

    public func matches(snapshot: AppSnapshot, at: Date = Date()) -> Bool {
        let age = at.timeIntervalSince(createdAt)
        guard age >= -300, age <= 7 * 86_400, sourceProfile == snapshot.profile,
              sourceActivePlanVersionID == snapshot.activePlanVersionID,
              sourceActiveWeeklyProgramID == snapshot.activeWeeklyProgramID else { return false }
        let recent = Array(snapshot.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(10))
        guard Set(recent.map(\.id)).count == recent.count else { return false }
        let revisions = Dictionary(uniqueKeysWithValues: recent.map { ($0.id.uuidString, $0.revision) })
        let normalized = Self.normalizedHistory(input: input, snapshot: snapshot, at: createdAt)
        return revisions == sourceSessionRevisions && normalized == input
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "计划草案时间")
        try Self.validateProfile(sourceProfile, input: input, at: createdAt)
        try input.validate()
        guard options == (try PlannerEngine.options(for: input)), sourceSessionRevisions.count <= 10,
              sourceSessionRevisions.values.allSatisfy({ $0 >= 0 }), sourceSessionRevisions.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw CoreError.invalidInput("计划草案与保存的规则输入不一致，不能确认或恢复。")
        }
        if let selection { try selection.validate(options: options) }
        guard (decision == .accepted) == (appliedProgramID != nil),
              (providerHost == nil) == (model == nil), providerHost.map({ !$0.isEmpty && $0.count <= 255 }) ?? true,
              model.map({ !$0.isEmpty && $0.count <= 200 }) ?? true else {
            throw CoreError.invalidInput("计划草案决定或AI来源不完整。")
        }
        if selection != nil, providerHost == nil { throw CoreError.invalidInput("AI方案选择缺少实际服务来源。") }
    }

    private static func normalizedHistory(input: PlanningInput, snapshot: AppSnapshot, at: Date) -> PlanningInput {
        var result = input
        let finished = snapshot.sessions.filter {
            !$0.status.isOngoing && $0.startedAt <= at && $0.exercises.contains { movement in
                !movement.skipped && movement.sets.contains { $0.isCompleted && !$0.skipped }
            }
        }
        result.completedSessionsLast28Days = finished.filter { $0.startedAt >= at.addingTimeInterval(-28 * 86_400) }.count
        if let latest = finished.compactMap(\.endedAt).filter({ $0 <= at }).max() {
            result.daysSinceLastTraining = max(0, Int(floor(at.timeIntervalSince(latest) / 86_400)))
        } else { result.daysSinceLastTraining = nil }
        return result
    }

    private static func validateProfile(_ profile: PersonalProfile, input: PlanningInput, at: Date) throws {
        try profile.validate()
        try input.validate()
        let restrictions = profile.restrictions.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noRestrictionDeclarations = Set(["", "无", "无已知限制", "无运动限制", "没有已知限制", "none"])
        guard noRestrictionDeclarations.contains(restrictions) else {
            throw CoreError.invalidInput("档案仍记有运动限制，不能用本次无已知限制声明覆盖。请先核对档案，或按专业建议手动创建。")
        }
        if let year = profile.birthYear {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let current = calendar.component(.year, from: at)
            guard current - year >= 18 else { throw CoreError.invalidInput("档案显示尚未年满18岁，本批不自动安排训练。") }
        }
    }
}

public struct WeeklyProgram: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var confirmedAt: Date
    /// Frozen pending input: its external draft is accepted atomically by storage.
    public var draft: PlanningDraft
    public var selectedOptionID: String
    public var dayPlanVersionIDs: [Int: UUID]
    public var selectedOption: WeeklyPlanOption? { draft.options.first { $0.id == selectedOptionID } }
    public init(id: UUID = UUID(), confirmedAt: Date = Date(), draft: PlanningDraft, selectedOptionID: String, dayPlanVersionIDs: [Int: UUID]) {
        self.id = id; self.confirmedAt = confirmedAt; self.draft = draft; self.selectedOptionID = selectedOptionID; self.dayPlanVersionIDs = dayPlanVersionIDs
    }
    public func validate() throws {
        try CoreValidation.date(confirmedAt, name: "周计划确认时间")
        try draft.validate()
        guard draft.decision == .pending, draft.appliedProgramID == nil, confirmedAt >= draft.createdAt,
              let option = selectedOption else { throw CoreError.invalidInput("周计划缺少有效待确认草案或选择。") }
        let required = Set(option.days.filter { !$0.isRestDay }.map(\.weekday))
        guard Set(dayPlanVersionIDs.keys) == required else { throw CoreError.invalidInput("周计划每天的记录计划关联不完整。") }
        try CoreValidation.unique(Array(dayPlanVersionIDs.values), name: "周计划日版本 ID")
    }
}
