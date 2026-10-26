import Foundation

/// The topics an interview can cover. Kept as a closed set so the AI cannot introduce fields the
/// app has no place to store.
public enum InterviewTopic: String, Codable, Equatable, CaseIterable, Sendable {
    case adultStatus, primaryGoal, secondaryGoals, experience, capability, schedule, minutes
    case equipment, equipmentLoads, venue, preferences, exclusions, restrictions
    case sleep, dailyActivity, adherence

    public var title: String {
        switch self {
        case .adultStatus: return "是否已年满18岁"
        case .primaryGoal: return "主要目标"
        case .secondaryGoals: return "次要目标"
        case .experience: return "训练经验"
        case .capability: return "实际能力"
        case .schedule: return "每周可训练日"
        case .minutes: return "单次可用时间"
        case .equipment: return "可用器械"
        case .equipmentLoads: return "器械重量档位"
        case .venue: return "训练场地"
        case .preferences: return "动作偏好"
        case .exclusions: return "不想做的动作"
        case .restrictions: return "伤病与运动限制"
        case .sleep: return "睡眠情况"
        case .dailyActivity: return "日常活动量"
        case .adherence: return "坚持难点"
        }
    }

    /// Topics whose answers can materially change a training plan; the interview prefers these first.
    public var isEssential: Bool { StructuredProfile.requiredTopics.contains(self) }
}

public enum InterviewPhase: String, Codable, Equatable, Sendable {
    case inProgress, awaitingReview, ready, planConfirmed

    public var title: String {
        switch self {
        case .inProgress: return "访谈中"
        case .awaitingReview: return "等你核对"
        case .ready: return "可以生成计划"
        case .planConfirmed: return "计划已确认"
        }
    }
}

/// The kind of answer the app will accept for one question. Anything else is rejected outright.
public enum InterviewQuestionKind: String, Codable, Equatable, Sendable {
    case singleChoice, multiChoice, number, text, boolean
}

/// A validated question. The AI proposes the content; the app decides whether it is legal.
public struct InterviewQuestion: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var topic: InterviewTopic
    public var kind: InterviewQuestionKind
    public var prompt: String
    /// Only meaningful for choice kinds; must be non-empty and unique.
    public var options: [String]
    /// Only meaningful for `number`; a unit label such as "分钟".
    public var unit: String?
    public var minimum: Double?
    public var maximum: Double?
    public var allowUnknown: Bool
    public var allowSkip: Bool

    public init(id: UUID = UUID(), topic: InterviewTopic, kind: InterviewQuestionKind,
                prompt: String, options: [String] = [], unit: String? = nil,
                minimum: Double? = nil, maximum: Double? = nil,
                allowUnknown: Bool = true, allowSkip: Bool = true) {
        self.id = id; self.topic = topic; self.kind = kind; self.prompt = prompt
        self.options = options; self.unit = unit; self.minimum = minimum; self.maximum = maximum
        self.allowUnknown = allowUnknown; self.allowSkip = allowSkip
    }

    public func validate() throws {
        try CoreValidation.nonempty(prompt, name: "问题内容", maxLength: 500)
        switch kind {
        case .singleChoice, .multiChoice:
            guard !options.isEmpty, options.count <= 20 else {
                throw CoreError.invalidInput("选择题必须提供 1 至 20 个选项。")
            }
            try CoreValidation.unique(options, name: "问题选项")
            guard options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }) else {
                throw CoreError.invalidInput("问题选项不能为空或过长。")
            }
            guard unit == nil, minimum == nil, maximum == nil else {
                throw CoreError.invalidInput("选择题不能携带数值范围。")
            }
        case .number:
            guard options.isEmpty else { throw CoreError.invalidInput("数值题不能携带选项。") }
            if let unit, unit.count > 20 { throw CoreError.invalidInput("数值单位过长。") }
            if let minimum, let maximum {
                guard minimum.isFinite, maximum.isFinite, minimum <= maximum else {
                    throw CoreError.invalidInput("数值范围无效。")
                }
            } else if minimum != nil || maximum != nil {
                throw CoreError.invalidInput("数值范围需要同时给出下限和上限。")
            }
        case .text, .boolean:
            guard options.isEmpty, unit == nil, minimum == nil, maximum == nil else {
                throw CoreError.invalidInput("这类问题不能携带选项或数值范围。")
            }
        }
    }
}

