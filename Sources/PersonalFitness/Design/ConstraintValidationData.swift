import Foundation
import FitnessCore

#if DEBUG
/// Isolated UI fixtures only. Never used by normal startup or a Release installation.
@MainActor enum ConstraintValidationData {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--capture-constraint-") }
    }

    static func makeStore() throws -> TrainingStore {
        let store = try TrainingStore(inMemory: true)
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var session = try store.startInterview(at: date.addingTimeInterval(-5))
        let evidence = date.addingTimeInterval(-1)
        session.profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: evidence)
        session.profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: evidence)
        session.profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: evidence)
        session.profile.weekdays = .init(value: Array(1...7), provenance: .stated, confirmedAt: evidence)
        session.profile.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: evidence)
        session.profile.equipment = .init(value: [.bodyweight, .dumbbells, .bench, .walkingSpace], provenance: .stated, confirmedAt: evidence)
        session.profile.restrictions = .init(value: "周五有固定事务，训练时避开跪姿动作。", provenance: .stated, confirmedAt: evidence)
        session.phase = .awaitingReview
        if ProcessInfo.processInfo.arguments.contains("--capture-constraint-draft") {
            let review = TrainingConstraintReview(sourceText: session.profile.restrictions.value!,
                legacySourceText: store.profile.restrictions, mode: .practicalOnly,
                excludedWeekdays: [5], restDateKeys: [], excludedExerciseIDs: [],
                avoidedPositions: [.kneeling], allowedExerciseIDs: nil, maxSessionMinutes: 25,
                painFreeConfirmed: true, allLimitsRepresentedConfirmed: true,
                professionalGuidanceNote: "", confirmedAt: date)
            try session.confirmConstraintReview(review, at: date)
        }
        try store.saveInterview(session)
        if ProcessInfo.processInfo.arguments.contains("--capture-constraint-draft"), let committed = store.interview {
            let draft = try PlanningDraft.make(input: committed.profile.planningInput(at: date), snapshot: store.snapshot(), at: date)
            try store.savePlanningDraft(draft)
        }
        return store
    }
}
#endif
