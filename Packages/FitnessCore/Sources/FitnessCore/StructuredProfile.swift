import Foundation

/// Where one profile value came from. Only the first three may feed a generated plan; an
/// inference has to be confirmed by the user before it can.
public enum ProfileProvenance: String, Codable, Equatable, CaseIterable, Sendable {
    case stated        // the user answered this directly during the interview
    case confirmed     // the user reviewed and confirmed it (including a confirmed inference)
    case healthSource  // read from Apple Health, with its own sample source and time
    case inferred      // suggested by the AI and not confirmed yet
    case unknown       // explicitly unknown — this is NOT the same as "none"

    public var title: String {
        switch self {
        case .stated: return "本人回答"
        case .confirmed: return "本人确认"
        case .healthSource: return "健康数据"
        case .inferred: return "待确认的推断"
        case .unknown: return "未知"
        }
    }

    /// A planning input may only use values the user actually stands behind.
    public var isUsableForPlanning: Bool {
        switch self {
        case .stated, .confirmed, .healthSource: return true
        case .inferred, .unknown: return false
        }
    }
}

/// One profile value plus its provenance. A value with provenance `unknown` must stay `nil`, and an
/// unconfirmed inference must never be promoted silently.
public struct ProfileField<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value?
    public var provenance: ProfileProvenance
    public var confirmedAt: Date?
    public var note: String?

    public init(value: Value? = nil, provenance: ProfileProvenance = .unknown,
                confirmedAt: Date? = nil, note: String? = nil) {
        self.value = value
        self.provenance = provenance
        self.confirmedAt = confirmedAt
        self.note = note
    }

    public static var unknown: ProfileField { ProfileField() }

    public var isUsable: Bool { value != nil && provenance.isUsableForPlanning }

    /// Confirming always produces `.confirmed` with a fresh timestamp, whatever the source was.
    public func confirmed(at date: Date) -> ProfileField {
        ProfileField(value: value, provenance: value == nil ? .unknown : .confirmed,
                     confirmedAt: value == nil ? nil : date, note: note)
    }

    public func asInference(note: String?) -> ProfileField {
        ProfileField(value: value, provenance: value == nil ? .unknown : .inferred, confirmedAt: nil, note: note)
    }

    public func validate(name: String) throws {
        if let confirmedAt { try CoreValidation.date(confirmedAt, name: "\(name)的确认时间") }
        if provenance == .unknown {
            guard value == nil, confirmedAt == nil else {
                throw CoreError.invalidInput("\(name)被标记为未知，却带有具体内容或确认时间。")
            }
            return
        }
        guard value != nil else { throw CoreError.invalidInput("\(name)有来源标记但没有实际内容。") }
        if provenance == .inferred {
            guard confirmedAt == nil else { throw CoreError.invalidInput("\(name)还是待确认的推断，不能带有确认时间。") }
        } else {
            guard confirmedAt != nil else { throw CoreError.invalidInput("\(name)缺少确认时间。") }
        }
        if let note, note.count > 1_000 { throw CoreError.invalidInput("\(name)的说明过长。") }
    }
}

/// The structured profile an interview produces. Every field carries its own provenance so a guess
/// can never be mistaken for a fact.
public struct StructuredProfile: Codable, Equatable, Sendable {
    /// The user's own confirmation that they are 18 or older. Never assumed.
    public var ageYears: ProfileField<Int>
    public var heightCM: ProfileField<Double>
    public var weightKG: ProfileField<Double>
    public var adultStatus: ProfileField<Bool>
    public var primaryGoal: ProfileField<PlanningGoal>
    public var secondaryGoals: ProfileField<[PlanningGoal]>
    public var experience: ProfileField<PlanningExperience>
    /// The user's own description of current ability, e.g. "10 push-ups, no barbell experience".
    public var capabilityNote: ProfileField<String>
    public var weekdays: ProfileField<[Int]>
    public var minutesPerSession: ProfileField<Int>
    public var equipment: ProfileField<[PlanningEquipment]>
    /// Free-form load notes per equipment, e.g. "哑铃 5/7.5/10 kg". Never converted into a guess.
    public var equipmentLoads: ProfileField<[String]>
    public var venue: ProfileField<String>
    public var preferredExerciseIDs: ProfileField<[String]>
    public var excludedExerciseIDs: ProfileField<[String]>
    public var restrictions: ProfileField<String>
    public var constraintReview: TrainingConstraintReview?
    public var sleepNote: ProfileField<String>
    public var dailyActivityNote: ProfileField<String>
    public var adherenceBarriers: ProfileField<String>

