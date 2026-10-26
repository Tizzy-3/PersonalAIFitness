import SwiftUI
import FitnessCore

/// The interview screen: AI asks, the user answers, then the user reviews and confirms every inferred
/// value before anything can be planned.
@MainActor
struct CoachInterviewView: View {
    let store: TrainingStore
    @State private var session: InterviewSession?
    @State private var request: Task<Void, Never>?
    @State private var issue: String?
    @State private var status: String?
    @State private var draft: AnswerDraft = AnswerDraft()
    @State private var configuration: AIConfiguration?
    @State private var draftRoute: InterviewDraftRoute?
    @State private var preparedPlan: PreparedPersonalizedPlan?
    @State private var unsavedPlan: PlanningDraft?

    var body: some View {
        List {
            availabilitySection
            if let unsavedPlan {
                Section("计划尚未保存") {
                    Text("AI已返回动作选择，但本地保存未完成。请重试保存，不需要重复请求模型。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试保存计划草案") { persistPlan(unsavedPlan) }
                    Button("放弃未保存结果，按最新资料重新制定", role: .destructive) { self.unsavedPlan = nil }
                }
            }
            if let session {
                progressSection(session)
                conversationSection(session)
                if !session.unansweredQuestions.isEmpty {
                    answerSection(session)
                }
                if !session.pendingInferences.isEmpty {
                    inferenceSection(session)
                }
                if session.profile.isReadyForPlanning {
                    planSection(session)
                }
                syncSection(session)
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("AI 教练 · 建档")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $draftRoute) { route in
            PlanningDraftDetailView(store: store, draftID: route.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { CoachProfileReviewView(store: store) } label: { Text("档案") }
            }
        }
        .task { await prepare() }
        .onChange(of: store.interview) { _, value in session = value }
        .sheet(item: $preparedPlan) { prepared in
            NavigationStack { PersonalizedPlanConsentView(prepared: prepared) { sendPlan(prepared) } }
        }
        .onDisappear { request?.cancel() }
        .fitnessError($issue)
    }

    // MARK: - Sections

    private var availabilitySection: some View {
        Section {
            if configuration == nil {
                Text("还没有配置 AI 接口。建档访谈需要联网调用你配置的服务，未配置时不会开始，也不会用预设内容假装是教练的提问。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { AISettingsView() } label: { Label("去配置接口与密钥", systemImage: "slider.horizontal.3") }
            } else {
                Text("访谈会把你回答的内容发送给你配置的服务（\(configuration?.model ?? "")）。健康数据不会在访谈中发送。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("访谈需要联网") }
    }

    private func progressSection(_ session: InterviewSession) -> some View {
        Section("进度") {
            LabeledContent("阶段", value: session.phase.title)
            LabeledContent("已确认信息", value: "\(session.profile.answeredTopics.count) 项")
            LabeledContent("待确认推断", value: "\(session.pendingInferences.count) 项")
            if !session.profile.missingRequiredTopics.isEmpty {
                Text("还缺少：" + session.profile.missingRequiredTopics.map(\.title).joined(separator: "、"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button {
                Task { await askNext() }
            } label: {
                Label(request == nil ? "继续访谈" : "正在询问…", systemImage: "bubble.left.and.bubble.right")
            }
            .disabled(configuration == nil || request != nil || !session.canContinueInterview)
            if !session.unansweredQuestions.isEmpty {
                Text("请先处理下面未回答的问题；不清楚时可明确选择未知或跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.profile.isReadyForPlanning, session.canContinueInterview {
                Text("已经可以制定保守首版计划，也可以继续补充实际能力、偏好和坚持困难，让教练更了解你。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func conversationSection(_ session: InterviewSession) -> some View {
        Section("对话") {
            if session.turns.isEmpty {
                Text("还没有开始。点“继续访谈”后，教练会先问你几个问题。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(session.turns.suffix(6)) { turn in
                ForEach(turn.questions) { question in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(question.prompt).font(.subheadline.weight(.semibold))
                        if let answer = turn.answers.first(where: { $0.questionID == question.id }) {
                            Text("你：\(InterviewAPI.describe(answer))").font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("待回答").font(.footnote).foregroundStyle(.orange)
                        }
                    }.padding(.vertical, 2)
                }
            }
        }
    }

    private func answerSection(_ session: InterviewSession) -> some View {
        Section("回答") {
            ForEach(session.unansweredQuestions) { question in
                QuestionAnswerRow(question: question, draft: $draft)
            }
            Button("提交这些回答") { submitAnswers() }.disabled(request != nil)
        }
    }

    private func inferenceSection(_ session: InterviewSession) -> some View {
        Section {
            ForEach(session.pendingInferences, id: \.self) { topic in
                VStack(alignment: .leading, spacing: 6) {
                    Text(topic.title).font(.subheadline.weight(.semibold))
                    Text("教练的推断：" + InterviewAPI.describe(topic, profile: session.profile))
                        .font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Button("对，是这样") { confirm(topic, accept: true) }
                        Button("不对，删掉") { confirm(topic, accept: false) }.foregroundStyle(.red)
                    }.buttonStyle(.borderless)
                }.padding(.vertical, 2)
            }
        } header: { Text("待你确认的推断") } footer: {
            Text("这些是教练从你的话里推断的，还没算数。你确认之后才会用于制定计划。")
        }
    }

    private func planSection(_ session: InterviewSession) -> some View {
        Section {
            Text("信息够了，可以让教练按你的情况组合第一版计划。生成后会先给你看完整的七天安排，你确认才生效。")
                .font(.footnote).foregroundStyle(.secondary)
            Button {
                generatePlan(session)
            } label: { Label("生成第一版计划", systemImage: "calendar.badge.plus") }
                .disabled(request != nil || configuration == nil || !session.unansweredQuestions.isEmpty || !session.pendingInferences.isEmpty || unsavedPlan != nil)
        } header: { Text("下一步") }
    }

    private func syncSection(_ session: InterviewSession) -> some View {
        Section {
            Button("保留已确认档案，重新访谈") { restart() }.disabled(request != nil)
        } footer: {
            Text("已确认的档案会保留在“档案”页，不会因为重新访谈而消失。")
        }
    }

    // MARK: - Actions

    private func prepare() async {
        do {
            configuration = try AIConfigurationStorage.load()
        } catch {
            issue = error.localizedDescription
        }
        do {
            session = try store.startInterview()
        } catch {
            issue = error.localizedDescription
        }
    }

    private func askNext() async {
        guard let configuration, request == nil else { return }
        let storedKey = try? AIKeychain.load(for: configuration)
        guard let key = storedKey ?? nil else {
            issue = CoachClientError.configuration("没有找到本机密钥，请先在接口设置中填写。").localizedDescription
            return
        }
        let starting = session ?? (try? store.startInterview())
        guard let starting else { return }
        guard starting.canContinueInterview else { return }
        status = nil
        request = Task {
            defer { request = nil }
            do {
                let api = InterviewAPI()
                let turn = try await api.nextTurn(session: starting, configuration: configuration, key: key)
                try Task.checkCancellation()
                guard store.interview == starting else {
                    throw CoreError.invalidState("访谈已在请求期间被修改，旧回答没有覆盖最新资料。请重新询问。")
                }
                var updated = starting
                let accepted = try updated.appendTurn(turn)
                // Extractions stay provisional until the user confirms them one by one.
                for extraction in accepted.extractions {
                    try updated.applyExtraction(extraction, at: Date())
                }
                try store.saveInterview(updated)
                session = store.interview
                draft = AnswerDraft()
                if turn.questions.isEmpty, !updated.profile.isReadyForPlanning {
                    status = "教练这次没有提出新问题。可以再点“继续访谈”，或先在档案页手动补充。"
                }
            } catch {
                issue = error.localizedDescription
            }
        }
        await request?.value
    }

    private func submitAnswers() {
        guard var current = session else { return }
        let answers = draft.answers(for: current.unansweredQuestions)
        guard !answers.isEmpty else { issue = "请先回答至少一个问题。"; return }
        do {
            try current.answer(answers)
            try store.saveInterview(current)
            session = store.interview
            draft = AnswerDraft()
        } catch {
            issue = error.localizedDescription
        }
    }

    private func confirm(_ topic: InterviewTopic, accept: Bool) {
        guard var current = session else { return }
        do {
            try current.confirmInference(topic, accept: accept)
            try store.saveInterview(current)
            session = store.interview
        } catch {
            issue = error.localizedDescription
        }
    }

    private func generatePlan(_ session: InterviewSession) {
        do {
            guard store.activeSession == nil else {
                throw CoreError.invalidState("请先结束或取消正在进行的训练，再生成新的生效计划。")
            }
            guard let configuration else { throw CoachClientError.configuration("请先配置AI接口，再让教练制定计划。") }
            let context = try PersonalizedPlanRequest.make(session: session, snapshot: store.snapshot())
            preparedPlan = PreparedPersonalizedPlan(configuration: configuration, session: session, context: context,
                                                    preview: try PersonalizedPlannerAPI.requestJSON(context))
        } catch {
            issue = error.localizedDescription
        }
    }

    private func restart() {
        do {
            guard let current = store.interview else { return }
            try store.saveInterview(current.restartedPreservingProfile())
            session = store.interview
            draft = AnswerDraft()
            status = "已保留本人确认的资料，清除旧对话及待确认推断，开始新的访谈。"
        } catch {
            issue = error.localizedDescription
        }
    }

    private func sendPlan(_ prepared: PreparedPersonalizedPlan) {
        preparedPlan = nil
        guard request == nil else { return }
        request = Task {
            defer { request = nil }
            do {
                guard let key = try AIKeychain.load(for: prepared.configuration) else {
                    throw CoachClientError.configuration("当前服务没有本机密钥，请先在接口设置中填写。")
                }
                let reply = try await PersonalizedPlannerAPI().compose(prepared.context, configuration: prepared.configuration, key: key)
                try Task.checkCancellation()
                guard store.interview == prepared.session,
                      prepared.context.baseline.matches(snapshot: try store.snapshot()) else {
                    throw CoreError.invalidState("请求期间档案、训练记录或生效安排发生变化，请按最新资料重新制定。")
                }
                let result = try PlanningDraft.makePersonalized(profile: prepared.session.profile, reply: reply,
                                                               snapshot: store.snapshot(),
                                                               providerHost: prepared.configuration.validatedURL().host ?? "未知",
                                                               model: prepared.configuration.model)
                unsavedPlan = result
                persistPlan(result)
            } catch is CancellationError {
                status = "本次请求已取消，原计划未变。"
            } catch { issue = error.localizedDescription }
        }
    }

    private func persistPlan(_ plan: PlanningDraft) {
        do {
            guard plan.matches(snapshot: try store.snapshot()) else {
                throw CoreError.invalidState("这份草案的依据已变化，请重新制定，旧结果不会覆盖当前安排。")
            }
            try store.savePlanningDraft(plan)
            unsavedPlan = nil
            draftRoute = InterviewDraftRoute(id: plan.id)
        } catch { issue = error.localizedDescription }
    }
}

/// Local answer state. Nothing here reaches the profile until the user submits it.
struct AnswerDraft {
    var choices: [UUID: String] = [:]
    var multiChoices: [UUID: Set<String>] = [:]
    var numbers: [UUID: String] = [:]
    var texts: [UUID: String] = [:]
    var booleans: [UUID: Bool] = [:]
    var unknown: Set<UUID> = []
    var skipped: Set<UUID> = []

    func answers(for questions: [InterviewQuestion]) -> [InterviewAnswer] {
        questions.compactMap { question in
            if unknown.contains(question.id) {
                return InterviewAnswer(questionID: question.id, outcome: .unknown)
            }
            if skipped.contains(question.id) {
                return InterviewAnswer(questionID: question.id, outcome: .skipped)
            }
            switch question.kind {
            case .singleChoice:
                guard let choice = choices[question.id] else { return nil }
                return InterviewAnswer(questionID: question.id, choice: choice)
            case .multiChoice:
                guard let selected = multiChoices[question.id], !selected.isEmpty else { return nil }
                return InterviewAnswer(questionID: question.id, choices: selected.sorted())
            case .number:
                guard let text = numbers[question.id],
                      let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
                return InterviewAnswer(questionID: question.id, number: value)
            case .text:
                guard let text = texts[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return InterviewAnswer(questionID: question.id, text: text)
            case .boolean:
                guard let flag = booleans[question.id] else { return nil }
                return InterviewAnswer(questionID: question.id, boolean: flag)
            }
        }
    }
}

@MainActor
private struct QuestionAnswerRow: View {
    let question: InterviewQuestion
    @Binding var draft: AnswerDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.prompt).font(.subheadline.weight(.semibold))
            input
            HStack {
                if question.allowUnknown {
                    Button(draft.unknown.contains(question.id) ? "✓ 不知道" : "不知道") { toggle(&draft.unknown) }
                        .font(.footnote)
                }
                if question.allowSkip {
                    Button(draft.skipped.contains(question.id) ? "✓ 跳过" : "跳过") { toggle(&draft.skipped) }
                        .font(.footnote)
                }
            }.buttonStyle(.borderless)
        }.padding(.vertical, 4)
    }

    @ViewBuilder private var input: some View {
        switch question.kind {
        case .singleChoice:
            Picker("", selection: Binding(
                get: { draft.choices[question.id] ?? "" },
                set: { draft.choices[question.id] = $0; draft.unknown.remove(question.id); draft.skipped.remove(question.id) }
            )) {
                Text("请选择").tag("")
                ForEach(question.options, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu)
        case .multiChoice:
            ForEach(question.options, id: \.self) { option in
                Button {
                    var selected = draft.multiChoices[question.id] ?? []
                    if selected.contains(option) { selected.remove(option) } else { selected.insert(option) }
                    draft.multiChoices[question.id] = selected
                } label: {
                    HStack {
                        Image(systemName: (draft.multiChoices[question.id] ?? []).contains(option) ? "checkmark.circle.fill" : "circle")
                        Text(option).font(.footnote)
                    }
                }.buttonStyle(.borderless)
            }
        case .number:
            HStack {
                TextField("输入数字", text: Binding(
                    get: { draft.numbers[question.id] ?? "" },
                    set: { draft.numbers[question.id] = $0 }
                )).keyboardType(.decimalPad)
                if let unit = question.unit { Text(unit).font(.footnote).foregroundStyle(.secondary) }
            }
        case .text:
            TextField("输入回答", text: Binding(
                get: { draft.texts[question.id] ?? "" },
                set: { draft.texts[question.id] = $0 }
            ), axis: .vertical).lineLimit(1...4)
        case .boolean:
            Toggle("是", isOn: Binding(
                get: { draft.booleans[question.id] ?? false },
                set: { draft.booleans[question.id] = $0 }
            ))
        }
    }

    private func toggle(_ set: inout Set<UUID>) {
        if set.contains(question.id) { set.remove(question.id) } else { set.insert(question.id) }
    }
}
