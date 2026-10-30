import Foundation
import CryptoKit

/// The four kinds of change the coach may propose. They are deliberately different objects because
/// they have different lifetimes: `todayOnly` never touches the long-term plan.
public enum AdjustmentKind: String, Codable, Equatable, CaseIterable, Sendable {
    case keep, todayOnly, progressive, cycleReview

    public var title: String {
        switch self {
        case .keep: return "保持原计划"
        case .todayOnly: return "只调整今天"
        case .progressive: return "渐进调整动作负荷"
        case .cycleReview: return "周期重新评估"
        }
    }

    public var isLongTerm: Bool { self == .progressive || self == .cycleReview }
}

public enum AdjustmentDecision: String, Codable, Equatable, Sendable {
    case pending, accepted, rejected

    public var title: String {
        switch self {
        case .pending: return "待本人确认"
        case .accepted: return "已确认生效"
        case .rejected: return "已拒绝，原计划不变"
        }
    }
}

/// One proposed change with everything needed to judge it: what triggers it, what it changes, and
/// which stored facts it relies on.
public struct AdjustmentProposal: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var kind: AdjustmentKind
    /// The plan version this proposal was written against. If it is no longer current, the proposal
    /// lapses instead of being applied to something else.
    public var basePlanVersionID: UUID?
    public var reason: String
    public var evidenceIDs: [String]
    public var summary: String
    /// Only for `todayOnly`: the single-day execution snapshot to use today.
    public var todayItems: [PlannedExercise]?
    /// Only for long-term kinds: the replacement items that would form a new version.
    public var proposedItems: [PlannedExercise]?
    public var decision: AdjustmentDecision
    /// Set when accepted; the version actually created or activated.
    public var appliedPlanVersionID: UUID?
    /// A today-only proposal is consumed by exactly one saved workout. Older backups omit this.
    public var appliedSessionID: UUID?
    /// Fingerprint of the data this was based on, so later changes can invalidate it.
    public var basedOn: AdjustmentFingerprint

    public init(id: UUID = UUID(), createdAt: Date = Date(), kind: AdjustmentKind,
                basePlanVersionID: UUID? = nil, reason: String, evidenceIDs: [String] = [],
                summary: String, todayItems: [PlannedExercise]? = nil,
                proposedItems: [PlannedExercise]? = nil,
                decision: AdjustmentDecision = .pending,
                appliedPlanVersionID: UUID? = nil,
                appliedSessionID: UUID? = nil,
                basedOn: AdjustmentFingerprint = AdjustmentFingerprint()) {
        self.id = id; self.createdAt = createdAt; self.kind = kind
        self.basePlanVersionID = basePlanVersionID; self.reason = reason
        self.evidenceIDs = evidenceIDs; self.summary = summary
        self.todayItems = todayItems; self.proposedItems = proposedItems
        self.decision = decision; self.appliedPlanVersionID = appliedPlanVersionID
        self.basedOn = basedOn
        self.appliedSessionID = appliedSessionID
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "建议时间")
        try CoreValidation.nonempty(reason, name: "调整原因", maxLength: 2_000)
        try CoreValidation.nonempty(summary, name: "调整说明", maxLength: 2_000)
        guard evidenceIDs.count <= 30, evidenceIDs.allSatisfy({ $0.count <= 200 }) else {
            throw CoreError.invalidInput("调整依据过多或过长。")
        }
        // A long-term change must record the version it created. A `todayOnly` change is applied as a
        // one-off snapshot and produces no long-term version, so it is accepted with none.
        if kind.isLongTerm {
            guard decision != .accepted || appliedPlanVersionID != nil else {
                throw CoreError.invalidState("已确认的长期调整必须记录生成的计划版本。")
            }
        } else {
            guard appliedPlanVersionID == nil else {
                throw CoreError.invalidState("只调整今天或保持原计划不会生成新的长期版本。")
            }
        }
        guard decision == .rejected || decision == .pending || decision == .accepted else {
            throw CoreError.invalidInput("调整建议的确认状态无效。")
        }
        try basedOn.validate()
        if appliedSessionID != nil, kind != .todayOnly || decision != .accepted {
            throw CoreError.invalidState("只有已确认的仅本次调整可以关联执行训练。")
        }
        switch kind {
        case .keep:
            guard todayItems == nil, proposedItems == nil else {
                throw CoreError.invalidInput("保持原计划不应携带具体改动。")
            }
        case .todayOnly:
            guard let items = todayItems, !items.isEmpty, proposedItems == nil else {
                throw CoreError.invalidInput("仅本次调整必须给出当天的动作，且不改长期版本。")
            }
            try CoreValidation.unique(items.map(\.id), name: "当天动作 ID")
            for item in items { try item.validate() }
        case .progressive, .cycleReview:
            guard let items = proposedItems, !items.isEmpty, todayItems == nil else {
                throw CoreError.invalidInput("长期调整必须给出新的动作版本。")
            }
            try CoreValidation.unique(items.map(\.id), name: "新版本动作 ID")
            for item in items { try item.validate() }
        }
    }
}

