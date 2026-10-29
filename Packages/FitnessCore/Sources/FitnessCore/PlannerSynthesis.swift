import Foundation

extension PlannerEngine {
    /// The exercises the AI is allowed to choose from, grouped by movement pattern.
    ///
    /// This is the only menu the model ever sees: every id here is a real catalogue exercise that
    /// already satisfies the user's equipment, exclusions and calibration stage. An id outside this
    /// pool is rejected when the plan is assembled, so the model cannot introduce a movement.
    public static func candidatePool(input: PlanningInput) throws -> [String: [String]] {
        try input.validate()
        var pool: [String: [String]] = [:]
        for pattern in [Pattern.squat, .hinge, .push, .pull, .core, .cardio] {
            let ids = candidates(pattern: pattern, input: input, simple: false).map(\.id)
                + candidates(pattern: pattern, input: input, simple: true).map(\.id)
            var unique: [String] = []
            for id in ids where !unique.contains(id) { unique.append(id) }
            if !unique.isEmpty { pool[pattern.rawValue] = unique }
        }
        return pool
    }

    /// Assembles a week from the AI's choices inside the validated pool, then re-validates it with the
    /// same rules the deterministic templates use.
    ///
    /// - Parameter choices: pattern raw value → exercise id, a subset of `candidatePool`.
    /// - Parameter preferredExerciseIDs: the user's stated preferences; used only to order the
    ///   remaining patterns that the AI did not choose explicitly.
    public static func synthesize(input: PlanningInput, choices: [String: String] = [:],
                                  preferredExerciseIDs: [String] = []) throws -> WeeklyPlanOption {
        try input.validate()
        let pool = try candidatePool(input: input)
        for (pattern, id) in choices {
            guard let allowed = pool[pattern], allowed.contains(id) else {
                throw CoreError.invalidInput("所选动作不在本地允许的动作范围内：\(id)。")
            }
        }
        let chosen = choices
        func pick(_ pattern: Pattern) throws -> String {
            if let id = chosen[pattern.rawValue] { return id }
            let allowed = pool[pattern.rawValue] ?? []
            // Prefer the user's stated preferences, then keep the pool's own order (stable).
            let preferred = allowed.filter { preferredExerciseIDs.contains($0) }
            guard let first = preferred.first ?? allowed.first else {
                throw CoreError.invalidInput("当前条件下没有可用的\(pattern.rawValue)类动作。请补充器械或调整排除项。")
            }
            return first
        }

        let strength = strengthWeekdays(input: input)
        let limits = input.minutesPerSession
        var days: [PlanningDay] = []
        for weekday in 1...7 {
            if !input.weekdays.contains(weekday) {
                days.append(PlanningDay(weekday: weekday, title: "休息与日常活动", items: [],
                                        estimatedMinutesLower: 0, estimatedMinutesUpper: 0,
                                        notes: ["没有训练处方；保持适合自己的普通日常活动。无强制补课。"]))
                continue
            }
            if let index = strength.firstIndex(of: weekday) {
                let items = try assembledItems(input: input, index: index, pick: pick)
                let estimate = timeRange(items: items)
                guard estimate.upper <= limits else {
                    throw CoreError.invalidInput("组合后的训练超过可用时间，请减少动作或增加时间。")
                }
                days.append(PlanningDay(weekday: weekday, title: "基础抗阻 \(["A", "B", "C"][index])",
                                        items: items, estimatedMinutesLower: estimate.lower,
                                        estimatedMinutesUpper: estimate.upper,
                                        notes: ["先用轻重量或容易控制的变式校准，保留余力，不追求力竭。",
                                                "估时含热身、所有规定休息、换动作与缓和；如实际超时，结束并保留记录。"]))
            } else {
                let id = try pick(.cardio)
                let minutes = min(input.experience == .regular ? 30 : 15, max(5, limits - 8))
                var item = PlanningItem(exerciseID: id, setCount: 1, targetReps: nil,
                                        targetSeconds: Double(minutes * 60), restSeconds: 0,
                                        notes: ["强度以能舒适交谈为起点，记录实际时长；没有距离就不生成速度。",
                                                "准备和结束时逐渐加快/放慢；出现异常不适停止。"])
                var adjusted = minutes
                while adjusted > 5, timeRange(items: [item]).upper > limits {
                    adjusted -= 1
                    item.targetSeconds = Double(adjusted * 60)
                }
                let estimate = timeRange(items: [item])
                guard estimate.upper <= limits else {
                    throw CoreError.invalidInput("有氧日的准备与缓和后仍超过时间预算，请增加可用时间。")
                }
                days.append(PlanningDay(weekday: weekday, title: "轻松有氧与习惯建立", items: [item],
                                        estimatedMinutesLower: estimate.lower,
                                        estimatedMinutesUpper: estimate.upper,
                                        notes: ["选择可舒适交谈的强度，不用未知最大心率推算精确心率区间。",
                                                "先从可承受的少量开始，不把成人活动指南当作第一周必须完成的配额。"]))
            }
        }
        let option = WeeklyPlanOption(id: profileOptionID, title: "按你的情况组合",
                                      days: days,
                                      rationale: ["动作由 AI 在本地允许范围内选择，组数、休息和时间再由本地规则复核。",
                                                  "只使用你已确认的目标、经验、器械和时间；未知项没有补猜。",
                                                  "规则 \(rulesVersion)；目录 \(catalogVersion)；估时 \(timingVersion)。"],
                                      limitations: ["这是第一版校准安排，不是长期周期化结果；每周按实际表现复核。",
                                                    "未指定公斤数：能力未知时用轻重量或容易变式校准并记录实际结果。"] + constraintLimitations(input: input),
                                      rulesVersion: rulesVersion)
        try validate(option: option, input: input)
        return option
    }

