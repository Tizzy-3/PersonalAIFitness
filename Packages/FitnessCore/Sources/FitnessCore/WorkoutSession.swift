import Foundation

public struct LoggedSet: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: SetKind
    public var loadKG: Double?
    public var reps: Int?
    public var durationSeconds: Double?
    public var distanceMeters: Double?
    public var rpe: Double?
    public var rir: Int?
    public var completedAt: Date?
    public var skipped: Bool

    public init(id: UUID = UUID(), kind: SetKind = .working, loadKG: Double? = nil,
                reps: Int? = nil, durationSeconds: Double? = nil, distanceMeters: Double? = nil,
                rpe: Double? = nil, rir: Int? = nil, completedAt: Date? = nil, skipped: Bool = false) {
        self.id = id; self.kind = kind; self.loadKG = loadKG; self.reps = reps
        self.durationSeconds = durationSeconds; self.distanceMeters = distanceMeters
        self.rpe = rpe; self.rir = rir; self.completedAt = completedAt; self.skipped = skipped
    }

    public var isCompleted: Bool { completedAt != nil }

    public func validate(for exercise: Exercise, requireResult: Bool = false) throws {
        try exercise.validate()
        if let loadKG { try CoreValidation.finite(loadKG, name: "重量") }
        if let reps, !(1...10_000).contains(reps) { throw CoreError.invalidInput("次数应在 1 至 10000 之间。") }
        if let durationSeconds { try CoreValidation.finite(durationSeconds, name: "持续时间", strictlyPositive: true) }
        if let distanceMeters { try CoreValidation.finite(distanceMeters, name: "距离") }
        if let rpe, !rpe.isFinite || !(1...10).contains(rpe) { throw CoreError.invalidInput("RPE 应在 1 至 10 之间。") }
        if let rir, !(0...10).contains(rir) { throw CoreError.invalidInput("RIR 应在 0 至 10 之间。") }
        if let completedAt { try CoreValidation.date(completedAt, name: "组完成时间") }
        guard !skipped || !isCompleted else { throw CoreError.invalidInput("一组不能同时标记为跳过和完成。") }
        guard requireResult || isCompleted else { return }
        guard !skipped else { throw CoreError.invalidInput("请先取消跳过，再完成这一组。") }
        switch exercise.metric {
        case .repetitions:
            guard reps != nil else { throw CoreError.invalidInput("请填写实际完成次数。") }
            if exercise.kind == .strength && exercise.loadConvention != .bodyweight && loadKG == nil {
                throw CoreError.invalidInput("请填写实际重量；未知时不要用零代替。")
            }
        case .duration, .cardio:
            guard durationSeconds != nil else { throw CoreError.invalidInput("请填写实际训练时间。") }
        }
    }

    public func copied() -> LoggedSet {
        LoggedSet(kind: kind, loadKG: loadKG, reps: reps, durationSeconds: durationSeconds,
                  distanceMeters: distanceMeters)
    }
}

public struct WorkoutExercise: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var exercise: Exercise
    public var sets: [LoggedSet]
    public var restSeconds: Double
    public var note: String
    public var skipped: Bool

    public init(id: UUID = UUID(), exercise: Exercise, sets: [LoggedSet] = [],
                restSeconds: Double = 90, note: String = "", skipped: Bool = false) {
        self.id = id; self.exercise = exercise; self.sets = sets
        self.restSeconds = restSeconds; self.note = note; self.skipped = skipped
    }

    public func validate() throws {
        try exercise.validate()
        try CoreValidation.finite(restSeconds, name: "组间休息")
        guard restSeconds <= 86_400, sets.count <= 500, note.count <= 10_000 else {
            throw CoreError.invalidInput("动作记录超出支持范围。")
        }
        try CoreValidation.unique(sets.map(\.id), name: "组 ID")
        for set in sets { try set.validate(for: exercise) }
    }
}