/// A cheap fingerprint of everything an adjustment depends on. When any part changes, an
/// unconfirmed proposal is stale and must be regenerated rather than applied.
public struct AdjustmentFingerprint: Codable, Equatable, Sendable {
    public var planVersionID: UUID?
    public var sessionRevisions: [String: Int]
    public var checkInID: UUID?
    public var healthCapturedAt: Date?
    public var profileDigest: String
    public var readinessVerdict: String?
    public var checkInDigest: String?
    public var sessionFeedbackDigest: String?
    public var readinessDigest: String?
    public var healthDigest: String?

    public init(planVersionID: UUID? = nil, sessionRevisions: [String: Int] = [:],
                checkInID: UUID? = nil, healthCapturedAt: Date? = nil,
                profileDigest: String = "", readinessVerdict: String? = nil,
                checkInDigest: String? = nil, sessionFeedbackDigest: String? = nil,
                readinessDigest: String? = nil, healthDigest: String? = nil) {
        self.planVersionID = planVersionID; self.sessionRevisions = sessionRevisions
        self.checkInID = checkInID; self.healthCapturedAt = healthCapturedAt
        self.profileDigest = profileDigest; self.readinessVerdict = readinessVerdict
        self.checkInDigest = checkInDigest; self.sessionFeedbackDigest = sessionFeedbackDigest
        self.readinessDigest = readinessDigest
        self.healthDigest = healthDigest
    }