/// One answer the user actually gave. `unknown` and `skip` are recorded as their own outcomes so a
/// missing answer can never be read as a negative or healthy answer.
public struct InterviewAnswer: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable {
        case answered, unknown, skipped
    }

    public var questionID: UUID
    public var outcome: Outcome
    public var choice: String?
    public var choices: [String]
    public var number: Double?
    public var text: String?
    public var boolean: Bool?
    public var answeredAt: Date

    public init(questionID: UUID, outcome: Outcome = .answered, choice: String? = nil,
                choices: [String] = [], number: Double? = nil, text: String? = nil,
                boolean: Bool? = nil, answeredAt: Date = Date()) {
        self.questionID = questionID; self.outcome = outcome; self.choice = choice
        self.choices = choices; self.number = number; self.text = text
        self.boolean = boolean; self.answeredAt = answeredAt
    }

    public func validate(question: InterviewQuestion) throws {
        guard questionID == question.id else { throw CoreError.invalidInput("回答与问题不匹配。") }
        try CoreValidation.date(answeredAt, name: "回答时间")
        switch outcome {
        case .unknown:
            guard question.allowUnknown else { throw CoreError.invalidInput("这个题目不允许回答“不知道”。") }
            guard choice == nil, choices.isEmpty, number == nil, text == nil, boolean == nil else {
                throw CoreError.invalidInput("“不知道”不能同时携带具体内容。")
            }
        case .skipped:
            guard question.allowSkip else { throw CoreError.invalidInput("这个题目不允许跳过。") }
            guard choice == nil, choices.isEmpty, number == nil, text == nil, boolean == nil else {
                throw CoreError.invalidInput("跳过不能同时携带具体内容。")
            }
        case .answered:
            switch question.kind {
            case .singleChoice:
                guard let choice, question.options.contains(choice), choices.isEmpty,
                      number == nil, text == nil, boolean == nil else {
                    throw CoreError.invalidInput("请从给出的选项中选择一项。")
                }
            case .multiChoice:
                guard choice == nil, number == nil, text == nil, boolean == nil,
                      Set(choices).count == choices.count,
                      choices.allSatisfy({ question.options.contains($0) }) else {
                    throw CoreError.invalidInput("所选项目不在给出的选项中。")
                }
            case .number:
                guard let number, number.isFinite, choice == nil, choices.isEmpty,
                      text == nil, boolean == nil else {
                    throw CoreError.invalidInput("请输入一个有效数字。")
                }
                if let minimum = question.minimum, number < minimum {
                    throw CoreError.invalidInput("数值低于允许范围。")
                }
                if let maximum = question.maximum, number > maximum {
                    throw CoreError.invalidInput("数值高于允许范围。")
                }
            case .text:
                guard let text, choice == nil, choices.isEmpty, number == nil, boolean == nil else {
                    throw CoreError.invalidInput("请输入文字回答。")
                }
                try CoreValidation.nonempty(text, name: "回答", maxLength: 2_000)
            case .boolean:
                guard boolean != nil, choice == nil, choices.isEmpty, number == nil, text == nil else {
                    throw CoreError.invalidInput("请选择是或否。")
                }
            }
        }
    }
}

/// One AI turn: up to three questions plus any values it extracted, which stay provisional until
/// the user confirms them one by one.
public struct InterviewTurn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var questions: [InterviewQuestion]
    public var answers: [InterviewAnswer]
    /// Extracted values, always stored as `inferred` until the user confirms them.
    public var extractions: [InterviewExtraction]
    /// What the assistant said alongside the questions. Not a source of facts.
    public var note: String
    public var provider: InterviewProvider?

    public init(id: UUID = UUID(), createdAt: Date = Date(), questions: [InterviewQuestion] = [],
                answers: [InterviewAnswer] = [], extractions: [InterviewExtraction] = [],
                note: String = "", provider: InterviewProvider? = nil) {
        self.id = id; self.createdAt = createdAt; self.questions = questions
        self.answers = answers; self.extractions = extractions; self.note = note
        self.provider = provider
    }

    public var isAnswered: Bool {
        !questions.isEmpty && questions.allSatisfy { question in answers.contains { $0.questionID == question.id } }
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "访谈时间")
        guard questions.count <= InterviewRules.maximumQuestionsPerTurn else {
            throw CoreError.invalidInput("一轮最多只能问 \(InterviewRules.maximumQuestionsPerTurn) 个问题。")
        }
        try CoreValidation.unique(questions.map(\.id), name: "问题 ID")
        for question in questions { try question.validate() }
        try CoreValidation.unique(answers.map(\.questionID), name: "同一问题的回答")
        for answer in answers {
            guard let question = questions.first(where: { $0.id == answer.questionID }) else {
                throw CoreError.invalidInput("回答指向了本轮不存在的问题。")
            }
            try answer.validate(question: question)
        }
        try CoreValidation.unique(extractions.map(\.topic), name: "同一主题的抽取结果")
        for extraction in extractions { try extraction.validate() }
        guard note.count <= 2_000 else { throw CoreError.invalidInput("说明过长。") }
    }
}

/// A value the AI read out of free text. It is always provisional.
public struct InterviewExtraction: Codable, Equatable, Sendable {
    public var topic: InterviewTopic
    /// The value in the topic's own encoding: an enum raw value, comma-separated numbers, or text.
    public var rawValue: String
    public var rationale: String

