import Foundation

/// A model may suggest executable boundaries, but never health clearance or consent.
public struct ConstraintChatCandidate: Codable, Equatable, Sendable {
    public var excludedExerciseIDs: [String]
    public var avoidedPositions: [ConstraintAvoidance]
    public var excludedWeekdays: [Int]
    public var restDateKeys: [String]
    public var maxSessionMinutes: Int?
    public var allowedExerciseIDs: [String]?
    public var questions: [String]
    public var unresolved: [String]

    public init(excludedExerciseIDs: [String] = [], avoidedPositions: [ConstraintAvoidance] = [],
                excludedWeekdays: [Int] = [], restDateKeys: [String] = [], maxSessionMinutes: Int? = nil,
                allowedExerciseIDs: [String]? = nil, questions: [String] = [], unresolved: [String] = []) {
        self.excludedExerciseIDs = excludedExerciseIDs; self.avoidedPositions = avoidedPositions
        self.excludedWeekdays = excludedWeekdays; self.restDateKeys = restDateKeys
        self.maxSessionMinutes = maxSessionMinutes; self.allowedExerciseIDs = allowedExerciseIDs
        self.questions = questions; self.unresolved = unresolved
    }

    public func validate() throws {
        let supported = Set(PlannerEngine.supportedMovementIDs)
        guard excludedExerciseIDs.count <= supported.count, (allowedExerciseIDs?.count ?? 0) <= supported.count,
              (excludedExerciseIDs + (allowedExerciseIDs ?? [])).allSatisfy(supported.contains),
              excludedWeekdays.count <= 7, excludedWeekdays.allSatisfy({ (1...7).contains($0) }),
              restDateKeys.count <= 366, restDateKeys.allSatisfy(TrainingConstraintReview.isValidDateKey),
              avoidedPositions.count <= ConstraintAvoidance.allCases.count,
              maxSessionMinutes.map({ (15...120).contains($0) }) ?? true,
              questions.count <= 5, unresolved.count <= 20 else {
            throw CoreError.invalidInput("教练整理的动作、日期、时间或待问事项无效，请继续补充。")
        }
        try CoreValidation.unique(excludedExerciseIDs, name: "暂不安排的动作")
        try CoreValidation.unique(avoidedPositions, name: "避免姿势")
        try CoreValidation.unique(excludedWeekdays, name: "休息星期")
        try CoreValidation.unique(restDateKeys, name: "休息日期")
        for text in questions + unresolved { try CoreValidation.nonempty(text, name: "待了解事项", maxLength: 1_000) }
        if let allowedExerciseIDs {
            try CoreValidation.unique(allowedExerciseIDs, name: "明确允许动作")
            let excluded = Set(excludedExerciseIDs + avoidedPositions.flatMap(\.exerciseIDs))
            guard !allowedExerciseIDs.isEmpty, Set(allowedExerciseIDs).isDisjoint(with: excluded) else {
                throw CoreError.invalidInput("明确允许的动作不能为空，也不能同时要求避开。")
            }
        }
    }
}

public struct ConstraintChatMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, coach }
    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
    }
    public func validate() throws {
        try CoreValidation.nonempty(text, name: "对话内容", maxLength: 6_000)
        try CoreValidation.date(createdAt, name: "对话时间")
    }
}

/// Resumable working conversation. Only a human's final readback confirmation calls makeReview.
public struct ConstraintChatSession: Codable, Equatable, Sendable {
    public var sourceText: String { didSet { if sourceText != oldValue { invalidateReadback() } } }
    public var legacySourceText: String { didSet { if legacySourceText != oldValue { invalidateReadback() } } }
    public var messages: [ConstraintChatMessage]
    public var candidate: ConstraintChatCandidate?
    public var candidateEvidenceCount: Int?
    public var mode: ConstraintReviewMode?
    public var painFree: Bool?
    public var professionalNote: String
    public var confirmedAt: Date?
    /// Optional for decoding saved conversations made before this explicit answer timestamp existed.
    public var painFreeAnsweredAt: Date?
    public var restScopeConfirmed: Bool?

