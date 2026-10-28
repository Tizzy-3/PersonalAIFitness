import Foundation

/// Small versioned calibration templates. AI may select an option, never create these quantities.
public enum PlannerEngine {
    public static let rulesVersion = "starter-week-1"
    public static let catalogVersion = ExerciseCatalog.version
    public static let timingVersion = "starter-time-1"

    enum Pattern: String { case squat, hinge, push, pull, core, cardio }
    struct Movement {
        let id: String
        let pattern: Pattern
        /// Any one requirement set is sufficient; an empty set means no dedicated equipment.
        let requirements: [Set<PlanningEquipment>]
    }
    static let movements: [Movement] = [
        Movement(id: "builtin.bodyweight-squat", pattern: .squat, requirements: [[.bodyweight]]),
        Movement(id: "builtin.goblet-squat", pattern: .squat, requirements: [[.dumbbells], [.kettlebells]]),
        Movement(id: "builtin.kettlebell-deadlift", pattern: .hinge, requirements: [[.kettlebells]]),
        Movement(id: "builtin.leg-press", pattern: .squat, requirements: [[.legPress]]),
        Movement(id: "builtin.box-squat", pattern: .squat, requirements: [[.stableSupport]]),
        Movement(id: "builtin.glute-bridge", pattern: .hinge, requirements: [[.bodyweight]]),
        Movement(id: "builtin.dumbbell-rdl", pattern: .hinge, requirements: [[.dumbbells]]),
        Movement(id: "builtin.knee-push-up", pattern: .push, requirements: [[.bodyweight]]),
        Movement(id: "builtin.incline-push-up", pattern: .push, requirements: [[.stableSupport]]),
        Movement(id: "builtin.push-up", pattern: .push, requirements: [[.bodyweight]]),
        Movement(id: "builtin.dumbbell-bench-press", pattern: .push, requirements: [[.dumbbells, .bench], [.dumbbells, .adjustableBench]]),
        Movement(id: "builtin.dumbbell-row", pattern: .pull, requirements: [[.dumbbells, .bench], [.dumbbells, .adjustableBench], [.dumbbells, .stableSupport]]),
        Movement(id: "builtin.seated-cable-row", pattern: .pull, requirements: [[.cableMachine]]),
        Movement(id: "builtin.lat-pulldown", pattern: .pull, requirements: [[.latPulldown]]),
        Movement(id: "builtin.band-pull-apart", pattern: .pull, requirements: [[.resistanceBand]]),
        Movement(id: "builtin.dead-bug", pattern: .core, requirements: [[.bodyweight]]),
        Movement(id: "builtin.bird-dog", pattern: .core, requirements: [[.bodyweight]]),
        Movement(id: "builtin.plank", pattern: .core, requirements: [[.bodyweight]]),
        Movement(id: "builtin.walking", pattern: .cardio, requirements: [[.walkingSpace], [.runningSpace]]),
        Movement(id: "builtin.stationary-cycling", pattern: .cardio, requirements: [[.stationaryBike]]),
        Movement(id: "builtin.elliptical", pattern: .cardio, requirements: [[.elliptical]]),
        Movement(id: "builtin.rowing-ergometer", pattern: .cardio, requirements: [[.rowingErgometer]]),
        Movement(id: "builtin.dumbbell-floor-press", pattern: .push, requirements: [[.dumbbells, .bodyweight]]),
        Movement(id: "builtin.dumbbell-front-squat", pattern: .squat, requirements: [[.dumbbells]]),
        Movement(id: "builtin.step-up", pattern: .squat, requirements: [[.stableSupport]]),
        Movement(id: "builtin.high-plank", pattern: .core, requirements: [[.bodyweight]]),
        Movement(id: "builtin.pallof-press", pattern: .core, requirements: [[.cableMachine]])
    ]

    public static func options(for input: PlanningInput) throws -> [WeeklyPlanOption] {
        try input.validate()
        let first = try build(input: input, simple: false)
        let second = try build(input: input, simple: true)
        // An extra option should reflect a real choice, not two labels for identical workouts.
        let sameWorkouts = zip(first.days, second.days).allSatisfy { left, right in left.items == right.items }
        return sameWorkouts ? [first] : [first, second]
    }

    public static func isAvailable(exerciseID: String, equipment: Set<PlanningEquipment>) -> Bool {
        guard let movement = movements.first(where: { $0.id == exerciseID }), ExerciseCatalog.exercise(id: exerciseID) != nil else { return false }
        return movement.requirements.contains { $0.isSubset(of: equipment) }
    }

