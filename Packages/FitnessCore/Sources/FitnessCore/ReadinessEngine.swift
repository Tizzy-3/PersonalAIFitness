import Foundation

/// One piece of real evidence behind a readiness statement. Every claim in the assessment points at
/// one of these, and an id has to exist before it can be referenced.
public struct ReadinessEvidence: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case checkIn, sessionHistory, healthMetric, profile, trainingLoad
    }

    public var id: String
    public var kind: Kind
    public var label: String
    public var value: String?
    public var observedAt: Date?

    public init(id: String, kind: Kind, label: String, value: String? = nil, observedAt: Date? = nil) {
        self.id = id; self.kind = kind; self.label = label
        self.value = value; self.observedAt = observedAt
    }

    public func validate() throws {
        try CoreValidation.nonempty(id, name: "依据 ID", maxLength: 200)
        try CoreValidation.nonempty(label, name: "依据说明", maxLength: 200)
        guard (value?.count ?? 0) <= 200 else { throw CoreError.invalidInput("依据内容过长。") }
        if let observedAt { try CoreValidation.date(observedAt, name: "依据时间") }
    }
}

/// The six parts the user sees. There is deliberately no combined "readiness score": a single number
/// would hide which part is missing or contradictory.
public struct ReadinessAssessment: Identifiable, Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Equatable, Sendable {
        case stop, downgrade, conservative, normal, gatherData

        public var title: String {
            switch self {
            case .stop: return "建议停止相关训练并寻求专业意见"
            case .downgrade: return "建议明显降级或改做轻量活动"
            case .conservative: return "可以训练，但保守推进"
            case .normal: return "按已确认计划推进"
            case .gatherData: return "数据不足，先按保守方案并补记录"
            }
        }
    }

    public var id: UUID
    public var createdAt: Date
    /// 1) Safety always wins and is stated first.
    public var safety: String
    public var safetyVerdict: Verdict
    /// 2) Recovery evidence, with explicit confidence instead of a synthetic score.
    public var recoveryEvidence: [String]
    /// 3) Performance trend from real recorded sessions.
    public var performanceTrend: String
    /// 4) How much of this is actually supported by data.
    public var confidence: String
    public var confidenceLevel: Int
    /// 5) The suggestion itself.
    public var todaySuggestion: String
    public var verdict: Verdict
    /// 6) The evidence every statement above refers to.
    public var evidence: [ReadinessEvidence]
    public var limitations: [String]
    public var rulesVersion: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), safety: String,
                safetyVerdict: Verdict = .normal, recoveryEvidence: [String] = [],
                performanceTrend: String = "", confidence: String = "",
                confidenceLevel: Int = 0, todaySuggestion: String = "",
                verdict: Verdict = .gatherData, evidence: [ReadinessEvidence] = [],
                limitations: [String] = [],
                rulesVersion: String = ReadinessEngine.rulesVersion) {
        self.id = id; self.createdAt = createdAt; self.safety = safety
        self.safetyVerdict = safetyVerdict; self.recoveryEvidence = recoveryEvidence
        self.performanceTrend = performanceTrend; self.confidence = confidence
        self.confidenceLevel = confidenceLevel; self.todaySuggestion = todaySuggestion
        self.verdict = verdict; self.evidence = evidence; self.limitations = limitations
        self.rulesVersion = rulesVersion
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "状态评估时间")
        try CoreValidation.nonempty(safety, name: "安全说明", maxLength: 1_000)
        try CoreValidation.nonempty(todaySuggestion, name: "今日建议", maxLength: 2_000)
        try CoreValidation.nonempty(confidence, name: "可信度说明", maxLength: 1_000)
        guard recoveryEvidence.count <= 20, limitations.count <= 20,
              (0...5).contains(confidenceLevel),
              recoveryEvidence.allSatisfy({ $0.count <= 1_000 }),
              limitations.allSatisfy({ $0.count <= 1_000 }),
              rulesVersion == ReadinessEngine.rulesVersion else {
            throw CoreError.invalidInput("状态评估内容或规则版本无效。")
        }
        try CoreValidation.unique(evidence.map(\.id), name: "状态依据 ID")
        for item in evidence { try item.validate() }
        // An evidence-free "all good" verdict is exactly the failure mode this design forbids.
        if verdict == .normal, evidence.isEmpty {
            throw CoreError.invalidInput("没有真实依据时不能给出“一切正常”的结论。")
        }
        if safetyVerdict == .stop, verdict != .stop {
            throw CoreError.invalidState("安全结论要求停止时，今日建议不能是继续训练。")
        }
    }
}

/// Builds a readiness assessment from real stored data only.
public enum ReadinessEngine {
    public static let rulesVersion = "readiness-1"

