import Foundation

/// Deterministic weekly/monthly review. Every number here is computed from saved records; the AI may
/// narrate these figures but never produces them.
public struct ReviewSummary: Identifiable, Codable, Equatable, Sendable {
    public enum Period: String, Codable, Equatable, Sendable {
        case week, month

        public var title: String { self == .week ? "最近 7 天" : "最近 30 天" }
        public var days: Int { self == .week ? 7 : 30 }
    }

    public var id: UUID
    public var createdAt: Date
    public var period: Period
    public var windowStart: Date
    public var windowEnd: Date
    public var finishedSessionCount: Int
    public var plannedSessionCount: Int
    public var completedWorkingSets: Int
    public var totalTrainingSeconds: Double
    public var exerciseProgress: [ExerciseProgress]
    public var checkInCount: Int
    public var answeredPainCount: Int
    public var reportedPainCount: Int
    /// Honest statement about what this window could not measure.
    public var dataGaps: [String]
    public var rulesVersion: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), period: Period,
                windowStart: Date, windowEnd: Date, finishedSessionCount: Int = 0,
                plannedSessionCount: Int = 0, completedWorkingSets: Int = 0,
                totalTrainingSeconds: Double = 0, exerciseProgress: [ExerciseProgress] = [],
                checkInCount: Int = 0, answeredPainCount: Int = 0, reportedPainCount: Int = 0,
                dataGaps: [String] = [], rulesVersion: String = ReviewEngine.rulesVersion) {
        self.id = id; self.createdAt = createdAt; self.period = period
        self.windowStart = windowStart; self.windowEnd = windowEnd
        self.finishedSessionCount = finishedSessionCount; self.plannedSessionCount = plannedSessionCount
        self.completedWorkingSets = completedWorkingSets; self.totalTrainingSeconds = totalTrainingSeconds
        self.exerciseProgress = exerciseProgress; self.checkInCount = checkInCount
        self.answeredPainCount = answeredPainCount; self.reportedPainCount = reportedPainCount
        self.dataGaps = dataGaps; self.rulesVersion = rulesVersion
    }

    /// Completion rate is only meaningful when there was something planned.
    public var completionRateText: String {
        guard plannedSessionCount > 0 else { return "这段时间没有排期，无法计算完成率。" }
        let rate = Double(finishedSessionCount) / Double(plannedSessionCount) * 100
        return "计划 \(plannedSessionCount) 次，完成 \(finishedSessionCount) 次，约 \(Int(rate.rounded()))%。"
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "复盘时间")
        try CoreValidation.date(windowStart, name: "复盘开始时间")
        try CoreValidation.date(windowEnd, name: "复盘结束时间")
        guard windowStart < windowEnd else { throw CoreError.invalidInput("复盘时间范围无效。") }
        guard finishedSessionCount >= 0, plannedSessionCount >= 0, completedWorkingSets >= 0,
              checkInCount >= 0, answeredPainCount >= 0, reportedPainCount >= 0,
              reportedPainCount <= answeredPainCount, answeredPainCount <= checkInCount else {
            throw CoreError.invalidInput("复盘统计数字无效。")
        }
        try CoreValidation.finite(totalTrainingSeconds, name: "训练总时长")
        guard exerciseProgress.count <= 200, dataGaps.count <= 20,
              dataGaps.allSatisfy({ $0.count <= 500 }),
              rulesVersion == ReviewEngine.rulesVersion else {
            throw CoreError.invalidInput("复盘内容或规则版本无效。")
        }
        try CoreValidation.unique(exerciseProgress.map(\.exerciseID), name: "复盘动作 ID")
        for item in exerciseProgress { try item.validate() }
    }
}

