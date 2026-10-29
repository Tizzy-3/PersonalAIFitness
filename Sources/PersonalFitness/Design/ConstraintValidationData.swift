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
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--capture-constraint-deferred") }) {
            var chat = ConstraintChatSession(sourceText: session.profile.restrictions.value!, legacySourceText: store.profile.restrictions)
            try chat.receiveCandidate(.init(avoidedPositions: [.kneeling], excludedWeekdays: [3, 4],
                questions: ["特定时段具体允许活动尚未明确"], unresolved: ["该时段强度要求尚未明确"]), evidenceCount: 0, at: date)
            chat.setMode(.affectedDaysRest)
            if ProcessInfo.processInfo.arguments.contains("--capture-constraint-deferred-readback") {
                chat.restScopeConfirmed = true; chat.setPainFree(true, at: date)
            }
            session.constraintChat = chat
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-constraint-readback") {
            var chat = ConstraintChatSession(sourceText: session.profile.restrictions.value!, legacySourceText: store.profile.restrictions)
            try chat.appendUser("周五休息，避开跪姿，每次最多25分钟。", at: evidence)
            try chat.receiveCandidate(.init(avoidedPositions: [.kneeling], excludedWeekdays: [5], maxSessionMinutes: 25),
                                      evidenceCount: 1, at: date)
            chat.setMode(.practicalOnly)
            chat.setPainFree(true, at: date)
            session.constraintChat = chat
        }
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
            let input = try committed.profile.planningInput(at: date)
            let pool = try PlannerEngine.candidatePool(input: input)
            let reply = PersonalizedPlanReply(choices: pool.mapValues { $0[0] },
                explanation: "合成界面验证：仅用于检查七天安排布局，未请求AI。", limitations: [])
            let draft = try PlanningDraft.makePersonalized(profile: committed.profile, reply: reply,
                snapshot: store.snapshot(), providerHost: "example.test", model: "isolated-ui-fixture", at: date)
            try store.savePlanningDraft(draft)
        }
        return store
    }
}
#endif