    /// Sleep below this many hours is treated as a recovery signal, not a diagnosis.
    static let shortSleepHours = 6.0
    /// Resting heart rate this many bpm above the personal baseline is flagged.
    static let restingHeartRateDelta = 7.0
    /// A metric needs at least this many samples before it is treated as a personal baseline.
    static let minimumBaselineSamples = 7

    public static func assess(checkIn: PreWorkoutCheckIn?,
                              health: HealthSnapshot?,
                              sessions: [WorkoutSession],
                              profile: StructuredProfile,
                              now: Date = Date()) throws -> ReadinessAssessment {
        var evidence: [ReadinessEvidence] = []
        var limitations: [String] = []
        var recovery: [String] = []

        // 1) Safety first: pain blocks everything else, including good recovery numbers.
        var safetyVerdict: ReadinessAssessment.Verdict = .normal
        var safety = "你没有报告疼痛或急性不适。若有变化，以现场感觉为准并停止相关动作。"
        if let checkIn {
            evidence.append(ReadinessEvidence(id: "checkin:\(checkIn.id.uuidString)", kind: .checkIn,
                                              label: "训练前自述",
                                              value: checkInSummary(checkIn),
                                              observedAt: checkIn.createdAt))
            if checkIn.painReported == true {
                safetyVerdict = .stop
                safety = "你报告了疼痛" + (checkIn.painAreas.isEmpty ? "" : "（\(checkIn.painAreas.joined(separator: "、"))）")
                    + "。安全优先：不要进行可能加重症状的训练，必要时寻求专业评估。"
            } else if checkIn.painReported == nil {
                safetyVerdict = .gatherData
                safety = "本次训练前的疼痛情况没有回答，因此不能当作“没有疼痛”。以下结论按不完整信息给出。"
            }
        } else {
            safetyVerdict = .gatherData
            safety = "今天还没有做训练前记录，因此疼痛与精力状态未知，不作为“状态良好”处理。"
        }
        if profile.provenance(of: .restrictions) == .unknown {
            limitations.append("档案中的运动限制仍为未知；存在限制时应按专业建议安排。")
        }

        // 2) Recovery evidence from real HealthKit data, never invented.
        if let health {
            for metric in health.metrics where metric.state.isUsable {
                evidence.append(ReadinessEvidence(id: "health:\(metric.metric.rawValue)", kind: .healthMetric,
                                                  label: metric.metric.title,
                                                  value: metric.latestValue.map { describe($0, metric: metric.metric) },
                                                  observedAt: metric.latestSampleAt))
            }
            if let sleep = health.snapshot(for: .sleepAnalysis), sleep.state.isUsable,
               let hours = sleep.latestValue, hours > 0 {
                if hours < shortSleepHours {
                    recovery.append("最近一次睡眠约 \(format(hours)) 小时，低于 \(format(shortSleepHours)) 小时的参考线。这只作为恢复信号，不是医学判断。")
                    if safetyVerdict == .normal { safetyVerdict = .conservative }
                } else {
                    recovery.append("最近一次睡眠约 \(format(hours)) 小时。")
                }
            } else {
                recovery.append("没有可用的睡眠数据，恢复情况未知。")
            }
            if let hrv = health.snapshot(for: .heartRateVariabilitySDNN) {
                if hrv.state.isUsable, let value = hrv.latestValue {
                    if hrv.sampleCountInWindow < minimumBaselineSamples {
                        recovery.append("HRV（SDNN）最新 \(format(value))，样本只有 \(hrv.sampleCountInWindow) 条，还没形成个人基线，不用于判断恢复。")
                    } else {
                        recovery.append("HRV（SDNN）最新 \(format(value))。这是 SDNN，不能当作 RMSSD，也不单独下结论。")
                    }
                } else {
                    recovery.append("没有可用的 HRV 数据。")
                }
            }
            if let resting = health.snapshot(for: .restingHeartRate), resting.state.isUsable,
               let value = resting.latestValue {
                recovery.append("最新静息心率 \(format(value)) 次/分。只有与你的个人基线比较才有意义，本版不生成偏离结论。")
            }
            let stale = health.metrics.filter { $0.state == .stale }.map(\.metric.title)
            if !stale.isEmpty { limitations.append("这些数据已过期：\(stale.joined(separator: "、"))。") }
            if health.usableMetrics.isEmpty {
                recovery.append("本次没有任何可用的健康数据。")
            }
        } else {
            recovery.append("尚未读取 Apple 健康数据，恢复证据缺失。")
            limitations.append("没有健康数据时，任何恢复结论都不成立。")
        }

        // 3) Performance trend from the user's own finished sessions.
        let finished = sessions.filter { !$0.status.isOngoing }.sorted { $0.startedAt > $1.startedAt }
        let window = finished.filter { $0.startedAt >= now.addingTimeInterval(-28 * 86_400) }
        let completedSets = window.reduce(0) { $0 + $1.completedWorkingSets }
        if let latest = finished.first {
            evidence.append(ReadinessEvidence(id: "session:\(latest.id.uuidString)", kind: .sessionHistory,
                                              label: "最近一次训练", value: latest.name, observedAt: latest.startedAt))
        }
        let trend = finished.isEmpty
            ? "还没有已完成的训练记录，无法给出表现趋势。"
            : "近 28 天完成 \(window.count) 次训练、\(completedSets) 个正式组；最近一次是 "
              + DateFormatter.localizedString(from: finished[0].startedAt, dateStyle: .medium, timeStyle: .short)
              + "。本版不推断力量增长曲线。"

        // 4) Confidence reflects how much is actually known.
        var known = 0
        if checkIn?.energy != nil { known += 1 }
        if checkIn?.painReported != nil { known += 1 }
        if !(health?.usableMetrics.isEmpty ?? true) { known += 1 }
        if !finished.isEmpty { known += 1 }
        if profile.isReadyForPlanning { known += 1 }
        let level = min(5, known)
        let confidenceText = "已获得 \(level)/5 项独立信息（训练前自述、疼痛、健康数据、训练历史、档案）。"
            + (level <= 2 ? "信息偏少，结论只作保守参考。" : "")

        // 5) The suggestion. Missing data can only lead to a conservative recommendation.
        var verdict: ReadinessAssessment.Verdict
        var suggestion: String
        if safetyVerdict == .stop {
            verdict = .stop
            suggestion = "今天不建议进行可能加重症状的训练。请优先休息并视情况寻求专业意见。"
        } else if safetyVerdict == .gatherData && level <= 2 {
            verdict = .gatherData
            suggestion = "先补一次训练前记录（精力、酸痛、疼痛、可用时间），再决定强度；在此之前按保守方案或轻量活动。"
        } else if safetyVerdict == .conservative || recovery.contains(where: { $0.contains("低于") }) {
            verdict = .conservative
            suggestion = "可以按计划训练，但把强度降一档：减少组数或保持明显余力，出现异常立即停止。"
        } else if level <= 2 {
            verdict = .gatherData
            suggestion = "数据不足，先按保守方案训练并记录实际结果，不做加量决定。"
        } else {
            verdict = .normal
            suggestion = "按已确认的计划推进，记录实际组数与感受；需要改动时以记录为准。"
        }
        if verdict == .normal, evidence.isEmpty {
            verdict = .gatherData
            suggestion = "没有足够依据判断状态，先按保守方案训练。"
        }
        if let checkIn, let energy = checkIn.energy, energy <= 2 {
            recovery.append("你自述今天精力 \(energy)/5，偏低。")
            if verdict == .normal { verdict = .conservative }
        }

        let assessment = ReadinessAssessment(
            createdAt: now, safety: safety, safetyVerdict: safetyVerdict,
            recoveryEvidence: recovery, performanceTrend: trend, confidence: confidenceText,
            confidenceLevel: level, todaySuggestion: suggestion, verdict: verdict,
            evidence: evidence,
            limitations: limitations + ["这是个人使用参考，不是医学诊断，也不保证预测表现。"])
        try assessment.validate()
        return assessment
    }

