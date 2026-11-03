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

    /// The coach's reply to one message.
    ///
    /// Deliberately plain text, not the structured `CoachAPI.reply`. That protocol requires the model
    /// to emit `{answer, evidence, limitations, proposal}`, and a general chat endpoint answers in
    /// prose — which then failed as "返回内容不是 JSON 对象" after the coach had visibly already
    /// replied. A conversation does not need a schema.
    ///
    /// The structured screen still exists for the cases that genuinely need evidence IDs and a
    /// validated proposal; this is the conversational path.
    static let conversationSystemPrompt = """
    你是本人的私人健身教练，用自然、具体、简短的中文说话，像真人教练。
    你会看到本人已确认的档案、最近的训练记录和统计；只依据这些真实资料作答，没有的数据就说不知道，不要编造。
    不要输出 JSON、字段列表或 Markdown 标题。回答控制在三五句话内。
    涉及伤病、疼痛或医生限制时，不要给运动许可、不要诊断，请本人先确认或就医。
    不要声称已经改动计划；计划由本人单独确认后才生效。
    本人说不想练时，先问一句原因；如果是累或没时间，给一个更小的起步方案；如果说了疼，就让他休息。
    """

    func reply(to question: String, store: TrainingStore) async throws -> String {
        guard let configuration = try AIConfigurationStorage.load() else {
            throw CoachClientError.configuration("先配置 AI 接口，教练才能回答。")
        }
        guard let key = try AIKeychain.load(for: configuration) else {
            throw CoachClientError.configuration("还没有填写本机密钥，先到设置里填写。")
        }
        let context = try CoachContext.make(snapshot: store.snapshot()).withMovementKnowledge(for: question)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let contextJSON = String(decoding: try encoder.encode(context), as: UTF8.self)
        let content = try await client.complete(
            configuration: configuration, key: key,
            messages: [CoachMessage(role: "system", content: Self.conversationSystemPrompt),
                       CoachMessage(role: "user", content: "资料：\(contextJSON)\n\n本人说：\(question)")],
            outputFormat: .text)
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoachClientError.invalidResponse }
        return trimmed
    }

    /// Pulls structured facts out of the free conversation.
    ///
    /// The chat only stores what the person said as narrative text; planning needs the structured
    /// profile (`primaryGoal`, `equipment`, `weekdays`…). Without this step the conversation could
    /// never produce a plan, which is exactly the "聊完什么都没发生" symptom.
    ///
    /// Only *stated* facts are written, and ambiguous ones stay pending for the profile screen to
    /// confirm — the same provenance rules the interview uses.
    /// Fills the profile from the person's own words using local rules.
    ///
    /// This runs before any model call, and is the reason a chat-only endpoint can still produce a
    /// plan: a sentence like 「家里有哑铃和壶铃，每次 30 分钟」 is readable without an LLM. Only
    /// unmistakable statements are taken; everything else stays unknown.
    @discardableResult
    func extractFactsLocally(store: TrainingStore) throws -> Int {
        guard var session = store.interview else { return 0 }
        var applied = 0
        let text = (session.narratives ?? []).map(\.text).joined(separator: "\n")
        guard !text.isEmpty else { return 0 }

        func setIfMissing<T>(_ keyPath: WritableKeyPath<StructuredProfile, ProfileField<T>>, _ value: T?) {
            guard let value, !session.profile[keyPath: keyPath].isUsable else { return }
            session.profile[keyPath: keyPath] = .init(value: value, provenance: .stated,
                                                      confirmedAt: Date(), note: "本人原话")
            applied += 1
        }

        let equipment = LocalFactExtractor.equipment(in: text)
        if !equipment.isEmpty, !session.profile.equipment.isUsable {
            session.profile.equipment = .init(value: equipment.sorted { $0.rawValue < $1.rawValue },
                                              provenance: .stated, confirmedAt: Date(), note: "本人原话")
            applied += 1
        }
        let days = LocalFactExtractor.weekdays(in: text)
        if !days.isEmpty, !session.profile.weekdays.isUsable {
            session.profile.weekdays = .init(value: days, provenance: .stated, confirmedAt: Date(), note: "本人原话")
            applied += 1
        }
        setIfMissing(\.minutesPerSession, LocalFactExtractor.minutesPerSession(in: text))
        setIfMissing(\.primaryGoal, LocalFactExtractor.goal(in: text))
        setIfMissing(\.experience, LocalFactExtractor.experience(in: text))

        if applied > 0 {
            session.updatedAt = Date()
            try store.saveInterview(session)
        }
        return applied
    }

    @discardableResult
    func extractFacts(store: TrainingStore) async throws -> Int {
        guard let configuration = try AIConfigurationStorage.load() else {
            throw CoachClientError.configuration("先配置 AI 接口，教练才能整理资料。")
        }
        guard let key = try AIKeychain.load(for: configuration) else {
            throw CoachClientError.configuration("还没有填写本机密钥，先到设置里填写。")
        }
        guard var session = store.interview else { return 0 }
        let turn = try await InterviewAPI().nextTurn(session: session, configuration: configuration,
                                                     key: key, legacyRestrictions: store.profile.restrictions)
        let accepted = try session.appendTurn(turn)
        var applied = 0
        for extraction in accepted.extractions {
            // `applyExtraction` stores it as inferred unless the person already stated it, so nothing
            // here can turn a guess into a confirmed fact.
            try session.applyExtraction(extraction, at: Date())
            applied += 1
        }
        try store.saveInterview(session)
        return applied
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
