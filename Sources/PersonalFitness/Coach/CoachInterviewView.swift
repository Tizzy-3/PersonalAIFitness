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

    var body: some View {
        List {
            availabilitySection
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
            .disabled(configuration == nil || request != nil || session.phase == .ready || session.phase == .planConfirmed)
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
            Button("提交这些回答") { submitAnswers() }
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
        } header: { Text("下一步") }
    }

    private func syncSection(_ session: InterviewSession) -> some View {
        Section {
            Button("从头开始一份新访谈", role: .destructive) { restart() }
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
        guard let key = try? AIKeychain.load(for: configuration), let key else {
            issue = CoachClientError.configuration("没有找到本机密钥，请先在接口设置中填写。").localizedDescription
            return
        }
        let starting = session ?? (try? store.startInterview())
        guard let starting else { return }
        status = nil
        request = Task {
            defer { request = nil }
            do {
                let api = InterviewAPI()
                let turn = try await api.nextTurn(session: starting, configuration: configuration, key: key)
                var updated = starting
                try updated.appendTurn(turn)
                // Extractions stay provisional until the user confirms them one by one.
                for extraction in turn.extractions {
                    try updated.applyExtraction(extraction)
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
            let input = try session.profile.planningInput()
            let option = try PlannerEngine.synthesize(input: input,
                                                      preferredExerciseIDs: session.profile.preferredExerciseIDs.value ?? [])
            let snapshot = try store.snapshot()
            // The generated week becomes a normal draft, so the existing diff-and-confirm screen
            // applies unchanged — including the second rule check inside PlanningDraft.
            let draft = try PlanningDraft.make(input: input, snapshot: snapshot, option: option)
            try store.savePlanningDraft(draft)
            draftRoute = InterviewDraftRoute(id: draft.id)
        } catch {
            issue = error.localizedDescription
        }
    }

    private func restart() {
        do {
            try store.discardInterview()
            session = try store.startInterview()
            draft = AnswerDraft()
            status = "已开始一份新的访谈。"
        } catch {
            issue = error.localizedDescription
        }
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
