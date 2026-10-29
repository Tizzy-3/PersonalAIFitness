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

extension InterviewSession {
    public func nextGuidanceStep(legacyRestrictions: String = "", snapshot: AppSnapshot? = nil,
                                 at date: Date = Date()) -> InterviewGuidanceStep {
        if pausedAt != nil { return .resume }
        if !pendingInferences.isEmpty { return .reviewFacts }
        if !unansweredQuestions.isEmpty { return .answerQuestions }
        let eligibility = planningEligibility(legacyRestrictions: legacyRestrictions, at: date, snapshot: snapshot)
        if eligibility.canGenerate { return .readyForPlan }
        if eligibility.needsConstraintReview { return .clarifyLimits }
        if !profile.isReadyForPlanning && canContinueInterview { return .askCoach }
        return .blocked(eligibility.message)
    }
}