    public init() {
        ageYears = .unknown; heightCM = .unknown; weightKG = .unknown
        adultStatus = .unknown
        primaryGoal = .unknown; secondaryGoals = .unknown; experience = .unknown
        capabilityNote = .unknown; weekdays = .unknown; minutesPerSession = .unknown
        equipment = .unknown; equipmentLoads = .unknown; venue = .unknown
        preferredExerciseIDs = .unknown; excludedExerciseIDs = .unknown; restrictions = .unknown
        sleepNote = .unknown; dailyActivityNote = .unknown; adherenceBarriers = .unknown
    }

    /// Every topic that currently holds a user-backed value and, separately, one that is only
    /// inferred. Used by the interview to decide what still needs asking or confirming.
    public var answeredTopics: Set<InterviewTopic> {
        Set(InterviewTopic.allCases.filter { isUsable($0) })
    }

    public func isUsable(_ topic: InterviewTopic) -> Bool {
        switch topic {
        case .age: return ageYears.isUsable
        case .height: return heightCM.isUsable
        case .weight: return weightKG.isUsable
        case .adultStatus: return adultStatus.isUsable
        case .primaryGoal: return primaryGoal.isUsable
        case .secondaryGoals: return secondaryGoals.isUsable
        case .experience: return experience.isUsable
        case .capability: return capabilityNote.isUsable
        case .schedule: return weekdays.isUsable
        case .minutes: return minutesPerSession.isUsable
        case .equipment: return equipment.isUsable
        case .equipmentLoads: return equipmentLoads.isUsable
        case .venue: return venue.isUsable
        case .preferences: return preferredExerciseIDs.isUsable
        case .exclusions: return excludedExerciseIDs.isUsable
        case .restrictions: return restrictions.isUsable
        case .sleep: return sleepNote.isUsable
        case .dailyActivity: return dailyActivityNote.isUsable
        case .adherence: return adherenceBarriers.isUsable
        }
    }

    public func provenance(of topic: InterviewTopic) -> ProfileProvenance {
        switch topic {
        case .age: return ageYears.provenance
        case .height: return heightCM.provenance
        case .weight: return weightKG.provenance
        case .adultStatus: return adultStatus.provenance
        case .primaryGoal: return primaryGoal.provenance
        case .secondaryGoals: return secondaryGoals.provenance
        case .experience: return experience.provenance
        case .capability: return capabilityNote.provenance
        case .schedule: return weekdays.provenance
        case .minutes: return minutesPerSession.provenance
        case .equipment: return equipment.provenance
        case .equipmentLoads: return equipmentLoads.provenance
        case .venue: return venue.provenance
        case .preferences: return preferredExerciseIDs.provenance
        case .exclusions: return excludedExerciseIDs.provenance
        case .restrictions: return restrictions.provenance
        case .sleep: return sleepNote.provenance
        case .dailyActivity: return dailyActivityNote.provenance
        case .adherence: return adherenceBarriers.provenance
        }
    }

    /// Inferred values that still need the user's confirmation, in a stable order.
    public var pendingInferences: [InterviewTopic] {
        InterviewTopic.allCases.filter { provenance(of: $0) == .inferred }
    }

    /// Fields the planner absolutely needs. Missing ones become follow-up questions, not guesses.
    public static let requiredTopics: [InterviewTopic] = [
        .adultStatus, .primaryGoal, .experience, .schedule, .minutes, .equipment, .restrictions
    ]

    public var missingRequiredTopics: [InterviewTopic] {
        Self.requiredTopics.filter { topic in
            switch topic {
            case .adultStatus: return !adultStatus.isUsable
            case .primaryGoal: return !primaryGoal.isUsable
            case .experience: return !experience.isUsable
            case .schedule: return !weekdays.isUsable
            case .minutes: return !minutesPerSession.isUsable
            case .equipment: return !equipment.isUsable
            case .restrictions: return !restrictions.isUsable
            default: return false
            }
        }
    }

