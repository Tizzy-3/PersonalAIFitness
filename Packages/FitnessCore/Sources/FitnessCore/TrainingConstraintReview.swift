import Foundation

public enum ConstraintReviewMode: String, Codable, CaseIterable, Sendable {
    case practicalOnly, professionalBoundaries, affectedDaysRest, gentleActivity
    public var title: String {
        switch self {
        case .practicalOnly: return "时间、能力或偏好限制"
        case .professionalBoundaries: return "已明确的专业活动指导"
        case .affectedDaysRest: return "受影响时段休息，未确定事项保留"
        case .gentleActivity: return "指定日期轻活动"
        }
    }
}

public enum ConstraintAvoidance: String, Codable, CaseIterable, Hashable, Sendable {
    case kneeling, floorWork
    public var title: String { self == .kneeling ? "避免跪姿" : "避免地面动作" }
    /// Explicitly reviewed identities in the prescription pool; never a fuzzy medical classifier.
    var exerciseIDs: [String] {
        switch self {
        case .kneeling: return ["builtin.knee-push-up", "builtin.bird-dog"]
        case .floorWork: return ["builtin.knee-push-up", "builtin.bird-dog", "builtin.push-up", "builtin.dead-bug", "builtin.plank", "builtin.high-plank", "builtin.glute-bridge", "builtin.dumbbell-floor-press"]
        }
    }
}

/// User-reviewed executable boundaries. This records the user's statements, not a medical clearance
/// invented by the model. Raw restriction texts remain intact and bind this review to its sources.
public struct TrainingConstraintReview: Codable, Equatable, Sendable {
    public var rulesVersion: String
    public var sourceText: String
    public var legacySourceText: String
    public var mode: ConstraintReviewMode
    public var excludedWeekdays: [Int]
    public var restDateKeys: [String]
    public var excludedExerciseIDs: [String]
    public var avoidedPositions: [ConstraintAvoidance]
    public var allowedExerciseIDs: [String]?
    public var maxSessionMinutes: Int?
    public var painFreeConfirmed: Bool
    public var allLimitsRepresentedConfirmed: Bool
    public var professionalGuidanceNote: String
    public var confirmedAt: Date
    public var restScopeConfirmed: Bool?
    public var deferredClinicalQuestions: [String]?
    public var temporaryActivity: TemporaryActivityConstraint?

    public init(sourceText: String, legacySourceText: String = "", mode: ConstraintReviewMode = .practicalOnly,
                excludedWeekdays: [Int] = [], restDateKeys: [String] = [], excludedExerciseIDs: [String] = [],
                avoidedPositions: [ConstraintAvoidance] = [], allowedExerciseIDs: [String]? = nil,
                maxSessionMinutes: Int? = nil, painFreeConfirmed: Bool = false,
                allLimitsRepresentedConfirmed: Bool = false, professionalGuidanceNote: String = "",
                confirmedAt: Date = Date(), rulesVersion: String = TrainingConstraintReview.currentRulesVersion,
                restScopeConfirmed: Bool? = nil, deferredClinicalQuestions: [String]? = nil,
                temporaryActivity: TemporaryActivityConstraint? = nil) {
        self.rulesVersion = rulesVersion; self.sourceText = sourceText; self.legacySourceText = legacySourceText; self.mode = mode
        self.excludedWeekdays = excludedWeekdays.sorted(); self.restDateKeys = restDateKeys.sorted()
        self.excludedExerciseIDs = excludedExerciseIDs.sorted(); self.avoidedPositions = avoidedPositions
        self.allowedExerciseIDs = allowedExerciseIDs?.sorted(); self.maxSessionMinutes = maxSessionMinutes
        self.painFreeConfirmed = painFreeConfirmed; self.allLimitsRepresentedConfirmed = allLimitsRepresentedConfirmed
        self.professionalGuidanceNote = professionalGuidanceNote; self.confirmedAt = confirmedAt
        self.restScopeConfirmed = restScopeConfirmed; self.deferredClinicalQuestions = deferredClinicalQuestions
        self.temporaryActivity = temporaryActivity
    }

