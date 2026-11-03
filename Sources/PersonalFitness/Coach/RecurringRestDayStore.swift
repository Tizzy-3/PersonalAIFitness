import Foundation
import FitnessCore

/// Saving a recurring day off.
///
/// This is deliberately *not* routed through `confirmConstraintReview`, which exists to turn a
/// physical restriction into movement rules and requires a fresh pain answer at the same time. A
/// calendar appointment has neither of those properties, and forcing it through that gate is what
/// kept plan generation blocked.
@MainActor
extension TrainingStore {
    /// Adds or replaces a recurring rest day, creating the constraint record if none exists yet.
    func saveRecurringRestDay(_ rule: RecurringRestDay, clearingOldRestriction: Bool = false,
                              at date: Date = Date()) throws {
        try rule.validate()
        guard var session = interview else {
            throw CoreError.invalidState("还没有训练档案，先跟教练聊几句，或到档案页填写。")
        }
        let existing = session.profile.constraintReview
        var rules = existing?.recurringRestDays ?? []
        // Replace a rule with the same weekday and interval instead of stacking duplicates.
        rules.removeAll { $0.weekday == rule.weekday && $0.everyWeeks == rule.everyWeeks }
        rules.append(rule)
        guard rules.count <= 10 else { throw CoreError.invalidInput("重复休息日过多。") }

        // Retiring the old free-text limit is what makes the record calendar-only. It is only done
        // when the person explicitly asked for it in the sheet; nothing here decides on its own that
        // a recorded restriction was harmless.
        let retired = clearingOldRestriction
        let sourceText = retired ? "无" : (existing?.sourceText ?? session.profile.restrictions.value ?? "")
        let review = TrainingConstraintReview(
            sourceText: sourceText,
            legacySourceText: retired ? "无" : (existing?.legacySourceText ?? profile.restrictions),
            mode: existing?.mode ?? .practicalOnly,
            excludedWeekdays: existing?.excludedWeekdays ?? [],
            restDateKeys: existing?.restDateKeys ?? [],
            excludedExerciseIDs: existing?.excludedExerciseIDs ?? [],
            avoidedPositions: existing?.avoidedPositions ?? [],
            allowedExerciseIDs: existing?.allowedExerciseIDs,
            maxSessionMinutes: existing?.maxSessionMinutes,
            painFreeConfirmed: existing?.painFreeConfirmed ?? false,
            allLimitsRepresentedConfirmed: existing?.allLimitsRepresentedConfirmed ?? false,
            professionalGuidanceNote: existing?.professionalGuidanceNote ?? "",
            confirmedAt: date,
            rulesVersion: existing?.rulesVersion ?? TrainingConstraintReview.currentRulesVersion,
            restScopeConfirmed: existing?.restScopeConfirmed,
            deferredClinicalQuestions: existing?.deferredClinicalQuestions,
            temporaryActivity: existing?.temporaryActivity,
            recurringRestDays: rules.sorted { $0.weekday < $1.weekday })
        try review.validate()
        session.profile.constraintReview = review
        if retired {
            // The structured profile carries the same text; leaving it behind would keep the old
            // wording alive even though the calendar rule replaced it.
            session.profile.restrictions = .init(value: "无", provenance: .confirmed, confirmedAt: date, note: nil)
        }
        try saveInterview(session)
    }

    /// The free-text restriction still on file, when it is not a plain "none".
    var oldRestrictionText: String? {
        guard let value = interview?.profile.restrictions.value,
              !TrainingConstraintReview.isNoRestrictionText(value, allowingEmpty: true) else { return nil }
        return value
    }

    /// Convenience for the UI: the rules already recorded.
    var recurringRestDays: [RecurringRestDay] {
        interview?.profile.constraintReview?.recurringRestDays ?? []
    }
}
