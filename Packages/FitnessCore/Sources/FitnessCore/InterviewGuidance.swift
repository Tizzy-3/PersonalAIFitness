import Foundation

/// One deterministic next step, shared by automatic continuation and the explicit plan button.
/// It only chooses navigation; it cannot answer questions or confirm/activate a plan.
public enum InterviewGuidanceStep: Equatable, Sendable {
    case reviewFacts, answerQuestions, clarifyLimits, readyForPlan, askCoach, resume
    case blocked(String)

    public func shouldAskOnEntry(continueInDepth: Bool) -> Bool {
        self == .askCoach || (self == .readyForPlan && continueInDepth)
    }
}

extension InterviewGuidanceStep {
    /// Whether pressing "生成训练计划" can actually produce a plan right now. Everything else must
    /// explain itself instead of silently asking another question.
    public var canGeneratePlanNow: Bool { self == .readyForPlan }
}

extension InterviewSession {
    public func nextGuidanceStep(legacyRestrictions: String = "", snapshot: AppSnapshot? = nil,
                                 at date: Date = Date()) -> InterviewGuidanceStep {
        if pausedAt != nil { return .resume }
        if !pendingInferences.isEmpty { return .reviewFacts }
        if !unansweredQuestions.isEmpty { return .answerQuestions }
        let eligibility = planningEligibility(legacyRestrictions: legacyRestrictions, at: date, snapshot: snapshot)
        if eligibility.canGenerate { return .readyForPlan }
        if eligibility.needsConstraintReview { return .clarifyLimits }
        // `.askCoach` is right for entering the interview, but wrong for the plan button: a person
        // who pressed "生成训练计划" would silently get another question, and a model told not to
        // write a plan put one in the free-text `note` field instead. The button path uses
        // `planButtonStep` below, which reports the missing facts.
        if !profile.isReadyForPlanning && canContinueInterview { return .askCoach }
        return .blocked(eligibility.message)
    }

    /// The step for the explicit "生成训练计划" button. Unlike `nextGuidanceStep`, it never answers
    /// "ask another question": if facts are missing it says which ones.
    public func planButtonStep(legacyRestrictions: String = "", snapshot: AppSnapshot? = nil,
                               at date: Date = Date()) -> InterviewGuidanceStep {
        let step = nextGuidanceStep(legacyRestrictions: legacyRestrictions, snapshot: snapshot, at: date)
        guard step == .askCoach, canContinueInterview else { return step }
        let eligibility = planningEligibility(legacyRestrictions: legacyRestrictions, at: date, snapshot: snapshot)
        return .blocked(missingPlanningFactsMessage(eligibility: eligibility))
    }

    /// Names the facts that actually gate planning, so the person knows what to answer next.
    /// Optional details (height, sleep notes, preferences) are never listed as blockers.
    func missingPlanningFactsMessage(eligibility: PlanningEligibility) -> String {
        let gating: [InterviewTopic] = [.adultStatus, .primaryGoal, .experience,
                                        .schedule, .minutes, .equipment, .restrictions]
        let missing = gating.filter { !profile.isUsable($0) }.map(\.title)
        guard !missing.isEmpty else { return eligibility.message }
        return "还缺这些资料才能制定计划：\(missing.joined(separator: "、"))。"
            + "点下面的“让教练继续问我”，教练会逐个问清楚，不用自己找话题。"
    }
}