/// Per-exercise progress. Only sessions that actually recorded a result are counted.
public struct ExerciseProgress: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var sessionCount: Int
    public var completedSetCount: Int
    /// Best recorded load in the window, when the user actually entered one.
    public var bestLoadKG: Double?
    public var bestReps: Int?
    public var bestDurationSeconds: Double?

    public init(exerciseID: String, sessionCount: Int = 0, completedSetCount: Int = 0,
                bestLoadKG: Double? = nil, bestReps: Int? = nil, bestDurationSeconds: Double? = nil) {
        self.exerciseID = exerciseID; self.sessionCount = sessionCount
        self.completedSetCount = completedSetCount; self.bestLoadKG = bestLoadKG
        self.bestReps = bestReps; self.bestDurationSeconds = bestDurationSeconds
    }

    public func validate() throws {
        guard ExerciseCatalog.exercise(id: exerciseID) != nil else {
            throw CoreError.missingReference("复盘动作 \(exerciseID)")
        }
        guard sessionCount >= 0, completedSetCount >= 0 else {
            throw CoreError.invalidInput("复盘动作统计为负。")
        }
        if let bestLoadKG { try CoreValidation.finite(bestLoadKG, name: "最佳重量") }
        if let bestReps, !(1...10_000).contains(bestReps) { throw CoreError.invalidInput("最佳次数无效。") }
        if let bestDurationSeconds {
            try CoreValidation.finite(bestDurationSeconds, name: "最佳持续时间", strictlyPositive: true)
        }
    }
}

public enum ReviewEngine {
    public static let rulesVersion = "review-1"

    public static func summarize(period: ReviewSummary.Period, sessions: [WorkoutSession],
                                 checkIns: [PreWorkoutCheckIn], plan: PlanVersion?,
                                 plannedDaysPerWeek: Int, now: Date = Date()) throws -> ReviewSummary {
        let windowStart = now.addingTimeInterval(-Double(period.days) * 86_400)
        let inWindow = sessions.filter { $0.startedAt >= windowStart && $0.startedAt <= now }
        let finished = inWindow.filter { !$0.status.isOngoing }
        var gaps: [String] = []
        if finished.isEmpty { gaps.append("这段时间没有已完成的训练记录。") }
        if checkIns.filter({ $0.createdAt >= windowStart }).isEmpty {
            gaps.append("这段时间没有训练前记录，无法评估主观状态变化。")
        }
        var progress: [String: ExerciseProgress] = [:]
        for session in finished {
            for movement in session.exercises {
                let completed = movement.sets.filter { $0.kind == .working && $0.isCompleted && !$0.skipped }
                guard !completed.isEmpty else { continue }
                var entry = progress[movement.exercise.id]
                    ?? ExerciseProgress(exerciseID: movement.exercise.id, sessionCount: 0, completedSetCount: 0)
                entry.sessionCount += 1
                entry.completedSetCount += completed.count
                for set in completed {
                    if let load = set.loadKG, load > (entry.bestLoadKG ?? -Double.infinity) { entry.bestLoadKG = load }
                    if let reps = set.reps, reps > (entry.bestReps ?? 0) { entry.bestReps = reps }
                    if let seconds = set.durationSeconds,
                       seconds > (entry.bestDurationSeconds ?? 0) { entry.bestDurationSeconds = seconds }
                }
                progress[movement.exercise.id] = entry
            }
        }
        let windowCheckIns = checkIns.filter { $0.createdAt >= windowStart && $0.createdAt <= now }
        let answeredPain = windowCheckIns.filter { $0.painReported != nil }
        let reportedPain = answeredPain.filter { $0.painReported == true }
        if !windowCheckIns.isEmpty, answeredPain.count < windowCheckIns.count {
            gaps.append("有 \(windowCheckIns.count - answeredPain.count) 次训练前记录没有回答疼痛，不能当作“没有疼痛”。")
        }
        let planned = plan == nil ? 0 : Int((Double(plannedDaysPerWeek) * Double(period.days) / 7).rounded())
        let summary = ReviewSummary(
            createdAt: now, period: period, windowStart: windowStart, windowEnd: now,
            finishedSessionCount: finished.count, plannedSessionCount: planned,
            completedWorkingSets: finished.reduce(0) { $0 + $1.completedWorkingSets },
            totalTrainingSeconds: finished.reduce(0) { $0 + $1.elapsed(at: now) },
            exerciseProgress: progress.values.sorted { $0.exerciseID < $1.exerciseID },
            checkInCount: windowCheckIns.count, answeredPainCount: answeredPain.count,
            reportedPainCount: reportedPain.count, dataGaps: gaps)
        try summary.validate()
        return summary
    }
}