    public static let currentRulesVersion = "training-constraints-3"
    public var effectiveExcludedExerciseIDs: [String] {
        Array(Set(excludedExerciseIDs + avoidedPositions.flatMap(\.exerciseIDs))).sorted()
    }
    public func allows(exerciseID: String) -> Bool {
        !effectiveExcludedExerciseIDs.contains(exerciseID) && (allowedExerciseIDs?.contains(exerciseID) ?? true)
    }

    public func validate() throws {
        try CoreValidation.date(confirmedAt, name: "训练约束确认时间")
        guard ["training-constraints-1", "training-constraints-2", Self.currentRulesVersion].contains(rulesVersion) else { throw CoreError.invalidInput("训练约束规则版本不受支持。") }
        if mode == .affectedDaysRest {
            guard ["training-constraints-2", Self.currentRulesVersion].contains(rulesVersion), restScopeConfirmed == true,
                  !excludedWeekdays.isEmpty || !restDateKeys.isEmpty,
                  let pending = deferredClinicalQuestions, !pending.isEmpty, pending.count <= 25 else {
                throw CoreError.invalidInput("请先选择全部受影响的休息日，并本人确认未明确事项仅限这些时段；其他日期也不确定时不能继续。")
            }
            for question in pending { try CoreValidation.nonempty(question, name: "休息日内保留的待确认事项", maxLength: 1_000) }
        }
        if mode == .gentleActivity {
            guard rulesVersion == Self.currentRulesVersion, let activity = temporaryActivity,
                  activity.lightActivityAllowed == true, activity.hasConcerningSymptoms == false,
                  !restDateKeys.contains(activity.dateKey),
                  activity.weekday.map({ !excludedWeekdays.contains($0) }) == true,
                  activity.excludedExerciseIDs == effectiveExcludedExerciseIDs else {
                throw CoreError.invalidInput("请先确认当天可以轻活动、当前身体状况及完整限制。")
            }
            try activity.validate()
        } else if temporaryActivity != nil {
            throw CoreError.invalidInput("临时活动限制与核对方式不一致。")
        }
        guard sourceText.count <= 2_000, legacySourceText.count <= 2_000,
              professionalGuidanceNote.count <= 2_000 else { throw CoreError.invalidInput("训练约束原文或说明过长。") }
        guard painFreeConfirmed else { throw CoreError.invalidInput("请本人确认当前没有疼痛或异常不适；有或不确定时先继续澄清。") }
        guard allLimitsRepresentedConfirmed else { throw CoreError.invalidInput("尚有未表达完整的限制，请先补充，不自动猜测训练许可。") }
        guard excludedWeekdays.count <= 7, excludedWeekdays.allSatisfy({ (1...7).contains($0) }),
              restDateKeys.count <= 366, restDateKeys.allSatisfy(Self.isValidDateKey),
              maxSessionMinutes.map({ (15...120).contains($0) }) ?? true else {
            throw CoreError.invalidInput("休息星期、明确日期或时长上限无效；短于15分钟时仍可手动安排。")
        }
        try CoreValidation.unique(excludedWeekdays, name: "休息星期")
        try CoreValidation.unique(restDateKeys, name: "休息日期")
        try CoreValidation.unique(avoidedPositions, name: "避免姿势")
        try CoreValidation.unique(excludedExerciseIDs, name: "约束排除动作")
        if let allowedExerciseIDs { try CoreValidation.unique(allowedExerciseIDs, name: "明确允许动作") }
        guard excludedExerciseIDs.count <= 1_000, (allowedExerciseIDs?.count ?? 0) <= 1_000 else {
            throw CoreError.invalidInput("训练约束的动作数量超出范围。")
        }
        for id in excludedExerciseIDs + (allowedExerciseIDs ?? []) where ExerciseCatalog.exercise(id: id) == nil {
            throw CoreError.missingReference("训练约束动作 \(id)")
        }
        if let allowedExerciseIDs {
            guard !allowedExerciseIDs.isEmpty, Set(allowedExerciseIDs).isDisjoint(with: effectiveExcludedExerciseIDs) else {
                throw CoreError.invalidInput("允许动作不能为空，也不能同时列为排除动作。")
            }
        }
        if mode == .professionalBoundaries {
            try CoreValidation.nonempty(professionalGuidanceNote, name: "本人记录的明确活动指导", maxLength: 2_000)
            guard let allowedExerciseIDs, !allowedExerciseIDs.isEmpty else {
                throw CoreError.invalidInput("涉及身体或治疗限制时，需要本人明确选择已获指导允许的动作；不能仅凭一段文字猜许可。")
            }
        }
    }