    /// Compatibility query for complete essential facts. Generation eligibility also needs the
    /// restriction review, original-profile checks and current safety evidence; use the session query.
    public var isReadyForPlanning: Bool { missingRequiredTopics.isEmpty }

    /// Converts only user-backed values into the existing deterministic planning input. An unknown
    /// or unconfirmed value is reported, never filled in.
    public func planningInput(at date: Date = Date()) throws -> PlanningInput {
        try validate()
        let missing = missingRequiredTopics
        guard missing.isEmpty else {
            throw CoreError.invalidState("还缺少这些信息，不能生成计划："
                + missing.map(\.title).joined(separator: "、") + "。")
        }
        guard let goal = primaryGoal.value else { throw CoreError.invalidState("主目标未知。") }
        guard let experience = experience.value else { throw CoreError.invalidState("训练经验未知。") }
        guard let days = weekdays.value else { throw CoreError.invalidState("可训练日未知。") }
        guard let minutes = minutesPerSession.value else { throw CoreError.invalidState("单次可用时间未知。") }
        guard let gear = equipment.value else { throw CoreError.invalidState("可用器械未知。") }
        guard let restrictionText = restrictions.value else { throw CoreError.invalidState("运动限制未知。") }
        // Adult status is the user's own confirmation, never inferred from age or assumed by the app.
        guard let adult = adultStatus.value, adult else {
            throw CoreError.invalidState("本批自动计划只面向已明确确认年满 18 岁的健康成人。")
        }
        if ageYears.isUsable, let age = ageYears.value, age < 18 {
            throw CoreError.invalidState("已记录的年龄未满18岁，不能自动制定成人训练计划。")
        }
        if let review = constraintReview {
            try review.validate()
            guard review.sourceText == restrictionText, review.isFresh(at: date) else {
                throw CoreError.invalidInput("限制原文或今日状态已变化，请重新核对训练约束。")
            }
        }
        let input = PlanningInput(goal: goal, experience: experience, weekdays: days.filter { !(constraintReview?.excludedWeekdays.contains($0) ?? false) }.sorted(),
                                  minutesPerSession: min(minutes, constraintReview?.maxSessionMinutes ?? minutes), equipment: Set(gear),
                                  adultConfirmed: adult, safety: constraintReview == nil ? .noKnownRestrictions : .reviewedConstraints,
                                  painToday: false,
                                  excludedExerciseIDs: Array(Set((excludedExerciseIDs.value ?? []) + (constraintReview?.effectiveExcludedExerciseIDs ?? []))).sorted(),
                                  completedSessionsLast28Days: 0, daysSinceLastTraining: nil, constraintReview: constraintReview)
        try input.validate()
        // The deterministic engine already refuses a profile that records restrictions; surface the
        // same rule here so the caller gets one clear message instead of two different ones.
        let normalized = restrictionText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let noRestriction = Set(["无", "无已知限制", "无运动限制", "没有已知限制", "none"])
        guard constraintReview != nil || noRestriction.contains(normalized) else {
            throw CoreError.invalidInput("资料已齐全，还需核对限制：请保留原文，明确动作、日期和当前状态后再生成。")
        }
        return input
    }