    public static func validate(option: WeeklyPlanOption, input: PlanningInput) throws {
        try input.validate()
        guard ["equipment-first", "simple-first", profileOptionID].contains(option.id),
              option.rulesVersion == rulesVersion,
              option.days.map(\.weekday) == Array(1...7), option.title.count <= 100,
              option.rationale.count <= 20, option.limitations.count <= 20 else {
            throw CoreError.invalidInput("周计划结构、版本或星期安排不符合本地规则。")
        }
        var strengthDays: [Int] = []
        for day in option.days {
            guard day.title.count <= 100, day.notes.count <= 10, day.notes.allSatisfy({ $0.count <= 1_000 }) else {
                throw CoreError.invalidInput("计划日说明超长。")
            }
            guard day.isRestDay == !input.weekdays.contains(day.weekday) else {
                throw CoreError.invalidInput("训练只能安排在本人明确选择的星期。")
            }
            if day.isRestDay {
                guard day.estimatedMinutesLower == 0, day.estimatedMinutesUpper == 0 else { throw CoreError.invalidInput("休息日不能包含虚构训练时长。") }
                continue
            }
            guard (1...5).contains(day.items.count) else { throw CoreError.invalidInput("本批单日动作数量不符合保守模板。") }
            try CoreValidation.unique(day.items.map(\.exerciseID), name: "单日动作 ID")
            var hasStrength = false
            var hasCardio = false
            for item in day.items {
                guard !input.excludedExerciseIDs.contains(item.exerciseID), isAvailable(exerciseID: item.exerciseID, equipment: input.equipment),
                      let exercise = ExerciseCatalog.exercise(id: item.exerciseID) else {
                    throw CoreError.invalidInput("计划包含未知、已排除或器械不满足的动作。")
                }
                guard item.notes.count <= 8, item.notes.allSatisfy({ $0.count <= 1_000 }) else { throw CoreError.invalidInput("动作说明超长。") }
                if exercise.kind == .cardio {
                    hasCardio = true
                    guard item.setCount == 1, item.targetReps == nil, let seconds = item.targetSeconds,
                          seconds.isFinite, (300...1_800).contains(seconds), item.restSeconds == 0 else {
                        throw CoreError.invalidInput("有氧量超出本批保守校准规则。")
                    }
                    if input.experience != .regular, item.exerciseID == "builtin.rowing-ergometer" {
                        throw CoreError.invalidInput("能力未校准时不自动选择划船机技术动作。")
                    }
                } else {
                    hasStrength = true
                    guard (1...2).contains(item.setCount), item.restSeconds.isFinite, (60...120).contains(item.restSeconds) else {
                        throw CoreError.invalidInput("抗阻组数或休息超出本批保守规则。")
                    }
                    if exercise.metric == .repetitions {
                        guard let reps = item.targetReps, (6...12).contains(reps), item.targetSeconds == nil else {
                            throw CoreError.invalidInput("抗阻次数或记录单位无效。")
                        }
                    } else {
                        guard item.targetReps == nil, let seconds = item.targetSeconds,
                              seconds.isFinite, (10...30).contains(seconds) else { throw CoreError.invalidInput("徒手持续时间超出本批规则。") }
                    }
                }
                try PlannedExercise(exercise: exercise, setCount: item.setCount, targetReps: item.targetReps,
                                    targetSeconds: item.targetSeconds, restSeconds: item.restSeconds).validate()
            }
            guard !(hasStrength && hasCardio) else { throw CoreError.invalidInput("本批校准模板分开安排抗阻日和轻有氧日。") }
            if hasStrength { strengthDays.append(day.weekday) }
            let estimate = timeRange(items: day.items)
            guard day.estimatedMinutesLower == estimate.lower, day.estimatedMinutesUpper == estimate.upper,
                  estimate.lower > 0, estimate.upper <= input.minutesPerSession else {
                throw CoreError.invalidInput("计划估时不包含完整预算，或已超过可用时间。")
            }
        }
        guard strengthDays.count <= 3 else { throw CoreError.invalidInput("本批每周最多安排3个抗阻校准日。") }
        for pair in strengthDays.enumerated() {
            for other in strengthDays.dropFirst(pair.offset + 1) where cyclicDistance(pair.element, other) < 2 {
                throw CoreError.invalidInput("不连续安排抗阻校准日，包括周日与周一。")
            }
        }
    }

    /// Bounds include 3 min preparation + 2 min gradual finish, every prescribed rest,
    /// per-movement transition and a 20% upper buffer. These are product estimates, not a promise.
    static func timeRange(items: [PlanningItem]) -> (lower: Int, upper: Int) {
        guard !items.isEmpty else { return (0, 0) }
        var seconds = 300.0
        for item in items {
            let effort = item.targetSeconds ?? Double(item.targetReps ?? 0) * 4
            seconds += Double(item.setCount) * (effort + item.restSeconds) + 45
        }
        return (max(1, Int(floor(seconds / 60))), max(1, Int(ceil(seconds * 1.2 / 60))))
    }

