import Foundation
import FitnessCore

/// Turns what the store already knows into the two sentences the coach says today.
///
/// This is assembly only: every decision is made by `DailyCoachBrief`/`SessionCoachReply` in
/// FitnessCore, and every input here is a saved record. Nothing in this file invents a plan, a
/// recommendation or a health conclusion of its own.
@MainActor
extension TrainingStore {
    var todayBrief: DailyCoachBrief {
        todayBrief(at: Date())
    }

    func todayBrief(at now: Date) -> DailyCoachBrief {
        let scheduled = scheduledPlan(on: now)
        let finishedToday = sessions
            .filter { !$0.status.isOngoing && Calendar.current.isDate($0.startedAt, inSameDayAs: now) }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .first
        let feedback = finishedToday.flatMap { feedback(for: $0.id) }
        // Feedback counts as "today's session" only when it was actually recorded after the workout
        // ended; a feedback record carried over from an earlier session must not read as done today.
        let completedToday: SessionFeedback? = {
            guard let feedback, let ended = finishedToday?.endedAt,
                  Calendar.current.isDate(feedback.createdAt, inSameDayAs: now),
                  feedback.createdAt >= ended.addingTimeInterval(-60) else { return nil }
            return feedback
        }()
        let lastFinished = sessions
            .filter { !$0.status.isOngoing && !Calendar.current.isDate($0.startedAt, inSameDayAs: now) }
            .sorted { $0.startedAt > $1.startedAt }
            .first
        let restriction = interview?.profile.restrictions
        return DailyCoachBrief.make(
            now: now,
            checkIn: todaysCheckIn(now: now),
            profileRestrictions: restriction?.isUsable == true ? restriction?.value : nil,
            plan: scheduled,
            hasWeeklyProgram: currentWeeklyProgram != nil,
            isConstraintRestDay: isConstraintRestDay(on: now),
            activeSession: activeSession,
            lastFinishedSession: lastFinished,
            lastFeedback: lastFinished.flatMap { feedback(for: $0.id) },
            completedToday: completedToday)
    }

    /// The reply to show once a workout has been saved. `nil` when the feedback could not be matched
    /// to a saved session, so the UI never shows a reply about a workout it cannot verify.
    func sessionCoachReply(feedbackID: UUID) -> SessionCoachReply? {
        guard let feedback = sessionFeedbackRecords.first(where: { $0.id == feedbackID }),
              let session = session(id: feedback.sessionID) else { return nil }
        return SessionCoachReply.make(feedback: feedback, session: session)
    }

    /// True when the stored proposal no longer matches today's facts, so the card can say so instead
    /// of offering a change that confirmation would immediately refuse.
    func isAdjustmentStale(_ proposal: AdjustmentProposal, now: Date = Date()) -> Bool {
        guard let current = try? adjustmentFingerprint(now: now) else { return true }
        return AdjustmentEngine.isStale(proposal, currently: current, now: now)
    }

    /// The question that must be answered before today's plan can be presented as startable, or
    /// `nil` when nothing stands in the way. Today's screen shows this above the plan instead of the
    /// start button, so the two never contradict each other.
    func prepQuestion(now: Date = Date()) -> String? {
        ReadinessEngine.blockingQuestion(checkIn: todaysCheckIn(now: now),
                                         profile: interview?.profile ?? StructuredProfile(), now: now)
    }

    /// Whether Today may offer the "less today" entry. It appears only when the conservative reduction
    /// would actually change something, so the button never opens a screen that just says "keep".
    ///
    /// The proposal is **not** stored here: the card is a preview, and generating stays on the review
    /// screen where the evidence is visible before anything is saved.
    func canProposeReduction(for plan: PlanVersion, on date: Date) -> Bool {
        guard activeSession == nil else { return false }
        guard pendingAdjustment == nil else { return false }
        return AdjustmentEngine.reductionPreview(items: plan.items) != plan.items
    }
}