    public init(sourceText: String, legacySourceText: String = "", messages: [ConstraintChatMessage] = [],
                candidate: ConstraintChatCandidate? = nil, candidateEvidenceCount: Int? = nil,
                mode: ConstraintReviewMode? = nil, painFree: Bool? = nil, professionalNote: String = "",
                confirmedAt: Date? = nil, painFreeAnsweredAt: Date? = nil) {
        self.sourceText = sourceText; self.legacySourceText = legacySourceText; self.messages = messages
        self.candidate = candidate; self.candidateEvidenceCount = candidateEvidenceCount
        self.mode = mode; self.painFree = painFree; self.professionalNote = professionalNote
        self.confirmedAt = confirmedAt; self.painFreeAnsweredAt = painFreeAnsweredAt
        self.restScopeConfirmed = nil
    }

    public var userMessageCount: Int { messages.filter { $0.role == .user }.count }

    public mutating func appendUser(_ text: String, at date: Date = Date()) throws {
        var draft = self
        draft.messages.append(.init(role: .user, text: text, createdAt: date))
        draft.invalidateReadback()
        try draft.validate(); self = draft
    }
    public mutating func appendCoach(_ text: String, at date: Date = Date()) throws {
        var draft = self
        draft.messages.append(.init(role: .coach, text: text, createdAt: date))
        try draft.validate(); self = draft
    }
    public mutating func receiveCandidate(_ value: ConstraintChatCandidate, evidenceCount: Int, at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "整理时间")
        guard evidenceCount == userMessageCount, messages.allSatisfy({ $0.createdAt <= date }) else {
            throw CoreError.invalidState("你已补充新的情况，请按最新回复重新整理。")
        }
        try value.validate()
        var draft = self
        draft.candidate = value; draft.candidateEvidenceCount = evidenceCount; draft.confirmedAt = nil
        draft.restScopeConfirmed = nil
        try draft.validate(); self = draft
    }
    public mutating func setMode(_ value: ConstraintReviewMode?) {
        mode = value; confirmedAt = nil; restScopeConfirmed = nil
    }
    public mutating func setPainFree(_ value: Bool?, at date: Date = Date()) {
        painFree = value; painFreeAnsweredAt = value == nil ? nil : date; confirmedAt = nil
    }
    private mutating func invalidateReadback() {
        candidateEvidenceCount = nil; painFree = nil; painFreeAnsweredAt = nil; confirmedAt = nil; restScopeConfirmed = nil
    }

    public func validate() throws {
        guard sourceText.count <= 2_000, legacySourceText.count <= 2_000, professionalNote.count <= 2_000,
              messages.count <= 200 else { throw CoreError.invalidInput("注意事项对话过长，请保留原话后重新整理。") }
        for message in messages { try message.validate() }
        try CoreValidation.unique(messages.map(\.id), name: "注意事项对话ID")
        for pair in zip(messages, messages.dropFirst()) where pair.0.createdAt > pair.1.createdAt {
            throw CoreError.invalidInput("注意事项对话时间顺序无效。")
        }
        try candidate?.validate()
        if let count = candidateEvidenceCount {
            guard candidate != nil, count == userMessageCount else { throw CoreError.invalidState("整理结果对应的回复已变化。") }
        }
        if let confirmedAt { try CoreValidation.date(confirmedAt, name: "回读确认时间") }
        if let painFreeAnsweredAt { try CoreValidation.date(painFreeAnsweredAt, name: "本人状态回答时间") }
    }

    /// Does not save or activate a plan. Call only after displaying every readback line and a human tap.
    public func makeReview(at date: Date = Date()) throws -> TrainingConstraintReview {
        try validate()
        guard let candidate, candidateEvidenceCount == userMessageCount,
              let mode, painFree == true, let answeredAt = painFreeAnsweredAt,
              answeredAt <= date, Calendar.current.isDate(answeredAt, inSameDayAs: date),
              messages.allSatisfy({ $0.createdAt <= date }) else {
            throw CoreError.invalidState("先把当前问题聊清楚，并由你回答今天是否不适，再核对安排。")
        }
        if mode != .affectedDaysRest && (!candidate.questions.isEmpty || !candidate.unresolved.isEmpty) {
            throw CoreError.invalidState("还有事项未明确。可以继续说明，或由本人选择全部受影响时段先休息；不能把未知当作活动许可。")
        }
        if mode == .professionalBoundaries {
            try CoreValidation.nonempty(professionalNote, name: "本人记录的明确活动指导", maxLength: 2_000)
            guard let allowed = candidate.allowedExerciseIDs, !allowed.isEmpty else {
                throw CoreError.invalidState("还需明确专业指导允许哪些动作，教练不能替你给活动许可。")
            }
        }
        let review = TrainingConstraintReview(sourceText: sourceText, legacySourceText: legacySourceText, mode: mode,
            excludedWeekdays: candidate.excludedWeekdays, restDateKeys: candidate.restDateKeys,
            excludedExerciseIDs: candidate.excludedExerciseIDs, avoidedPositions: candidate.avoidedPositions,
            allowedExerciseIDs: candidate.allowedExerciseIDs, maxSessionMinutes: candidate.maxSessionMinutes,
            painFreeConfirmed: true, allLimitsRepresentedConfirmed: true,
            professionalGuidanceNote: professionalNote, confirmedAt: date,
            restScopeConfirmed: restScopeConfirmed,
            deferredClinicalQuestions: mode == .affectedDaysRest ? candidate.questions + candidate.unresolved : nil)
        try review.validate()
        return review
    }

    /// Deterministic execution summary; the model's prose cannot hide a restriction.
    public var readbackLines: [String] {
        guard let candidate else { return ["还在了解你的情况，尚未整理出安排。"] }
        guard (try? candidate.validate()) != nil else { return ["整理结果有误，请继续补充后重新整理。"] }
        func names(_ ids: [String]) -> String {
            ids.sorted().map { ExerciseCatalog.exercise(id: $0)?.name ?? $0 }.joined(separator: "、")
        }
        let days = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var lines: [String] = []
        if candidateEvidenceCount != userMessageCount { lines.append("你补充了新的情况，以下旧整理需要重新核对。") }
        lines.append(candidate.excludedWeekdays.isEmpty ? "每周没有额外指定的休息日，仍按你的可训练日期安排。" : "每逢" + candidate.excludedWeekdays.sorted().map { days[$0] }.joined(separator: "、") + "不安排训练。")
        lines.append(candidate.restDateKeys.isEmpty ? "没有额外指定的单次休息日期。" : "这些日期休息：" + candidate.restDateKeys.sorted().joined(separator: "、") + "。")
        lines.append(candidate.avoidedPositions.isEmpty ? "没有额外指定的姿势排除。" : candidate.avoidedPositions.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: "、") + "。")
        let excluded = Array(Set(candidate.excludedExerciseIDs + candidate.avoidedPositions.flatMap(\.exerciseIDs)))
        lines.append(excluded.isEmpty ? "没有额外排除具体动作；这不代表没有身体限制。" : "这些动作不加入计划：" + names(excluded) + "。")
        lines.append(candidate.maxSessionMinutes.map { "每次训练最多\($0)分钟。" } ?? "每次时长沿用已确认档案，没有额外缩短上限。")
        lines.append(candidate.allowedExerciseIDs.map { "只能从这些明确允许的动作中安排：" + names($0) + "。" } ?? "没有另设允许动作名单，仍受器械、能力和以上排除条件限制。")
        if let mode { lines.append("限制依据：" + mode.title + "。") }
        if !professionalNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("你记录的专业指导：" + professionalNote) }
        lines.append(painFree == true ? "你本轮回答：当前没有疼痛或异常不适。" : "还需你回答今天当前是否有疼痛或异常不适。")
        if mode == .affectedDaysRest {
            lines.append("所选休息日不安排任何正式训练，不推定这些时段可以做某个动作。")
            lines.append(restScopeConfirmed == true ? "本人确认：以下未明确事项仅影响所选休息时段，其他日期没有额外未说明限制。" : "尚未由本人确认未明确事项的影响范围。")
            lines += (candidate.questions + candidate.unresolved).map { "仅限休息时段、继续保留待确认：" + $0 }
        } else {
            lines += candidate.questions.map { "还需了解：" + $0 }
            lines += candidate.unresolved.map { "尚未明确：" + $0 }
        }
        return lines
    }
}