    /// Option id for a profile-fitted week. Kept separate from the template ids so stored plans
    /// remain distinguishable.
    public static let profileOptionID = "profile-fitted"

    static func strengthWeekdays(input: PlanningInput) -> [Int] {
        let desired: Int
        switch input.goal {
        case .endurance: desired = input.weekdays.count >= 4 ? 2 : input.weekdays.count >= 3 ? 1 : 0
        case .fatLoss: desired = min(2, input.weekdays.count)
        default: desired = min(3, input.weekdays.count)
        }
        var strength: [Int] = []
        for weekday in input.weekdays where strength.count < desired {
            if strength.allSatisfy({ cyclicDistance($0, weekday) >= 2 }) { strength.append(weekday) }
        }
        return strength
    }

    private static func assembledItems(input: PlanningInput, index: Int,
                                       pick: (Pattern) throws -> String) throws -> [PlanningItem] {
        let groups: [Pattern] = index == 1 ? [.hinge, .push, .pull, .squat, .core]
                                           : [.squat, .push, .pull, .hinge, .core]
        var selected: [String] = []
        for group in groups {
            // A missing pattern is skipped rather than faked: not every equipment set can support
            // every movement direction, and the caller checks the resulting coverage.
            guard let id = try? pick(group) else { continue }
            if !selected.contains(id) { selected.append(id) }
        }
        guard selected.count >= 2 else {
            throw CoreError.invalidInput("排除选项或器械条件下没有至少 2 个可行动作，请调整条件或手动创建。")
        }
        let sets = input.experience == .returning || input.minutesPerSession < 25 ? 1 : 2
        let reps = input.goal == .strength ? 8 : 10
        let rest = input.minutesPerSession < 25 ? 60.0 : input.goal == .strength ? 120.0 : 90.0
        var items = selected.map { id -> PlanningItem in
            let isDuration = ExerciseCatalog.exercise(id: id)?.metric == .duration
            return PlanningItem(exerciseID: id, setCount: sets, targetReps: isDuration ? nil : reps,
                                targetSeconds: isDuration ? 15 : nil, restSeconds: rest,
                                notes: ["首次不指定公斤数：选择能稳定完成且仍有余力的轻重量或容易变式，记录实际结果。",
                                        "没有 RPE/RIR 记录时不猜；出现疼痛或异常不适就停止相关动作。"])
        }
        while items.count > 2, timeRange(items: items).upper > input.minutesPerSession { items.removeLast() }
        if timeRange(items: items).upper > input.minutesPerSession {
            items = items.map { item in
                var reduced = item
                reduced.setCount = 1
                reduced.restSeconds = 60
                return reduced
            }
        }
        guard timeRange(items: items).upper <= input.minutesPerSession else {
            throw CoreError.invalidInput("含准备、休息与换动作后的时间仍不足，请增加时间或减少动作。")
        }
        return items
    }
}