    public func validate() throws {
        try constraintReview?.validate()
        try ageYears.validate(name: "年龄")
        try heightCM.validate(name: "身高")
        try weightKG.validate(name: "体重")
        if let value = ageYears.value, !(1...120).contains(value) { throw CoreError.invalidInput("年龄超出允许输入范围。") }
        if let value = heightCM.value, !value.isFinite || !(50...250).contains(value) { throw CoreError.invalidInput("身高超出允许输入范围。") }
        if let value = weightKG.value, !value.isFinite || !(15...400).contains(value) { throw CoreError.invalidInput("体重超出允许输入范围。") }
        try adultStatus.validate(name: "成年确认")
        try primaryGoal.validate(name: "主目标")
        try secondaryGoals.validate(name: "次目标")
        try experience.validate(name: "训练经验")
        try capabilityNote.validate(name: "实际能力")
        try weekdays.validate(name: "可训练日")
        try minutesPerSession.validate(name: "单次时间")
        try equipment.validate(name: "器械")
        try equipmentLoads.validate(name: "器械重量")
        try venue.validate(name: "场地")
        try preferredExerciseIDs.validate(name: "偏好动作")
        try excludedExerciseIDs.validate(name: "排除动作")
        try restrictions.validate(name: "运动限制")
        try sleepNote.validate(name: "睡眠")
        try dailyActivityNote.validate(name: "日常活动")
        try adherenceBarriers.validate(name: "坚持障碍")
        if let days = weekdays.value {
            guard (1...7).contains(days.count), days == days.sorted(),
                  days.allSatisfy({ (1...7).contains($0) }), Set(days).count == days.count else {
                throw CoreError.invalidInput("可训练日必须是 1 至 7 个不重复的星期。")
            }
        }
        if let minutes = minutesPerSession.value {
            guard (15...120).contains(minutes) else {
                throw CoreError.invalidInput("单次可用时间需在 15 至 120 分钟之间。")
            }
        }
        if let gear = equipment.value {
            guard !gear.isEmpty, Set(gear).count == gear.count else {
                throw CoreError.invalidInput("器械清单不能为空或重复。")
            }
        }
        if let excluded = excludedExerciseIDs.value {
            for id in excluded where ExerciseCatalog.exercise(id: id) == nil {
                throw CoreError.missingReference("排除动作 \(id)")
            }
        }
        if let preferred = preferredExerciseIDs.value {
            for id in preferred where ExerciseCatalog.exercise(id: id) == nil {
                throw CoreError.missingReference("偏好动作 \(id)")
            }
        }
        if let text = capabilityNote.value, text.count > 2_000 { throw CoreError.invalidInput("能力说明过长。") }
        if let text = restrictions.value, text.count > 2_000 { throw CoreError.invalidInput("限制说明过长。") }
        for field in [sleepNote.note, dailyActivityNote.note, adherenceBarriers.note] {
            if let field, field.count > 1_000 { throw CoreError.invalidInput("说明过长。") }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case ageYears, heightCM, weightKG, constraintReview
        case adultStatus, primaryGoal, secondaryGoals, experience, capabilityNote, weekdays, minutesPerSession, equipment, equipmentLoads, venue, preferredExerciseIDs, excludedExerciseIDs, restrictions, sleepNote, dailyActivityNote, adherenceBarriers
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        constraintReview = try values.decodeIfPresent(TrainingConstraintReview.self, forKey: .constraintReview)
        ageYears = try values.decodeIfPresent(ProfileField<Int>.self, forKey: .ageYears) ?? .unknown
        heightCM = try values.decodeIfPresent(ProfileField<Double>.self, forKey: .heightCM) ?? .unknown
        weightKG = try values.decodeIfPresent(ProfileField<Double>.self, forKey: .weightKG) ?? .unknown
        adultStatus = try values.decode(ProfileField<Bool>.self, forKey: .adultStatus)
        primaryGoal = try values.decode(ProfileField<PlanningGoal>.self, forKey: .primaryGoal)
        secondaryGoals = try values.decode(ProfileField<[PlanningGoal]>.self, forKey: .secondaryGoals)
        experience = try values.decode(ProfileField<PlanningExperience>.self, forKey: .experience)
        capabilityNote = try values.decode(ProfileField<String>.self, forKey: .capabilityNote)
        weekdays = try values.decode(ProfileField<[Int]>.self, forKey: .weekdays)
        minutesPerSession = try values.decode(ProfileField<Int>.self, forKey: .minutesPerSession)
        equipment = try values.decode(ProfileField<[PlanningEquipment]>.self, forKey: .equipment)
        equipmentLoads = try values.decode(ProfileField<[String]>.self, forKey: .equipmentLoads)
        venue = try values.decode(ProfileField<String>.self, forKey: .venue)
        preferredExerciseIDs = try values.decode(ProfileField<[String]>.self, forKey: .preferredExerciseIDs)
        excludedExerciseIDs = try values.decode(ProfileField<[String]>.self, forKey: .excludedExerciseIDs)
        restrictions = try values.decode(ProfileField<String>.self, forKey: .restrictions)
        sleepNote = try values.decode(ProfileField<String>.self, forKey: .sleepNote)
        dailyActivityNote = try values.decode(ProfileField<String>.self, forKey: .dailyActivityNote)
        adherenceBarriers = try values.decode(ProfileField<String>.self, forKey: .adherenceBarriers)
    }
}
