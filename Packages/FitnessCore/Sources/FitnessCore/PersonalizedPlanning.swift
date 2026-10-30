import Foundation

/// A model may choose only one real movement per available pattern. Quantities and scheduling
/// remain the independently versioned engine's responsibility.
public struct PersonalizedPlanReply: Codable, Equatable, Sendable {
    public var choices: [String: String]
    public var explanation: String
    public var limitations: [String]
    public var gentleMinutes: Int?

    public init(choices: [String: String], explanation: String, limitations: [String], gentleMinutes: Int? = nil) {
        self.choices = choices; self.explanation = explanation; self.limitations = limitations
        self.gentleMinutes = gentleMinutes
    }

    public func validate(input: PlanningInput) throws {
        let pool = try PlannerEngine.candidatePool(input: input)
        guard Set(choices.keys) == Set(pool.keys), !choices.isEmpty else {
            throw CoreError.invalidInput("AI必须为每个可用动作模式选择真实候选，不允许遗漏后由本地默认补齐。")
        }
        for (pattern, id) in choices {
            guard pool[pattern]?.contains(id) == true else {
                throw CoreError.invalidInput("AI返回了不在本人器械与动作限制内的选择。")
            }
        }
        if input.constraintReview?.temporaryActivity != nil && gentleMinutes == nil {
            throw CoreError.invalidInput("教练没有安排轻活动的时长，请重新请求计划。")
        }
        if let gentleMinutes {
            guard try input.temporaryActivityItem(preferredID: choices["cardio"], minutes: gentleMinutes) != nil else {
                throw CoreError.invalidInput("这份计划没有临时轻活动，不能指定该时长。")
            }
        }
        try CoreValidation.nonempty(explanation, name: "AI个性化安排说明", maxLength: 12_000)
        guard limitations.count <= 20, limitations.allSatisfy({ !$0.isEmpty && $0.count <= 2_000 }) else {
            throw CoreError.invalidInput("AI计划限制说明过长或为空。")
        }
    }

    public static func decode(data: Data, input: PlanningInput) throws -> PersonalizedPlanReply {
        guard !data.isEmpty, data.count <= 128 * 1_024 else { throw CoreError.invalidInput("AI动作选择为空或超长。") }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (Set(object.keys) == Set(["choices", "explanation", "limitations"]) ||
                   Set(object.keys) == Set(["choices", "explanation", "limitations", "gentleMinutes"])) else {
                throw CoreError.invalidInput("AI动作组合包含不允许的字段，未生成生效计划。")
            }
            let value = try JSONDecoder().decode(PersonalizedPlanReply.self, from: data)
            try value.validate(input: input)
            return value
        } catch let error as CoreError { throw error }
        catch { throw CoreError.invalidInput("AI没有返回约定的动作组合格式，原计划未变。") }
    }
}

/// Optional on old format-4 drafts. Retaining choices and the exact interview profile makes a new
/// personalized draft reproducible and allows confirmation to reject changed interview facts.
public struct PersonalizationRecord: Codable, Equatable, Sendable {
    public var profile: StructuredProfile
    public var choices: [String: String]
    public var promptVersion: String
    public var gentleMinutes: Int?

    public init(profile: StructuredProfile, choices: [String: String], promptVersion: String = "personalized-plan-1", gentleMinutes: Int? = nil) {
        self.profile = profile; self.choices = choices; self.promptVersion = promptVersion; self.gentleMinutes = gentleMinutes
    }
}

extension PlanningDraft {
    public static func makePersonalized(profile: StructuredProfile, reply: PersonalizedPlanReply,
                                        snapshot: AppSnapshot, providerHost: String, model: String,
                                        at: Date = Date()) throws -> PlanningDraft {
        guard snapshot.interview?.profile == profile else {
            throw CoreError.invalidState("访谈档案已变化，请根据最新档案重新制定。")
        }
        var draft = try PlanningDraft.make(input: profile.planningInput(at: at), snapshot: snapshot, at: at)
        try reply.validate(input: draft.input)
        let option = try PlannerEngine.synthesize(input: draft.input, choices: reply.choices,
                                                 preferredExerciseIDs: profile.preferredExerciseIDs.isUsable
                                                 ? profile.preferredExerciseIDs.value ?? [] : [])
        draft.options = [option]
        draft.personalization = PersonalizationRecord(profile: profile, choices: reply.choices, gentleMinutes: reply.gentleMinutes)
        draft.selection = AISelection(optionID: option.id, explanation: reply.explanation,
                                      evidence: ["request", "rules", "option:\(option.id)"],
                                      limitations: reply.limitations)
        draft.providerHost = providerHost; draft.model = model
        try draft.validate()
        return draft
    }
}