    private static func build(input: PlanningInput, simple: Bool) throws -> WeeklyPlanOption {
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
        var limitations = [
            "这是健康成人的第一阶段保守校准，不是精确最佳训练量或长期周期。每周复核实际表现后再提出新草案。",
            "尚无完整睡眠、HRV、个人恢复基线或动作能力实测；本方案不生成恢复分数，也不预测最优公斤数。",
            "次数、组数、估时和不相邻策略属于版本化产品模板，不是所有人通用的医学阈值。"
        ]
        if strength.count < 2 { limitations.append("本次安排少于每周2次抗阻，没有伪装为达到一般指南方向；可在时间允许后逐步增加。") }
        if strength.count < desired { limitations.append("部分可训练日相邻，为避免连续抗阻校准，改安排轻有氧；若想增加抗阻频率，请调整可训练日。") }
        let hasPull = candidates(pattern: .pull, input: input, simple: simple).first != nil
        if !hasPull, !strength.isEmpty { limitations.append("当前器械/排除条件缺少可靠拉类动作，不能声称完整覆盖背部；可补充合适器械后重新制定。") }
        if input.equipment.contains(.resistanceBand), !input.equipment.contains(.dumbbells), !input.equipment.contains(.cableMachine), !input.equipment.contains(.latPulldown) {
            limitations.append("弹力带拉开仅作基础肩带练习，不能等同于完整的划船或下拉训练。")
        }
        if input.experience == .regular { limitations.append("本批仍使用基础校准模板；规律训练者的高负荷、专项或完整增肌周期需后续根据真实记录制定。") }
        if input.goal == .fatLoss { limitations.append("本方案不推算热量缺口或保证体重下降；活动只是体重管理的一部分。") }
        var days: [PlanningDay] = []
        for weekday in 1...7 {
            if !input.weekdays.contains(weekday) {
                days.append(PlanningDay(weekday: weekday, title: "休息与日常活动", items: [], estimatedMinutesLower: 0,
                                        estimatedMinutesUpper: 0, notes: ["没有训练处方；保持适合自己的普通日常活动。无强制补课。 "]))
            } else if let index = strength.firstIndex(of: weekday) {
                let items = try strengthItems(input: input, simple: simple, index: index)
                let estimate = timeRange(items: items)
                let title = "基础抗阻 \(["A", "B", "C"][index])"
                days.append(PlanningDay(weekday: weekday, title: title, items: items, estimatedMinutesLower: estimate.lower,
                                        estimatedMinutesUpper: estimate.upper,
                                        notes: ["先用轻重量或容易控制的变式校准，保留余力，不追求力竭。", "估时含热身、所有规定休息、换动作与缓和；如实际超时，结束并保留记录，不赶组数。 "]))
            } else {
                let items = try cardioItems(input: input, simple: simple)
                let estimate = timeRange(items: items)
                days.append(PlanningDay(weekday: weekday, title: "轻松有氧与习惯建立", items: items, estimatedMinutesLower: estimate.lower,
                                        estimatedMinutesUpper: estimate.upper, notes: ["选择可舒适交谈的强度，不用未知最大心率推算精确心率区间。", "先从可承受的少量开始，不把成人公共活动指南当作第一周必须完成的配额。 "]))
            }
        }
        let result = WeeklyPlanOption(id: simple ? "simple-first" : "equipment-first", title: simple ? "简易变式优先" : "可用器械优先",
                                      days: days, rationale: ["按本人选择的目标、星期、器械和时间生成；动作只能来自内置规则白名单。",
                                                               "近28天已有完成记录：\(input.completedSessionsLast28Days)次；没有记录不等于本人没有运动。",
                                                               "规则 \(rulesVersion)；目录 \(catalogVersion)；估时 \(timingVersion)。",
                                                               "参考：ACSM2026健康成人抗阻原则；WHO2020逐步增加活动原则。"],
                                      limitations: limitations, rulesVersion: rulesVersion)
        try validate(option: result, input: input)
        return result
    }

