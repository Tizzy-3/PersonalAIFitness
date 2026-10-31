import Foundation
import FitnessCore

/// The two jobs the coach does in conversation.
///
/// Both are single calls with no menu in between: the person types, the coach answers, and when
/// there is enough to work with a plan is drafted. Nothing here asks the person to choose a mode.
///
/// Marked `@MainActor` because `TrainingStore` is main-actor isolated: `snapshot()`, `interview` and
/// `savePlanningDraft` cannot be touched from a background executor. The network calls inside still
/// suspend rather than block, so the main actor is not held while waiting for the model.
@MainActor
struct CoachConversationService {
    let client: CoachHTTPClient
    init(client: CoachHTTPClient = CoachHTTPClient()) { self.client = client }

    /// The coach's reply to one message, using the same consented context and safety rules as the
    /// question-answer screen.
    func reply(to question: String, store: TrainingStore) async throws -> String {
        guard let configuration = try AIConfigurationStorage.load() else {
            throw CoachClientError.configuration("先配置 AI 接口，教练才能回答。")
        }
        guard let key = try AIKeychain.load(for: configuration) else {
            throw CoachClientError.configuration("还没有填写本机密钥，先到设置里填写。")
        }
        let context = try CoachContext.make(snapshot: store.snapshot()).withMovementKnowledge(for: question)
        let reply = try await CoachAPI().reply(question: question, context: context,
                                               configuration: configuration, key: key)
        return reply.answer
    }

    /// Drafts a plan from everything confirmed so far and saves it as a draft. Returns the draft id;
    /// the draft is *not* active until the person confirms it on the detail screen.
    func draftPlan(store: TrainingStore) async throws -> UUID {
        guard let configuration = try AIConfigurationStorage.load() else {
            throw CoachClientError.configuration("先配置 AI 接口，教练才能制定计划。")
        }
        guard let key = try AIKeychain.load(for: configuration) else {
            throw CoachClientError.configuration("还没有填写本机密钥，先到设置里填写。")
        }
        guard let session = store.interview else {
            throw CoreError.invalidState("还没有和教练聊过，先说几句你的情况。")
        }
        guard store.activeSession == nil else {
            throw CoreError.invalidState("先结束正在进行的训练，再制定新计划。")
        }
        let request = try PersonalizedPlanRequest.make(session: session, snapshot: store.snapshot())
        let reply = try await PersonalizedPlannerAPI().compose(request, configuration: configuration, key: key)
        guard store.interview == session,
              request.baseline.matches(snapshot: try store.snapshot()) else {
            throw CoreError.invalidState("聊天期间资料有更新，请再说一次，我按最新情况安排。")
        }
        let draft = try PlanningDraft.makePersonalized(
            profile: session.profile, reply: reply, snapshot: store.snapshot(),
            providerHost: configuration.validatedURL().host ?? "未知",
            model: configuration.model)
        guard draft.matches(snapshot: try store.snapshot()) else {
            throw CoreError.invalidState("这份计划的依据已变化，请重新说一次。")
        }
        try store.savePlanningDraft(draft)
        return draft.id
    }
}

@MainActor
extension TrainingStore {
    /// Appends the person's message as a pending turn so it survives an interrupted reply.
    func appendCoachConversationUser(_ text: String) throws {
        // A turn needs both halves; the question is staged in `interview.narratives` until the answer
        // arrives, which is also what the plan request reads as context.
        guard var session = interview else {
            var created = try startInterview()
            try created.addNarrative(text)
            try saveInterview(created)
            return
        }
        try session.addNarrative(text)
        try saveInterview(session)
    }

    /// Stores the completed exchange. Writing both halves together is what keeps the transcript and
    /// what the coach was told from ever disagreeing.
    func appendCoachConversationCoach(_ answer: String) throws {
        guard let session = interview,
              let question = session.narratives?.last?.text, !question.isEmpty else {
            throw CoreError.invalidState("找不到刚才那句话，请再说一次。")
        }
        let context = try CoachContext.make(snapshot: snapshot())
        let reply = CoachReply(answer: answer, evidence: [], limitations: [])
        let turn = CoachTurn(question: question, context: context, reply: reply)
        try saveCoachTurn(turn)
    }
}