    /// Same civil day is a product confirmation policy, not an estimate of physiological recovery.
    public func isFresh(at date: Date, calendar: Calendar = .current) -> Bool {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        return confirmedAt <= date.addingTimeInterval(1) && civil.isDate(confirmedAt, inSameDayAs: date)
    }

    public static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        let parts = civil.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public func isRestDate(_ date: Date, calendar: Calendar = .current) -> Bool {
        var civil = Calendar(identifier: .gregorian); civil.timeZone = calendar.timeZone
        let weekday = ((civil.component(.weekday, from: date) + 5) % 7) + 1
        return excludedWeekdays.contains(weekday) || restDateKeys.contains(Self.dateKey(date, calendar: civil))
    }

    public static func isValidDateKey(_ value: String) -> Bool {
        guard value.count == 10, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }
}

public struct PlanningEligibility: Equatable, Sendable {
    public let canGenerate: Bool
    public let title: String
    public let message: String
    public let needsConstraintReview: Bool
    public init(canGenerate: Bool, title: String, message: String, needsConstraintReview: Bool = false) {
        self.canGenerate = canGenerate; self.title = title; self.message = message; self.needsConstraintReview = needsConstraintReview
    }
}

extension InterviewSession {
    public func planningEligibility(legacyRestrictions: String = "", at date: Date = Date(), snapshot: AppSnapshot? = nil) -> PlanningEligibility {
        guard profile.isReadyForPlanning else {
            return .init(canGenerate: false, title: "继续了解", message: "还需核对：" + profile.missingRequiredTopics.map(\.title).joined(separator: "、"))
        }
        guard pendingInferences.isEmpty, unansweredQuestions.isEmpty else {
            return .init(canGenerate: false, title: "待回答和核对", message: "先完成本轮回答，并确认或拒绝待核对的推断。")
        }
        guard !needsSafetyReview else {
            return .init(canGenerate: false, title: "待核对限制", message: "新的补充可能影响训练边界，请核对后再制定。", needsConstraintReview: true)
        }
        do {
            let input = try profile.planningInput(at: date)
            try input.validateLegacyRestrictions(legacyRestrictions, at: date)
            if let snapshot {
                if snapshot.sessions.contains(where: { $0.status.isOngoing }) {
                    return .init(canGenerate: false, title: "先完成当前训练", message: "先结束或取消正在进行的训练，再制定新的生效安排。")
                }
                do { try PlanningDraft.validateProfile(snapshot.profile, input: input, at: date) }
                catch { return .init(canGenerate: false, title: "待核对原档案", message: error.localizedDescription,
                                     needsConstraintReview: !TrainingConstraintReview.isNoRestrictionText(snapshot.profile.restrictions, allowingEmpty: true)) }
                do { try input.validateCurrentSafety(snapshot: snapshot, at: date) }
                catch { return .init(canGenerate: false, title: "待核对今日状态", message: error.localizedDescription) }
            }
            _ = try PlannerEngine.options(for: input)
            return .init(canGenerate: true, title: "可以生成计划", message: "资料和训练边界已核对；先生成草案，你确认后才生效。")
        } catch {
            let needsReview = profile.constraintReview != nil || !TrainingConstraintReview.isNoRestrictionText(profile.restrictions.value ?? "")
                || !TrainingConstraintReview.isNoRestrictionText(legacyRestrictions, allowingEmpty: true)
            return .init(canGenerate: false, title: needsReview ? "待核对训练约束" : "还需调整条件",
                         message: error.localizedDescription, needsConstraintReview: needsReview)
        }
    }

