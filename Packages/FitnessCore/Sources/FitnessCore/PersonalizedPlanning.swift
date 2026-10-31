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
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.invalidInput("模型没有返回 JSON 对象。")
        }
        let allowed: Set<String> = ["choices", "explanation", "limitations", "gentleMinutes"]
        let unknown = object.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CoreError.invalidInput("动作组合包含不允许的字段：\(unknown.joined(separator: "、"))，未生成生效计划。")
        }
        let missing = ["choices", "explanation", "limitations"].filter { object[$0] == nil }
        guard missing.isEmpty else {
            throw CoreError.invalidInput("动作组合缺少字段：\(missing.joined(separator: "、"))。")
        }
        // A model sometimes sends the minute count as "10" or "10分钟"; only an exact integer is
        // accepted, never a rounded or guessed duration.
        if let minutes = object["gentleMinutes"], !(minutes is NSNull),
           let value = strictInteger(minutes) { object["gentleMinutes"] = value }
        guard let normalized = try? JSONSerialization.data(withJSONObject: object) else {
            throw CoreError.invalidInput("动作组合无法还原为标准 JSON。")
        }
        do {
            let value = try JSONDecoder().decode(PersonalizedPlanReply.self, from: normalized)
            try value.validate(input: input)
            return value
        } catch let error as CoreError { throw error }
        catch { throw CoreError.invalidInput("动作组合的字段类型与约定不符，原计划未变。") }
    }

    /// Exact integer only: `10`, `"10"`, `"10分钟"`. A decimal or a boolean is rejected rather than
    /// truncated into a duration the model never asked for.
    static func strictInteger(_ value: Any) -> Int? {
        if let text = value as? String {
            var digits = ""
            for character in text.trimmingCharacters(in: .whitespacesAndNewlines) {
                if character.isNumber || (digits.isEmpty && character == "-") { digits.append(character) }
                else { break }
            }
            guard !digits.isEmpty else { return nil }
            let remainder = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(digits.count)
            guard !remainder.hasPrefix(".") else { return nil }
            return Int(digits)
        }
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              double >= Double(Int.min), double <= Double(Int.max) else { return nil }
        return Int(double)
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
