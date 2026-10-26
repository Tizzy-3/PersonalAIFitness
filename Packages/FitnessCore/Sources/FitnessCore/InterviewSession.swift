import Foundation

/// One interview: the profile being built, the turns so far, and what the app still needs.
///
/// The engine owns every state transition. The AI can propose questions and extractions, but only
/// this type decides whether they are legal and what provenance the resulting profile values carry.
public struct InterviewSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var phase: InterviewPhase
    public var profile: StructuredProfile
    public var turns: [InterviewTurn]
    /// Topics the user said they do not want to answer. Never asked again.
    public var declinedTopics: Set<InterviewTopic>
    public var rulesVersion: String
    public var appliedPlanVersionID: UUID?

    public init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date? = nil,
                phase: InterviewPhase = .inProgress, profile: StructuredProfile = StructuredProfile(),
                turns: [InterviewTurn] = [], declinedTopics: Set<InterviewTopic> = [],
                rulesVersion: String = InterviewRules.rulesVersion,
                appliedPlanVersionID: UUID? = nil) {
        self.id = id; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.phase = phase; self.profile = profile; self.turns = turns
        self.declinedTopics = declinedTopics; self.rulesVersion = rulesVersion
        self.appliedPlanVersionID = appliedPlanVersionID
    }

    // MARK: - Queries

    /// Topics still worth asking: not answered by the user, not declined, not already pending
    /// confirmation (a pending inference should be confirmed, not re-asked).
    public var openTopics: [InterviewTopic] {
        InterviewTopic.allCases.filter { topic in
            !declinedTopics.contains(topic)
                && !profile.isUsable(topic)
                && profile.provenance(of: topic) != .inferred
        }
    }

    /// Essential topics that are still open, in the order the interview should prefer.
    public var essentialOpenTopics: [InterviewTopic] { openTopics.filter(\.isEssential) }

    public var pendingInferences: [InterviewTopic] { profile.pendingInferences }

    /// The next phase the session should be in, derived — never set by hand from outside.
    public var derivedPhase: InterviewPhase {
        if appliedPlanVersionID != nil { return .planConfirmed }
        if !pendingInferences.isEmpty { return .awaitingReview }
        if profile.isReadyForPlanning { return .ready }
        return .inProgress
    }

    public var latestTurn: InterviewTurn? { turns.last }

    /// Questions from the newest turn that the user has not answered yet.
    public var unansweredQuestions: [InterviewQuestion] {
        guard let turn = latestTurn else { return [] }
        return turn.questions.filter { question in
            !turn.answers.contains { $0.questionID == question.id }
        }
    }

    public var answeredTurnCount: Int { turns.filter(\.isAnswered).count }

    // MARK: - Mutations

    /// Records one AI turn. Questions are validated, and topics the user declined or already
    /// answered are stripped rather than trusted, so the same thing is not asked twice.
    @discardableResult
    public mutating func appendTurn(_ turn: InterviewTurn, at date: Date = Date()) throws -> InterviewTurn {
        try CoreValidation.date(date, name: "访谈记录时间")
        try turn.validate()
        guard turns.count < InterviewRules.maximumTurns else {
            throw CoreError.invalidState("这次访谈记录已经很多，请先核对档案或开始一份新的访谈。")
        }
        var accepted = turn
        accepted.createdAt = date
        accepted.questions = turn.questions.filter { question in
            !declinedTopics.contains(question.topic)
                && !profile.isUsable(question.topic)
                && profile.provenance(of: question.topic) != .inferred
        }
        accepted.answers = turn.answers.filter { answer in
            accepted.questions.contains { $0.id == answer.questionID }
        }
        accepted.extractions = turn.extractions.filter { extraction in
            !declinedTopics.contains(extraction.topic)
        }
        // Re-validate the trimmed turn: dropping questions may orphan an answer.
        try accepted.validate()
        turns.append(accepted)
        updatedAt = date
        phase = derivedPhase
        return accepted
    }

    /// Records the user's answers to the newest turn and applies any resulting profile values as
    /// `stated`. An unanswered question is left unanswered; it never becomes an implicit "no".
    ///
    /// All work happens on a copy that is committed only on success, so a rejected answer cannot
    /// leave a partially applied profile behind.
    public mutating func answer(_ answers: [InterviewAnswer], at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "回答时间")
        guard let index = turns.indices.last else { throw CoreError.invalidState("还没有可以回答的问题。") }
        for answer in answers {
            guard let question = turns[index].questions.first(where: { $0.id == answer.questionID }) else {
                throw CoreError.invalidInput("这个问题不属于最新一轮访谈。")
            }
            guard !turns[index].answers.contains(where: { $0.questionID == answer.questionID }) else {
                throw CoreError.invalidInput("这个问题已经回答过了。")
            }
            try answer.validate(question: question)
        }
        try CoreValidation.unique(answers.map(\.questionID), name: "回答的问题")
        var draft = self
        for answer in answers {
            guard let question = draft.turns[index].questions.first(where: { $0.id == answer.questionID }) else { continue }
            switch answer.outcome {
            case .answered:
                try draft.applyAnswer(answer, for: question, at: date)
            case .unknown:
                try draft.clearTopic(question.topic)
            case .skipped:
                draft.declinedTopics.insert(question.topic)
            }
            draft.turns[index].answers.append(answer)
        }
        draft.updatedAt = date
        draft.phase = draft.derivedPhase
        try draft.validate()
        self = draft
    }

    /// Confirms one provisionally inferred value. This is the only path that turns a guess into a
    /// usable fact, and it requires the user's own action.
    public mutating func confirmInference(_ topic: InterviewTopic, accept: Bool, at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "确认时间")
        guard profile.provenance(of: topic) == .inferred else {
            throw CoreError.invalidState("这个项目当前没有待确认的推断。")
        }
        var draft = self
        if accept { try draft.setProvenance(.confirmed, for: topic, at: date) }
        else { try draft.clearTopic(topic) }
        draft.updatedAt = date
        draft.phase = draft.derivedPhase
        try draft.validate()
        self = draft
    }

    /// The user edits one field directly. Editing always yields a confirmed value.
    public mutating func setValue(_ value: InterviewValue, for topic: InterviewTopic,
                                  at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "修改时间")
        var draft = self
        try draft.apply(value, for: topic, provenance: .confirmed, at: date)
        draft.declinedTopics.remove(topic)
        draft.updatedAt = date
        draft.phase = draft.derivedPhase
        try draft.validate()
        self = draft
    }

    /// Marks one topic as explicitly unknown and stops asking about it.
    public mutating func markUnknown(_ topic: InterviewTopic, at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "修改时间")
        var draft = self
        try draft.clearTopic(topic)
        draft.declinedTopics.insert(topic)
        draft.updatedAt = date
        draft.phase = draft.derivedPhase
        try draft.validate()
        self = draft
    }

    public mutating func applyPlan(versionID: UUID, at date: Date = Date()) throws {
        try CoreValidation.date(date, name: "应用时间")
        appliedPlanVersionID = versionID
        updatedAt = date
        phase = derivedPhase
    }

    // MARK: - Answer application

    private mutating func applyAnswer(_ answer: InterviewAnswer, for question: InterviewQuestion,
                                     at date: Date) throws {
        switch question.kind {
        case .singleChoice:
            guard let choice = answer.choice else { throw CoreError.invalidInput("缺少选择结果。") }
            try applyChoice(choice, topic: question.topic, at: date)
        case .multiChoice:
            try applyChoices(answer.choices, topic: question.topic, at: date)
        case .number:
            guard let number = answer.number else { throw CoreError.invalidInput("缺少数值结果。") }
            try applyNumber(number, topic: question.topic, at: date)
        case .text:
            guard let text = answer.text else { throw CoreError.invalidInput("缺少文字结果。") }
            try apply(.text(text), for: question.topic, provenance: .stated, at: date)
        case .boolean:
            guard let flag = answer.boolean else { throw CoreError.invalidInput("缺少是否结果。") }
            try applyBoolean(flag, topic: question.topic, at: date)
        }
    }

    private mutating func applyChoice(_ choice: String, topic: InterviewTopic, at date: Date) throws {
        switch topic {
        case .adultStatus:
            guard choice == "yes" || choice == "是" else {
                throw CoreError.invalidInput("本批自动计划只面向已明确确认年满 18 岁的健康成人。")
            }
            profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: date)
        case .primaryGoal:
            guard let goal = PlanningGoal(rawValue: choice) else { throw CoreError.invalidInput("无法识别的目标选项。") }
            profile.primaryGoal = .init(value: goal, provenance: .stated, confirmedAt: date)
        case .experience:
            guard let value = PlanningExperience(rawValue: choice) else { throw CoreError.invalidInput("无法识别的经验选项。") }
            profile.experience = .init(value: value, provenance: .stated, confirmedAt: date)
        case .restrictions:
            profile.restrictions = .init(value: choice, provenance: .stated, confirmedAt: date)
        default:
            throw CoreError.invalidInput("这个主题不接受单选结果。")
        }
    }

    private mutating func applyChoices(_ choices: [String], topic: InterviewTopic, at date: Date) throws {
        switch topic {
        case .schedule:
            let days = choices.compactMap { Int($0) }.filter { (1...7).contains($0) }
            guard days.count == choices.count, !days.isEmpty else { throw CoreError.invalidInput("可训练日选项无效。") }
            profile.weekdays = .init(value: Array(Set(days)).sorted(), provenance: .stated, confirmedAt: date)
        case .equipment:
            let gear = choices.compactMap { PlanningEquipment(rawValue: $0) }
            guard gear.count == choices.count, !gear.isEmpty else { throw CoreError.invalidInput("器械选项无效。") }
            profile.equipment = .init(value: Array(Set(gear)).sorted { $0.rawValue < $1.rawValue },
                                      provenance: .stated, confirmedAt: date)
        case .secondaryGoals:
            let goals = choices.compactMap { PlanningGoal(rawValue: $0) }
            guard goals.count == choices.count else { throw CoreError.invalidInput("次要目标选项无效。") }
            profile.secondaryGoals = .init(value: goals, provenance: .stated, confirmedAt: date)
        case .preferences, .exclusions:
            for id in choices where ExerciseCatalog.exercise(id: id) == nil {
                throw CoreError.missingReference("动作 \(id)")
            }
            if topic == .preferences {
                profile.preferredExerciseIDs = .init(value: choices, provenance: .stated, confirmedAt: date)
            } else {
                profile.excludedExerciseIDs = .init(value: choices, provenance: .stated, confirmedAt: date)
            }
        default:
            throw CoreError.invalidInput("这个主题不接受多选结果。")
        }
    }

    private mutating func applyNumber(_ number: Double, topic: InterviewTopic, at date: Date) throws {
        switch topic {
        case .minutes:
            guard number == number.rounded(), (15...120).contains(Int(number)) else {
                throw CoreError.invalidInput("单次时间需为 15 至 120 分钟的整数。")
            }
            profile.minutesPerSession = .init(value: Int(number), provenance: .stated, confirmedAt: date)
        default:
            throw CoreError.invalidInput("这个主题不接受数值结果。")
        }
    }

    private mutating func applyBoolean(_ flag: Bool, topic: InterviewTopic, at date: Date) throws {
        switch topic {
        case .restrictions:
            // Recording a restriction never silently becomes a plan-ready profile: saying "yes"
            // tells the interview to keep asking until the user explains it.
            profile.restrictions = .init(value: flag ? "本人表示存在运动限制，需进一步说明" : "无",
                                         provenance: .stated, confirmedAt: date)
            if flag {
                throw CoreError.invalidInput("你表示存在运动限制。请说明具体情况；在明确之前不会自动生成训练计划。")
            }
        default:
            throw CoreError.invalidInput("这个主题不接受是否结果。")
        }
    }

    // MARK: - Value application

    /// Applies a typed extraction. `inferred` values keep no confirmation time, so nothing can use
    /// them before the user confirms.
    public mutating func applyExtraction(_ extraction: InterviewExtraction, at date: Date) throws {
        let value = try extraction.parse()
        var draft = self
        try draft.apply(value, for: extraction.topic, provenance: .inferred, at: date)
        draft.updatedAt = date
        draft.phase = draft.derivedPhase
        try draft.validate()
        self = draft
    }

    private mutating func apply(_ value: InterviewValue, for topic: InterviewTopic,
                                provenance: ProfileProvenance, at date: Date) throws {
        let confirmedAt: Date? = provenance == .inferred ? nil : date
        switch (topic, value) {
        case (.adultStatus, .boolean(let flag)):
            profile.adultStatus = .init(value: flag, provenance: provenance, confirmedAt: confirmedAt)
        case (.primaryGoal, .goal(let goal)):
            profile.primaryGoal = .init(value: goal, provenance: provenance, confirmedAt: confirmedAt)
        case (.secondaryGoals, .goals(let goals)):
            profile.secondaryGoals = .init(value: goals, provenance: provenance, confirmedAt: confirmedAt)
        case (.experience, .experience(let experience)):
            profile.experience = .init(value: experience, provenance: provenance, confirmedAt: confirmedAt)
        case (.schedule, .weekdays(let days)):
            profile.weekdays = .init(value: days, provenance: provenance, confirmedAt: confirmedAt)
        case (.minutes, .minutes(let minutes)):
            profile.minutesPerSession = .init(value: minutes, provenance: provenance, confirmedAt: confirmedAt)
        case (.equipment, .equipment(let gear)):
            profile.equipment = .init(value: gear, provenance: provenance, confirmedAt: confirmedAt)
        case (.equipmentLoads, .loads(let loads)):
            profile.equipmentLoads = .init(value: loads, provenance: provenance, confirmedAt: confirmedAt)
        case (.preferences, .exerciseIDs(let ids)):
            profile.preferredExerciseIDs = .init(value: ids, provenance: provenance, confirmedAt: confirmedAt)
        case (.exclusions, .exerciseIDs(let ids)):
            profile.excludedExerciseIDs = .init(value: ids, provenance: provenance, confirmedAt: confirmedAt)
        case (.capability, .text(let text)), (.venue, .text(let text)),
             (.restrictions, .text(let text)), (.sleep, .text(let text)),
             (.dailyActivity, .text(let text)), (.adherence, .text(let text)):
            try applyText(text, for: topic, provenance: provenance, at: confirmedAt)
        default:
            throw CoreError.invalidInput("\(topic.title)不接受这种内容。")
        }
        try profile.validate()
    }

    private mutating func applyText(_ text: String, for topic: InterviewTopic,
                                   provenance: ProfileProvenance, at confirmedAt: Date?) throws {
        let field = ProfileField(value: text, provenance: provenance, confirmedAt: confirmedAt)
        switch topic {
        case .capability: profile.capabilityNote = field
        case .venue: profile.venue = field
        case .restrictions: profile.restrictions = field
        case .sleep: profile.sleepNote = field
        case .dailyActivity: profile.dailyActivityNote = field
        case .adherence: profile.adherenceBarriers = field
        default: break
        }
    }

    private mutating func setProvenance(_ provenance: ProfileProvenance,
                                        for topic: InterviewTopic, at date: Date) throws {
        let confirmedAt: Date? = provenance == .inferred ? nil : date
        func rewrite<Value>(_ field: inout ProfileField<Value>) {
            field = ProfileField(value: field.value, provenance: field.value == nil ? .unknown : provenance,
                                 confirmedAt: field.value == nil ? nil : confirmedAt, note: field.note)
        }
        switch topic {
        case .adultStatus: rewrite(&profile.adultStatus)
        case .primaryGoal: rewrite(&profile.primaryGoal)
        case .secondaryGoals: rewrite(&profile.secondaryGoals)
        case .experience: rewrite(&profile.experience)
        case .capability: rewrite(&profile.capabilityNote)
        case .schedule: rewrite(&profile.weekdays)
        case .minutes: rewrite(&profile.minutesPerSession)
        case .equipment: rewrite(&profile.equipment)
        case .equipmentLoads: rewrite(&profile.equipmentLoads)
        case .venue: rewrite(&profile.venue)
        case .preferences: rewrite(&profile.preferredExerciseIDs)
        case .exclusions: rewrite(&profile.excludedExerciseIDs)
        case .restrictions: rewrite(&profile.restrictions)
        case .sleep: rewrite(&profile.sleepNote)
        case .dailyActivity: rewrite(&profile.dailyActivityNote)
        case .adherence: rewrite(&profile.adherenceBarriers)
        }
        try profile.validate()
    }

    private mutating func clearTopic(_ topic: InterviewTopic) throws {
        switch topic {
        case .adultStatus: profile.adultStatus = .unknown
        case .primaryGoal: profile.primaryGoal = .unknown
        case .secondaryGoals: profile.secondaryGoals = .unknown
        case .experience: profile.experience = .unknown
        case .capability: profile.capabilityNote = .unknown
        case .schedule: profile.weekdays = .unknown
        case .minutes: profile.minutesPerSession = .unknown
        case .equipment: profile.equipment = .unknown
        case .equipmentLoads: profile.equipmentLoads = .unknown
        case .venue: profile.venue = .unknown
        case .preferences: profile.preferredExerciseIDs = .unknown
        case .exclusions: profile.excludedExerciseIDs = .unknown
        case .restrictions: profile.restrictions = .unknown
        case .sleep: profile.sleepNote = .unknown
        case .dailyActivity: profile.dailyActivityNote = .unknown
        case .adherence: profile.adherenceBarriers = .unknown
        }
        try profile.validate()
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "访谈开始时间")
        try CoreValidation.date(updatedAt, name: "访谈更新时间")
        guard updatedAt >= createdAt, turns.count <= InterviewRules.maximumTurns,
              rulesVersion == InterviewRules.rulesVersion else {
            throw CoreError.invalidInput("访谈记录时间、数量或规则版本无效。")
        }
        try profile.validate()
        try CoreValidation.unique(turns.map(\.id), name: "访谈轮次 ID")
        var seenQuestionIDs = Set<UUID>()
        for turn in turns {
            try turn.validate()
            for question in turn.questions {
                guard seenQuestionIDs.insert(question.id).inserted else {
                    throw CoreError.duplicateIdentifier("访谈问题 ID")
                }
            }
        }
        guard (appliedPlanVersionID != nil) == (phase == .planConfirmed) else {
            throw CoreError.invalidState("访谈的应用计划状态与阶段不一致。")
        }
    }
}