    public mutating func confirmConstraintReview(_ review: TrainingConstraintReview, at date: Date = Date()) throws {
        try review.validate()
        guard profile.restrictions.isUsable, review.sourceText == profile.restrictions.value,
              review.isFresh(at: date), date >= updatedAt else {
            throw CoreError.invalidState("限制原文或核对时间已变化，请重新查看并确认最新训练约束。")
        }
        let latestNarrative = (narratives ?? []).map(\.recordedAt).max()
        let latestSafetyAnswer = dialogueEvidence.filter { $0.topic == .restrictions && $0.answer.outcome == .answered }.map { $0.answer.answeredAt }.max()
        guard [latestNarrative, latestSafetyAnswer].compactMap({ $0 }).allSatisfy({ $0 <= review.confirmedAt }) else {
            throw CoreError.invalidState("核对后又有新的限制或补充，请基于最新情况重新确认。")
        }
        var draft = self
        draft.profile.constraintReview = review
        draft.profile.restrictions = draft.profile.restrictions.confirmed(at: review.confirmedAt)
        draft.updatedAt = date; draft.phase = draft.derivedPhase; draft.rulesVersion = InterviewRules.rulesVersion
        try draft.validate(); self = draft
    }
}

extension TrainingConstraintReview {
    static func isNoRestrictionText(_ text: String, allowingEmpty: Bool = false) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (allowingEmpty && value.isEmpty) || ["无", "无已知限制", "无运动限制", "没有已知限制", "none"].contains(value)
    }
}

extension PlanningInput {
    func allowsExercise(_ id: String) -> Bool {
        !excludedExerciseIDs.contains(id) && (constraintReview?.allows(exerciseID: id) ?? true)
    }
    public func allowsExerciseForPlanning(_ id: String) -> Bool { allowsExercise(id) }

    /// New drafts and pending confirmations respect contradictory evidence already recorded today.
    /// Historical frozen drafts validate against their creation time, not today's state.
    public func validateCurrentSafety(snapshot: AppSnapshot, at date: Date, calendar: Calendar = .current) throws {
        let latest = (snapshot.preWorkoutCheckIns ?? []).filter {
            $0.painReported != nil && $0.createdAt <= date && calendar.isDate($0.createdAt, inSameDayAs: date)
        }.max { $0.createdAt < $1.createdAt }
        if latest?.painReported == true {
            throw CoreError.invalidInput("今日训练前记录仍报告疼痛或异常，请先核对并更新今日记录，不能用约束确认覆盖。")
        }
        if let readiness = snapshot.latestReadiness, readiness.createdAt <= date,
           calendar.isDate(readiness.createdAt, inSameDayAs: date), readiness.safetyVerdict == .stop {
            throw CoreError.invalidInput("今日安全评估仍建议停止相关训练，请先核对或更新状态，不能用约束确认覆盖。")
        }
    }

    /// Both the original personal profile and the interview must be bound to the same review.
    func validateLegacyRestrictions(_ text: String, at date: Date) throws {
        if let review = constraintReview {
            guard review.legacySourceText == text, review.isFresh(at: date) else {
                throw CoreError.invalidInput("旧档案限制或今日状态已变化，请重新核对；不会以新声明覆盖原限制。")
            }
        } else if !TrainingConstraintReview.isNoRestrictionText(text, allowingEmpty: true) {
            throw CoreError.invalidInput("原档案仍有未核对的限制，请将它整理成可执行约束后再制定计划。")
        }
    }
}
