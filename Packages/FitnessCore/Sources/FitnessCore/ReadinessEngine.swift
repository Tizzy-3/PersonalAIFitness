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
              ["readiness-1", ReadinessEngine.rulesVersion].contains(rulesVersion) else {
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
    public static let rulesVersion = "readiness-2"

    /// Sleep below this many hours is treated as a recovery signal, not a diagnosis.
    static let shortSleepHours = 6.0
    /// Resting heart rate this many bpm above the personal baseline is flagged.
    static let restingHeartRateDelta = 7.0
    /// A metric needs at least this many samples before it is treated as a personal baseline.
    static let minimumBaselineSamples = 7

    /// Why today's plan cannot be presented as ready to start, if that is the case. `nil` means there
    /// is no safety question standing between the person and the plan.
    ///
    /// Today's screen uses this so a plan card can never sit next to a question it contradicts, and
    /// so the check-in only opens for a reason it can state out loud.
    public static func blockingQuestion(checkIn: PreWorkoutCheckIn?, profile: StructuredProfile,
                                        now: Date = Date(), calendar: Calendar = .current) -> String? {
        let restriction = profile.restrictions
        // "无 / 无已知限制 / none" are the strings the rest of the app treats as no restriction;
        // anything else the person confirmed is a real limit and must not be planned around.
        if restriction.isUsable, let text = restriction.value, DailyCoachBrief.hasRealRestriction(text) {
            return "档案里记有运动限制；本版不会自动绕过，请按专业建议安排。"
        }
        let today = checkIn.flatMap { calendar.isDate($0.createdAt, inSameDayAs: now) ? $0 : nil }
        return today?.painReported == nil ? "今天的疼痛情况还没有回答，不能当成“没问题”。" : nil
    }

    public static func assess(checkIn suppliedCheckIn: PreWorkoutCheckIn?,
                              health: HealthSnapshot?,
                              sessions: [WorkoutSession],
                              profile: StructuredProfile,
                              sessionFeedback: [SessionFeedback] = [],
                              now: Date = Date()) throws -> ReadinessAssessment {
        try profile.validate()
        try health?.validate()
        if let suppliedCheckIn { try suppliedCheckIn.validate() }
        let checkIn = suppliedCheckIn.flatMap {
            Calendar.current.isDate($0.createdAt, inSameDayAs: now) && $0.createdAt <= now.addingTimeInterval(300) ? $0 : nil
        }
        var evidence: [ReadinessEvidence] = []
        var limitations: [String] = []
        var recovery: [String] = []
        var recoveryConcern = false
        var safetyVerdict: ReadinessAssessment.Verdict = .normal
        var safety = "你今天明确报告没有疼痛。若情况变化，请停止可能加重症状的动作。"
        let painUnknown = checkIn?.painReported == nil
        if let checkIn {
            evidence.append(ReadinessEvidence(id: "checkin:\(checkIn.id.uuidString)", kind: .checkIn,
                                              label: "训练前自述", value: checkInSummary(checkIn), observedAt: checkIn.createdAt))
        }
        if checkIn?.painReported == true {
            safetyVerdict = .stop
            safety = "你报告了疼痛" + ((checkIn?.painAreas.isEmpty ?? true) ? "" : "（\(checkIn!.painAreas.joined(separator: "、"))）")
                + "。不要进行可能加重症状的训练，必要时寻求专业评估。"
        } else if painUnknown {
            safetyVerdict = .gatherData
            safety = checkIn == nil
                ? "今天还没有有效的训练前记录，疼痛与精力状态未知。"
                : "本次训练前的疼痛情况没有回答，不能当作没有疼痛。"
        }
        let restriction = profile.restrictions
        if restriction.isUsable, let text = restriction.value {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let noRestriction = Set(["无", "无已知限制", "无运动限制", "没有已知限制", "none"])
            evidence.append(ReadinessEvidence(id: "profile:restrictions", kind: .profile,
                                              label: "本人确认的运动限制", value: String(text.prefix(180)),
                                              observedAt: restriction.confirmedAt))
            if normalized.isEmpty {
                if safetyVerdict != .stop { safetyVerdict = .gatherData }
                limitations.append("运动限制内容为空，不能当作明确没有限制。")
            } else if !noRestriction.contains(normalized) {
                safetyVerdict = .stop
                safety = "档案中记有运动限制；本版没有医学限制适配能力，不根据其他良好数据自动放行。请按专业建议安排。"
            }
        } else {
            limitations.append("档案中的运动限制仍未确认；不能把未知或AI推断当作没有限制。")
            if safetyVerdict != .stop { safetyVerdict = .gatherData }
        }

        // Historical values can still be displayed in Health, but only currently valid samples
        // are evidence for today's recovery. Re-evaluate freshness even without another sync.
        let currentMetrics = health?.metrics.filter { $0.isCurrent(at: now) } ?? []
        for metric in currentMetrics {
            evidence.append(ReadinessEvidence(id: "health:\(metric.metric.rawValue)", kind: .healthMetric,
                                              label: metric.metric.title,
                                              value: metric.latestValue.map { describe($0, metric: metric.metric) },
                                              observedAt: metric.latestSampleAt))
        }
        if let sleep = currentMetrics.first(where: { $0.metric == .sleepAnalysis }), let hours = sleep.latestValue {
            if hours < shortSleepHours {
                recovery.append("最近一次睡眠约 \(format(hours)) 小时，低于 \(format(shortSleepHours)) 小时的产品参考线；这只是恢复信号，不是诊断。")
                recoveryConcern = true
            } else { recovery.append("最近一次睡眠约 \(format(hours)) 小时。") }
        } else { recovery.append("没有当前可用的睡眠数据，不能据此判断今天恢复。") }
        if let hrv = currentMetrics.first(where: { $0.metric == .heartRateVariabilitySDNN }), let value = hrv.latestValue {
            let count = hrv.sampleCountInWindow
            recovery.append(count < minimumBaselineSamples
                ? "HRV（SDNN）最新 \(format(value)) ms，只有 \(count) 条样本，还没形成个人基线，不用于判断恢复。"
                : "HRV（SDNN）最新 \(format(value)) ms。样本数量不等于已验证个人基线；不能当作RMSSD或单独下恢复结论。")
        }
        if let resting = currentMetrics.first(where: { $0.metric == .restingHeartRate }), let value = resting.latestValue {
            recovery.append("最新静息心率 \(format(value)) 次/分；尚无有效个人基线偏离分析，不把它单独当作恢复结论。")
        }
        let stale = health?.metrics.filter { $0.effectiveState(at: now) == .stale }.map(\.metric.title) ?? []
        if !stale.isEmpty { limitations.append("这些数据已过期，未用于今日恢复判断：\(stale.joined(separator: "、"))。") }
        if currentMetrics.isEmpty { recovery.append("尚无当前可用的健康数据，恢复证据不足。") }
        if let energy = checkIn?.energy, energy <= 2 {
            recovery.append("你自述今天精力 \(energy)/5，偏低。")
            recoveryConcern = true
        }
        if let level = checkIn?.sorenessLevel, level >= 4 {
            recovery.append("你自述明显酸痛 \(level)/5；先避免加重不适的动作，不做加量决定。")
            recoveryConcern = true
        }
        let timeLimited: Bool
        if let available = checkIn?.availableMinutes, profile.minutesPerSession.isUsable,
           let planned = profile.minutesPerSession.value, available < planned {
            timeLimited = true
            recovery.append("今天可用 \(available) 分钟，少于档案安排的 \(planned) 分钟；需要本人确认时间内的缩短方案。")
        } else { timeLimited = false }

        let finished = sessions.filter { !$0.status.isOngoing && $0.startedAt <= now }.sorted { $0.startedAt > $1.startedAt }
        let sessionIDs = Set(finished.map(\.id))
        let feedback = sessionFeedback.filter {
            sessionIDs.contains($0.sessionID) && $0.createdAt <= now && $0.createdAt >= now.addingTimeInterval(-7 * 86_400)
        }.sorted { $0.createdAt > $1.createdAt }
        if let latestFeedback = feedback.first {
            try latestFeedback.validate()
            var parts: [String] = []
            if latestFeedback.tooHard == true { parts.append("上次自述过难"); recoveryConcern = true }
            if let exertion = latestFeedback.perceivedExertion, exertion >= 9 {
                parts.append("上次主观用力 \(exertion)/10"); recoveryConcern = true
            }
            if latestFeedback.painReported == true {
                parts.append("上次训练后报告疼痛，需确认是否缓解"); recoveryConcern = true
            }
            if !parts.isEmpty {
                recovery.append(parts.joined(separator: "；") + "。")
                evidence.append(ReadinessEvidence(id: "feedback:\(latestFeedback.id.uuidString)", kind: .sessionHistory,
                                                  label: "真实训练后的本人反馈", value: parts.joined(separator: "；"),
                                                  observedAt: latestFeedback.createdAt))
            }
        }
        let window = finished.filter { $0.startedAt >= now.addingTimeInterval(-28 * 86_400) }
        let completedSets = window.reduce(0) { $0 + $1.completedWorkingSets }
        if let latest = finished.first {
            evidence.append(ReadinessEvidence(id: "session:\(latest.id.uuidString)", kind: .sessionHistory,
                                              label: "最近一次训练", value: String(latest.name.prefix(180)), observedAt: latest.startedAt))
        }
        let trend = finished.isEmpty ? "还没有已完成的训练记录，无法给出表现趋势。"
            : "近28天记录 \(window.count) 次已结束训练、\(completedSets) 个完成正式组；尚不足以单凭次数推断力量增长。"
        var known = 0
        if checkIn?.energy != nil { known += 1 }
        if checkIn?.painReported != nil { known += 1 }
        if !currentMetrics.isEmpty { known += 1 }
        if !finished.isEmpty { known += 1 }
        if profile.isReadyForPlanning { known += 1 }
        let level = min(5, known)
        let confidence = "已获得 \(level)/5 类信息（精力、疼痛、健康数据、训练历史、档案）；这是信息覆盖情况，不是恢复分数。"
        let verdict: ReadinessAssessment.Verdict
        let suggestion: String
        if safetyVerdict == .stop {
            verdict = .stop
            suggestion = "不要进行可能加重症状或违反运动限制的训练，请先按专业建议处理。"
        } else if painUnknown {
            verdict = .gatherData
            suggestion = "先明确今天是否疼痛，再决定如何执行；健康数据和历史表现不能替代这项安全回答。"
        } else if recoveryConcern || timeLimited {
            verdict = .conservative
            suggestion = timeLimited
                ? "今天时间不足或恢复证据偏弱，请先核对并确认缩短方案；不要直接照原训练量开训，任何改动只在确认后应用。"
                : "今天保守推进，不做加量决定；先查看减少训练量的建议，出现不适立即停止相关动作。"
        } else if safetyVerdict == .gatherData || level <= 2 {
            verdict = .gatherData
            suggestion = "尚缺足够的安全或恢复信息；先补充记录，不做加量决定，不把当前状态表述成正常。"
        } else {
            verdict = .normal
            suggestion = "现有记录未提示需要改变已确认安排；按计划记录实际结果，若状态变化再评估。"
        }
        let assessment = ReadinessAssessment(createdAt: now, safety: safety, safetyVerdict: safetyVerdict,
            recoveryEvidence: recovery, performanceTrend: trend, confidence: confidence, confidenceLevel: level,
            todaySuggestion: suggestion, verdict: verdict, evidence: evidence,
            limitations: limitations + ["规则阈值是保守产品策略，未验证为个人最佳处方；不构成医学诊断或表现预测。"])
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
        case .workoutDuration: return "\(Int(value.rounded())) 分钟"
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