    static func strengthItems(input: PlanningInput, simple: Bool, index: Int) throws -> [PlanningItem] {
        let groups: [Pattern] = index == 1 ? [.hinge, .push, .pull, .squat, .core] : [.squat, .push, .pull, .hinge, .core]
        var selected: [Movement] = []
        for group in groups {
            if let first = candidates(pattern: group, input: input, simple: simple).first { selected.append(first) }
        }
        guard selected.count >= 2 else { throw CoreError.invalidInput("排除动作或器械条件下没有至少2个可行基础动作，请修改条件或手动创建。") }
        let sets = input.experience == .returning || input.minutesPerSession < 25 ? 1 : 2
        let reps = input.goal == .strength ? 8 : 10
        let rest = input.minutesPerSession < 25 ? 60.0 : input.goal == .strength ? 120.0 : 90.0
        var items = selected.map { movement in
            let exercise = ExerciseCatalog.exercise(id: movement.id)
            let duration = exercise?.metric == .duration
            return PlanningItem(exerciseID: movement.id, setCount: sets, targetReps: duration ? nil : reps,
                                targetSeconds: duration ? 15 : nil, restSeconds: rest,
                                notes: ["首次不指定公斤数：选择能稳定完成且仍有余力的轻重量或容易变式，记录实际结果。", "没有RPE/RIR记录时不猜；出现疼痛或异常不适就停止相关动作。"])
        }
        while items.count > 2, timeRange(items: items).upper > input.minutesPerSession { items.removeLast() }
        if timeRange(items: items).upper > input.minutesPerSession {
            items = items.map { item in
                var reduced = item; reduced.setCount = 1; reduced.restSeconds = 60
                return reduced
            }
        }
        guard timeRange(items: items).upper <= input.minutesPerSession else {
            throw CoreError.invalidInput("含准备、休息与换动作后的时间仍不足，请增加可训练时间或手动安排更短训练。")
        }
        return items
    }

    static func cardioItems(input: PlanningInput, simple: Bool) throws -> [PlanningItem] {
        guard let chosen = candidates(pattern: .cardio, input: input, simple: simple).first else {
            throw CoreError.invalidInput("当前安排需要轻有氧日，但没有可用安全步行空间或适合的有氧器械。请补充可用条件、调整星期或手动创建。")
        }
        let cap = input.experience == .regular ? 30 : 15
        var minutes = min(cap, max(5, input.minutesPerSession - 8))
        var item = PlanningItem(exerciseID: chosen.id, setCount: 1, targetReps: nil, targetSeconds: Double(minutes * 60), restSeconds: 0,
                                notes: ["强度以能舒适交谈为起点，记录实际时长；没有距离就不生成速度。", "准备和结束时逐渐加快/放慢；出现异常不适停止。"])
        while minutes > 5, timeRange(items: [item]).upper > input.minutesPerSession {
            minutes -= 1; item.targetSeconds = Double(minutes * 60)
        }
        guard timeRange(items: [item]).upper <= input.minutesPerSession else { throw CoreError.invalidInput("有氧准备与缓和后仍超过时间预算，请增加可用时间。") }
        return [item]
    }

    static func candidates(pattern: Pattern, input: PlanningInput, simple: Bool) -> [Movement] {
        var ranks: [String]
        switch pattern {
        case .squat: ranks = simple ? ["bodyweight-squat", "box-squat", "goblet-squat", "leg-press"] : ["leg-press", "goblet-squat", "bodyweight-squat", "box-squat"]
        case .hinge: ranks = simple || input.experience != .regular ? ["glute-bridge", "dumbbell-rdl"] : ["dumbbell-rdl", "glute-bridge"]
        case .push:
            let bodyweight = input.experience == .regular ? ["push-up", "incline-push-up", "knee-push-up"] : ["incline-push-up", "knee-push-up", "push-up"]
            ranks = simple ? bodyweight + ["dumbbell-bench-press"] : ["dumbbell-bench-press"] + bodyweight
        case .pull: ranks = simple ? ["band-pull-apart", "dumbbell-row", "seated-cable-row", "lat-pulldown"] : ["lat-pulldown", "seated-cable-row", "dumbbell-row", "band-pull-apart"]
        case .core: ranks = simple ? ["bird-dog", "dead-bug", "plank"] : ["dead-bug", "bird-dog", "plank"]
        case .cardio: ranks = simple ? ["walking", "stationary-cycling", "elliptical", "rowing-ergometer"] : ["stationary-cycling", "elliptical", "walking", "rowing-ergometer"]
        }
        switch pattern {
        case .squat: ranks += ["step-up", "dumbbell-front-squat"]
        case .hinge: ranks += ["kettlebell-deadlift"]
        case .push: ranks += ["dumbbell-floor-press"]
        case .core: ranks += ["high-plank", "pallof-press"]
        default: break
        }
        return ranks.compactMap { slug in movements.first { $0.id == "builtin.\(slug)" && $0.pattern == pattern } }
            .filter { !input.excludedExerciseIDs.contains($0.id) && isAvailable(exerciseID: $0.id, equipment: input.equipment)
                && (input.experience == .regular || $0.id != "builtin.rowing-ergometer") }
    }

    static func cyclicDistance(_ first: Int, _ second: Int) -> Int {
        let distance = abs(first - second)
        return min(distance, 7 - distance)
    }
}