    public init(topic: InterviewTopic, rawValue: String, rationale: String = "") {
        self.topic = topic; self.rawValue = rawValue; self.rationale = rationale
    }

    public func validate() throws {
        try CoreValidation.nonempty(rawValue, name: "抽取内容", maxLength: 2_000)
        guard rationale.count <= 500 else { throw CoreError.invalidInput("抽取说明过长。") }
        // The value must be interpretable for this topic; otherwise it is not a candidate fact.
        _ = try parse()
    }

    /// Interprets `rawValue` as the topic's own value type. Throws when the text cannot represent a
    /// legal value, so an unparseable guess never reaches the profile.
    public func parse() throws -> InterviewValue {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoreError.invalidInput("抽取内容为空。") }
        switch topic {
        case .primaryGoal:
            guard let goal = PlanningGoal(rawValue: trimmed) else {
                throw CoreError.invalidInput("无法识别的训练目标。")
            }
            return .goal(goal)
        case .secondaryGoals:
            let goals = try Self.list(trimmed).map { raw -> PlanningGoal in
                guard let goal = PlanningGoal(rawValue: raw) else {
                    throw CoreError.invalidInput("无法识别的次要目标：\(raw)。")
                }
                return goal
            }
            guard !goals.isEmpty else { throw CoreError.invalidInput("次要目标为空。") }
            return .goals(goals)
        case .experience:
            guard let experience = PlanningExperience(rawValue: trimmed) else {
                throw CoreError.invalidInput("无法识别的训练经验。")
            }
            return .experience(experience)
        case .adultStatus:
            let normalizedAdult = trimmed.lowercased()
            guard ["true", "yes", "是", "1", "已满18"].contains(normalizedAdult) else {
                throw CoreError.invalidInput("成年确认只能由本人明确回答。")
            }
            return .boolean(true)
        case .capability, .venue, .restrictions, .sleep, .dailyActivity, .adherence:
            return .text(trimmed)
        case .schedule:
            let days = try Self.list(trimmed).map { raw -> Int in
                guard let day = Int(raw), (1...7).contains(day) else {
                    throw CoreError.invalidInput("可训练日必须是 1 至 7：\(raw)。")
                }
                return day
            }
            let unique = Array(Set(days)).sorted()
            guard !unique.isEmpty else { throw CoreError.invalidInput("可训练日为空。") }
            return .weekdays(unique)
        case .minutes:
            guard let minutes = Int(trimmed), (15...120).contains(minutes) else {
                throw CoreError.invalidInput("单次时间需在 15 至 120 分钟之间的整数。")
            }
            return .minutes(minutes)
        case .equipment:
            let gear = try Self.list(trimmed).map { raw -> PlanningEquipment in
                guard let item = PlanningEquipment(rawValue: raw) else {
                    throw CoreError.invalidInput("无法识别的器械：\(raw)。")
                }
                return item
            }
            let unique = Array(Set(gear)).sorted { $0.rawValue < $1.rawValue }
            guard !unique.isEmpty else { throw CoreError.invalidInput("器械清单为空。") }
            return .equipment(unique)
        case .equipmentLoads:
            let loads = Self.list(trimmed).filter { !$0.isEmpty }
            guard !loads.isEmpty else { throw CoreError.invalidInput("器械重量说明为空。") }
            return .loads(loads)
        case .preferences, .exclusions:
            let ids = try Self.list(trimmed)
            for id in ids where ExerciseCatalog.exercise(id: id) == nil {
                throw CoreError.missingReference("动作 \(id)")
            }
            guard !ids.isEmpty else { throw CoreError.invalidInput("动作清单为空。") }
            return .exerciseIDs(ids)
        }
    }

    private static func list(_ text: String) throws -> [String] {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count <= 40 else { throw CoreError.invalidInput("一次抽取的项目过多。") }
        return parts
    }
}

/// A parsed extraction, typed by topic. Only these shapes can ever be written into a profile.
public enum InterviewValue: Equatable, Sendable {
    case goal(PlanningGoal)
    case goals([PlanningGoal])
    case experience(PlanningExperience)
    case weekdays([Int])
    case minutes(Int)
    case equipment([PlanningEquipment])
    case loads([String])
    case exerciseIDs([String])
    case boolean(Bool)
    case text(String)
}

public struct InterviewProvider: Codable, Equatable, Sendable {
    public var host: String
    public var model: String

    public init(host: String, model: String) { self.host = host; self.model = model }

    public func validate() throws {
        try CoreValidation.nonempty(host, name: "服务地址", maxLength: 255)
        try CoreValidation.nonempty(model, name: "模型名称", maxLength: 200)
    }
}

public enum InterviewRules {
    public static let rulesVersion = "interview-1"
    public static let maximumQuestionsPerTurn = 3
    public static let maximumTurns = 200
}