    public static func describe(_ value: Double, metric: HealthMetric) -> String {
        switch metric {
        case .stepCount: return "\(Int(value.rounded())) 步"
        case .restingHeartRate: return "\(Int(value.rounded())) 次/分"
        case .heartRateVariabilitySDNN: return "\(Int(value.rounded())) ms"
        case .sleepAnalysis: return "\(format(value)) 小时"
        case .activeEnergy: return "\(Int(value.rounded())) 千卡"
        case .bodyMass: return String(format: "%.1f kg", value)
        case .workoutDuration: return "\(Int((value / 60).rounded())) 分钟"
        case .cardioFitness: return String(format: "%.1f mL/kg/min", value)
        }
    }

    public static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    static func checkInSummary(_ checkIn: PreWorkoutCheckIn) -> String {
        var parts: [String] = []
        if let energy = checkIn.energy { parts.append("精力 \(energy)/5") } else { parts.append("精力未答") }
        if let pain = checkIn.painReported { parts.append(pain ? "有疼痛" : "无疼痛") } else { parts.append("疼痛未答") }
        if let level = checkIn.sorenessLevel { parts.append("酸痛 \(level)/5") }
        if let minutes = checkIn.availableMinutes { parts.append("可用 \(minutes) 分钟") }
        return parts.joined(separator: " · ")
    }
}