    public func validate() throws {
        // The digest covers every interview topic, so it is bounded by the topic count, not a guess.
        guard sessionRevisions.count <= 20, sessionRevisions.values.allSatisfy({ $0 >= 0 }),
              sessionRevisions.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              profileDigest.count <= 2_000 else {
            throw CoreError.invalidInput("调整依据指纹无效。")
        }
        if let healthCapturedAt { try CoreValidation.date(healthCapturedAt, name: "健康数据时间") }
        for digest in [checkInDigest, sessionFeedbackDigest, readinessDigest, healthDigest].compactMap({ $0 }) {
            guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
                throw CoreError.invalidInput("调整依据的内容摘要无效。")
            }
        }
    }

    public static func digest(of profile: StructuredProfile) -> String {
        contentDigest(profile)
    }

    /// A deterministic content hash, never a copy of the user's private notes in the fingerprint.
    public static func contentDigest<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        guard let data = try? encoder.encode(value) else { return String(repeating: "0", count: 64) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AdjustmentEngine {
    public static let rulesVersion = "adjustment-1"

    /// A pending proposal is only applicable while every input it was written against is unchanged.
    public static func isStale(_ proposal: AdjustmentProposal, currently fingerprint: AdjustmentFingerprint,
                               now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let age = now.timeIntervalSince(proposal.createdAt)
        return age < -300 || age > 86_400 || !calendar.isDate(proposal.createdAt, inSameDayAs: now)
            || proposal.basedOn != fingerprint
    }

    public static func fingerprint(planVersionID: UUID?, sessions: [WorkoutSession],
                                   checkIn: PreWorkoutCheckIn?, health: HealthSnapshot?,
                                   profile: StructuredProfile,
                                   readiness: ReadinessAssessment?,
                                   sessionFeedback: [SessionFeedback] = []) -> AdjustmentFingerprint {
        let recent = sessions.sorted { $0.startedAt > $1.startedAt }.prefix(10)
        return AdjustmentFingerprint(
            planVersionID: planVersionID,
            sessionRevisions: Dictionary(uniqueKeysWithValues: recent.map { ($0.id.uuidString, $0.revision) }),
            checkInID: checkIn?.id,
            healthCapturedAt: health?.capturedAt,
            profileDigest: AdjustmentFingerprint.digest(of: profile),
            readinessVerdict: readiness?.verdict.rawValue,
            checkInDigest: checkIn.map { AdjustmentFingerprint.contentDigest($0) },
            sessionFeedbackDigest: AdjustmentFingerprint.contentDigest(sessionFeedback.sorted { $0.id.uuidString < $1.id.uuidString }),
            readinessDigest: readiness.map { value in
                var stable = value
                stable.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                stable.createdAt = Date(timeIntervalSince1970: 0)
                return AdjustmentFingerprint.contentDigest(stable)
            }, healthDigest: health.map { AdjustmentFingerprint.contentDigest($0) })
    }

    /// The one reduction the rules can offer today: every movement loses one set, never below one.
    /// Today's screen uses this only to decide whether a "less today" entry is worth showing; the
    /// proposal itself is still built and stored by `proposeForToday` on the review screen.
    public static func reductionPreview(items: [PlannedExercise]) -> [PlannedExercise] {
        items.map { item in
            var copy = item
            copy.setCount = max(1, item.setCount - 1)
            return copy
        }
    }

    /// Builds the conservative adjustment the rules allow for today, from a real readiness verdict.
    /// This never invents a load: it only reduces sets or keeps the plan.
    public static func proposeForToday(readiness: ReadinessAssessment, basePlan: PlanVersion?,
                                       fingerprint: AdjustmentFingerprint,
                                       createdAt: Date = Date(), availableMinutes: Int? = nil) throws -> AdjustmentProposal {
        try readiness.validate()
        switch readiness.verdict {
        case .stop:
            return AdjustmentProposal(createdAt: createdAt, kind: .keep,
                                      basePlanVersionID: basePlan?.id,
                                      reason: readiness.safety,
                                      evidenceIDs: readiness.evidence.map(\.id),
                                      summary: "今天不建议按原计划训练：\(readiness.todaySuggestion)",
                                      basedOn: fingerprint)
        case .normal, .conservative, .downgrade, .gatherData:
            guard let basePlan else {
                return AdjustmentProposal(createdAt: createdAt, kind: .keep, basePlanVersionID: nil,
                                          reason: "当前没有生效计划，因此没有可调整的长期安排。",
                                          evidenceIDs: readiness.evidence.map(\.id),
                                          summary: readiness.todaySuggestion, basedOn: fingerprint)
            }
            let minutes = availableMinutes.flatMap { (5...300).contains($0) ? $0 : nil }
            let needsTimeReduction = minutes.map { estimatedUpperMinutes(basePlan.items) > $0 } ?? false
            let shouldReduce = needsTimeReduction || readiness.verdict == .conservative || readiness.verdict == .downgrade
                || readiness.verdict == .gatherData
            guard shouldReduce else {
                return AdjustmentProposal(createdAt: createdAt, kind: .keep,
                                          basePlanVersionID: basePlan.id,
                                          reason: "状态评估显示可以按计划推进。",
                                          evidenceIDs: readiness.evidence.map(\.id),
                                          summary: "按已确认计划训练，记录实际结果。",
                                          basedOn: fingerprint)
            }
            var reduced = basePlan.items.map { item -> PlannedExercise in
                var copy = item
                copy.setCount = max(1, item.setCount - 1)
                return copy
            }
            if let minutes, needsTimeReduction {
                guard basePlan.items.allSatisfy({ $0.targetReps != nil || $0.targetSeconds != nil }) else {
                    return AdjustmentProposal(createdAt: createdAt, kind: .keep, basePlanVersionID: basePlan.id,
                        reason: "计划中有未知目标时长或次数，无法可靠估算今天的时间预算。",
                        evidenceIDs: readiness.evidence.map(\.id),
                        summary: "暂不自动生成时间可行方案。请先补充目标或手动安排，不代表建议按原计划全部完成。", basedOn: fingerprint)
                }
                while reduced.count > 1, estimatedUpperMinutes(reduced) > minutes { reduced.removeLast() }
                guard estimatedUpperMinutes(reduced) <= minutes else {
                    return AdjustmentProposal(createdAt: createdAt, kind: .keep, basePlanVersionID: basePlan.id,
                        reason: "包含准备和缓和的保守估时仍超过今天的可用时间。",
                        evidenceIDs: readiness.evidence.map(\.id),
                        summary: "今天不自动安排原训练的缩短版；可另选适合的轻度活动或重新安排训练时间，长期计划保持不变。", basedOn: fingerprint)
                }
            }
            // Only offer a change when it actually differs; otherwise say "keep".
            guard reduced != basePlan.items else {
                return AdjustmentProposal(createdAt: createdAt, kind: .keep,
                                          basePlanVersionID: basePlan.id,
                                          reason: "当前计划的组数已经是最低校准量，无法再降。",
                                          evidenceIDs: readiness.evidence.map(\.id),
                                          summary: readiness.todaySuggestion, basedOn: fingerprint)
            }
            return AdjustmentProposal(createdAt: createdAt, kind: .todayOnly,
                                      basePlanVersionID: basePlan.id,
                                      reason: readiness.todaySuggestion,
                                      evidenceIDs: readiness.evidence.map(\.id),
                                      summary: needsTimeReduction
                                        ? "按今天的时间预算减少组数并裁剪末尾动作；估时约\(estimatedUpperMinutes(reduced))分钟（含准备、休息与缓和），实际用时仍需记录。只用于下一次训练。"
                                        : "今天每个动作减少一组，只影响今天这次训练，不改变已确认的长期计划。",
                                      todayItems: reduced, basedOn: fingerprint)
        }
    }

    private static func estimatedUpperMinutes(_ items: [PlannedExercise]) -> Int {
        PlannerEngine.timeRange(items: items.map {
            PlanningItem(exerciseID: $0.exercise.id, setCount: $0.setCount, targetReps: $0.targetReps,
                         targetSeconds: $0.targetSeconds, restSeconds: $0.restSeconds, notes: [])
        }).upper
    }
}