public struct WorkoutSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sourcePlanVersionID: UUID?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var exercises: [WorkoutExercise]
    public var pausedAt: Date?
    public var accumulatedPauseSeconds: Double
    public var restEndsAt: Date?
    public var pausedRestSeconds: Double?
    public var revision: Int
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, sourcePlanVersionID: UUID? = nil,
                startedAt: Date = Date(), exercises: [WorkoutExercise] = []) {
        self.id = id; self.name = name; self.sourcePlanVersionID = sourcePlanVersionID
        self.startedAt = startedAt; self.exercises = exercises; endedAt = nil; status = .active
        pausedAt = nil; accumulatedPauseSeconds = 0; restEndsAt = nil; pausedRestSeconds = nil
        revision = 0; updatedAt = startedAt
    }

    public static func start(plan: PlanVersion, at: Date = Date()) throws -> WorkoutSession {
        try plan.validate()
        try CoreValidation.date(at, name: "训练开始时间")
        guard at >= plan.confirmedAt else { throw CoreError.invalidInput("训练开始时间早于计划确认时间，请检查系统时间。") }
        let entries = plan.items.map { item in
            WorkoutExercise(exercise: item.exercise, sets: (0..<item.setCount).map { _ in
                LoggedSet(reps: item.exercise.metric == .repetitions ? item.targetReps : nil,
                          durationSeconds: item.exercise.metric == .repetitions ? nil : item.targetSeconds)
            }, restSeconds: item.restSeconds)
        }
        let session = WorkoutSession(name: plan.name, sourcePlanVersionID: plan.id, startedAt: at, exercises: entries)
        try session.validate()
        return session
    }

    public var completedWorkingSets: Int {
        exercises.reduce(0) { total, exercise in
            total + exercise.sets.filter { $0.kind == .working && $0.isCompleted }.count
        }
    }

    public var plannedWorkingSets: Int {
        exercises.reduce(0) { $0 + $1.sets.filter { $0.kind == .working }.count }
    }

    public func elapsed(at: Date = Date()) -> TimeInterval {
        let effectiveEnd = endedAt ?? (status == .paused ? pausedAt : nil) ?? at
        let value = effectiveEnd.timeIntervalSince(startedAt) - accumulatedPauseSeconds
        return value.isFinite ? max(0, value) : 0
    }

    public func remainingRest(at: Date = Date()) -> TimeInterval {
        guard status.isOngoing else { return 0 }
        if status == .paused { return max(0, pausedRestSeconds ?? 0) }
        guard let restEndsAt else { return 0 }
        let value = restEndsAt.timeIntervalSince(at)
        return value.isFinite ? max(0, value) : 0
    }

    public mutating func pause(at: Date = Date()) throws {
        try requireActive(at: at)
        pausedRestSeconds = restEndsAt == nil ? nil : remainingRest(at: at)
        restEndsAt = nil; pausedAt = at; status = .paused
        touch(at: at)
    }

    public mutating func resume(at: Date = Date()) throws {
        guard status == .paused, let pausedAt else { throw CoreError.invalidState("只有暂停中的训练可以恢复。") }
        try requireMutationTime(at)
        guard at >= pausedAt else { throw CoreError.invalidInput("恢复时间早于暂停时间，请检查系统时间。") }
        accumulatedPauseSeconds += at.timeIntervalSince(pausedAt)
        if let remaining = pausedRestSeconds, remaining > 0 { restEndsAt = at.addingTimeInterval(remaining) }
        else { restEndsAt = nil }
        self.pausedAt = nil; pausedRestSeconds = nil; status = .active
        touch(at: at)
    }

    public mutating func finish(early: Bool, at: Date = Date()) throws {
        guard status.isOngoing else { throw CoreError.invalidState("这次训练已经结束，不能重复结束。") }
        try requireMutationTime(at)
        if let pausedAt {
            guard at >= pausedAt else { throw CoreError.invalidInput("结束时间早于暂停时间，请检查系统时间。") }
            accumulatedPauseSeconds += at.timeIntervalSince(pausedAt)
        }
        endedAt = at; status = early ? .endedEarly : .completed
        pausedAt = nil; pausedRestSeconds = nil; restEndsAt = nil
        touch(at: at)
    }

    public mutating func completeSet(exerciseID: UUID, setID: UUID, at: Date = Date()) throws {
        try requireActive(at: at)
        let (exerciseIndex, setIndex) = try locate(exerciseID: exerciseID, setID: setID)
        guard !exercises[exerciseIndex].skipped else { throw CoreError.invalidState("这个动作已跳过，请先取消跳过。") }
        // Repeated completion is a no-op: it must not duplicate a result or restart its rest timer.
        if exercises[exerciseIndex].sets[setIndex].isCompleted { return }
        try exercises[exerciseIndex].sets[setIndex].validate(for: exercises[exerciseIndex].exercise, requireResult: true)
        exercises[exerciseIndex].sets[setIndex].completedAt = at
        let rest = exercises[exerciseIndex].restSeconds
        restEndsAt = rest > 0 ? at.addingTimeInterval(rest) : nil
        touch(at: at)
    }

    public mutating func undoSet(exerciseID: UUID, setID: UUID, at: Date = Date()) throws {
        try requireActive(at: at)
        let (exerciseIndex, setIndex) = try locate(exerciseID: exerciseID, setID: setID)
        guard let completedAt = exercises[exerciseIndex].sets[setIndex].completedAt else { return }
        let mostRecent = exercises.flatMap(\.sets).compactMap(\.completedAt).max()
        exercises[exerciseIndex].sets[setIndex].completedAt = nil
        if mostRecent == completedAt { restEndsAt = nil }
        touch(at: at)
    }

    public func validate() throws {
        try CoreValidation.nonempty(name, name: "训练名称", maxLength: 100)
        try CoreValidation.date(startedAt, name: "训练开始时间")
        try CoreValidation.date(updatedAt, name: "训练更新时间")
        try CoreValidation.finite(accumulatedPauseSeconds, name: "暂停累计时间")
        guard updatedAt >= startedAt, revision >= 0, revision < Int.max, exercises.count <= 500 else {
            throw CoreError.invalidInput("训练时间、修订号或动作数量无效。")
        }
        if let endedAt {
            try CoreValidation.date(endedAt, name: "训练结束时间")
            guard endedAt >= startedAt, updatedAt >= endedAt else { throw CoreError.invalidInput("训练结束时间无效。") }
        }
        if let pausedAt {
            try CoreValidation.date(pausedAt, name: "暂停时间")
            guard pausedAt >= startedAt, pausedAt <= updatedAt else { throw CoreError.invalidInput("暂停时间无效。") }
        }
        if let restEndsAt { try CoreValidation.date(restEndsAt, name: "休息截止时间") }
        if let pausedRestSeconds { try CoreValidation.finite(pausedRestSeconds, name: "暂停时剩余休息") }
        switch status {
        case .active:
            guard endedAt == nil, pausedAt == nil, pausedRestSeconds == nil else { throw CoreError.invalidState("进行中的训练状态不一致。") }
        case .paused:
            guard endedAt == nil, pausedAt != nil, restEndsAt == nil else { throw CoreError.invalidState("暂停中的训练状态不一致。") }
        case .completed, .endedEarly:
            guard endedAt != nil, pausedAt == nil, restEndsAt == nil, pausedRestSeconds == nil else { throw CoreError.invalidState("已结束训练的状态不一致。") }
        }
        guard accumulatedPauseSeconds <= updatedAt.timeIntervalSince(startedAt) + 0.001 else {
            throw CoreError.invalidInput("累计暂停时间超过训练记录的时间范围。")
        }
        try CoreValidation.unique(exercises.map(\.id), name: "训练动作 ID")
        try CoreValidation.unique(exercises.flatMap(\.sets).map(\.id), name: "组 ID")
        for exercise in exercises {
            try exercise.validate()
            for set in exercise.sets {
                if let completed = set.completedAt {
                    guard completed >= startedAt, completed <= (endedAt ?? updatedAt) else {
                        throw CoreError.invalidInput("组完成时间超出这次训练的记录范围。")
                    }
                }
            }
        }
    }

    private func locate(exerciseID: UUID, setID: UUID) throws -> (Int, Int) {
        guard let exerciseIndex = exercises.firstIndex(where: { $0.id == exerciseID }) else { throw CoreError.notFound("训练动作") }
        guard let setIndex = exercises[exerciseIndex].sets.firstIndex(where: { $0.id == setID }) else { throw CoreError.notFound("训练组") }
        return (exerciseIndex, setIndex)
    }

    private func requireMutationTime(_ at: Date) throws {
        try CoreValidation.date(at, name: "操作时间")
        guard at >= updatedAt, at >= startedAt else { throw CoreError.invalidInput("操作时间早于最近记录，请检查系统时间。") }
        guard revision < Int.max - 1 else { throw CoreError.invalidState("训练修订号超出范围。") }
    }

    private func requireActive(at: Date) throws {
        guard status == .active else { throw CoreError.invalidState(status == .paused ? "请先恢复训练，再修改组记录。" : "已结束的训练不能直接修改。") }
        try requireMutationTime(at)
    }

    private mutating func touch(at: Date) { revision += 1; updatedAt = at }
}
