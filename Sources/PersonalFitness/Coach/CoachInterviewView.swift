import SwiftUI
import UIKit
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
    @State private var ownWords = ""
    @State private var formatDiagnostic: String?
    @State private var reviewingEarly = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                availabilitySection
                selfDescriptionSection
                if let formatDiagnostic { diagnosticSection(formatDiagnostic) }
                if let unsavedPlan {
                    CoachPanel {
                        Label("计划尚未保存", systemImage: "exclamationmark.circle")
                            .font(.headline).foregroundStyle(FitnessTheme.orange)
                        Text("AI已返回动作选择，但本地保存未完成。重试保存不需要重复请求模型。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重试保存计划草案") { persistPlan(unsavedPlan) }.buttonStyle(FitnessPrimaryButtonStyle())
                        Button("放弃未保存结果，按最新资料重新制定", role: .destructive) { self.unsavedPlan = nil }
                            .frame(minHeight: 44)
                    }
                }
                if let session {
                    progressSection(session)
                    if !session.unansweredQuestions.isEmpty { answerSection(session) }
                    if !session.pendingInferences.isEmpty { inferenceSection(session) }
                    if session.profile.isReadyForPlanning { planSection(session) }
                    conversationSection(session)
                    syncSection(session)
                }
                if let status {
                    CoachPanel { Label(status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
                }
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(FitnessTheme.canvas)
        .tint(FitnessTheme.accent)
        .navigationTitle("教练建档")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $draftRoute) { route in
            PlanningDraftDetailView(store: store, draftID: route.id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { CoachProfileReviewView(store: store) } label: {
                    Label("档案", systemImage: "person.crop.rectangle").frame(minHeight: 44)
                }
            }
        }
        .task { await prepare() }
        .onChange(of: store.interview) { _, value in session = value }
        .sheet(item: $preparedPlan) { prepared in
            NavigationStack { PersonalizedPlanConsentView(prepared: prepared) { sendPlan(prepared) } }
        }
        .onDisappear { request?.cancel() }
        .confirmationDialog("先跳过本轮未回答问题并核对计划？", isPresented: $reviewingEarly, titleVisibility: .visible) {
            Button("跳过本轮，先核对") { skipForReview() }
            Button("继续回答", role: .cancel) { }
        } message: { Text("这些问题会明确记录为跳过，不猜测答案。关键安全资料或待确认推断仍须本人核对，计划不会自动生效。") }
        .fitnessError($issue)
    }

    private var selfDescriptionSection: some View {
        CoachPanel {
            Text((session?.narratives ?? []).isEmpty ? "先用自己的话介绍一下" : "还有想让教练知道的吗？").font(.headline)
            Text("可以聊你想达到什么变化、现在能做什么、在哪练、时间和身体顾虑。愿意说多少都可以，教练会按你的回答具体追问。")
                .font(.footnote).foregroundStyle(.secondary)
            TextField("比如具体目标、过去训练经历、器械与日程……", text: $ownWords, axis: .vertical)
                .lineLimit(3...8).padding(12).background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                .disabled(request != nil)
            HStack {
                Text("\(ownWords.count) / 6000").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("保存我的补充") { saveOwnWords() }
                    .disabled(request != nil || ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ownWords.count > 6000)
                    .frame(minHeight: 44)
            }
            if !(session?.narratives ?? []).isEmpty {
                DisclosureGroup("已保存的本人叙述（\((session?.narratives ?? []).count)）") {
                    ForEach(session?.narratives ?? []) { entry in
                        Text(entry.text).font(.footnote).textSelection(.enabled).padding(.vertical, 6)
                    }
                }.font(.footnote)
            }
        }
    }

    private func diagnosticSection(_ value: String) -> some View {
        CoachPanel {
            Label("访谈格式未通过校验", systemImage: "exclamationmark.circle").font(.headline).foregroundStyle(FitnessTheme.orange)
            Text("已保留你的资料。本轮最多进行一次格式纠正，不会无限重试，也不会采用格式不合法的内容。")
                .font(.footnote).foregroundStyle(.secondary)
            DisclosureGroup("查看脱敏格式诊断") { Text(value).font(.caption.monospaced()).textSelection(.enabled) }
            Button("复制格式诊断") { UIPasteboard.general.string = value }.frame(minHeight: 44)
            Button("重新询问") { Task { await askNext() } }.disabled(request != nil || configuration == nil || session?.canContinueInterview != true)
        }
    }

    private func saveOwnWords() {
        do {
            var current = try session ?? store.startInterview()
            try current.addNarrative(ownWords)
            try store.saveInterview(current)
            session = store.interview; ownWords = ""
            status = "你的原话已保存。点继续访谈，教练会结合这些情况追问；不会直接猜成已确认档案。"
        } catch { issue = error.localizedDescription }
    }

    private func setPaused(_ paused: Bool) {
        guard var current = session else { return }
        do {
            if paused { try current.pause() } else { try current.resume() }
            try store.saveInterview(current); session = store.interview
        } catch { issue = error.localizedDescription }
    }

    private func skipForReview() {
        guard var current = session else { return }
        do {
            try current.skipUnansweredForReview(); try store.saveInterview(current)
            session = store.interview; draft = AnswerDraft()
            status = "本轮剩余问题已明确记为跳过。可先核对档案；基础条件齐备且无待确认项后，可制定保守首版计划。"
        } catch { issue = error.localizedDescription }
    }

    // MARK: - Sections

    private var availabilitySection: some View {
        CoachPanel {
            HStack(spacing: 12) {
                CoachIconBadge(symbol: "person.text.rectangle", color: FitnessTheme.violet)
                VStack(alignment: .leading, spacing: 5) {
                    Text("把你的情况，慢慢聊清楚").font(.headline)
                    Text(configuration == nil ? "先连接你选择的 AI 服务" : "使用 \(configuration?.model ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if configuration == nil {
                NavigationLink { AISettingsView() } label: { Label("配置接口与本机密钥", systemImage: "slider.horizontal.3") }
                    .frame(minHeight: 44)
                Text("访谈需要联网。尚未配置时不会开始，也不会用预设内容假装是教练提问。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                DisclosureGroup("这次访谈会发送哪些内容") {
                    Text("你的回答会发送给已配置的服务。保存的本人叙述和完整访谈会一起发送（可能含你输入的身体/限制说明）。不会自动发送Apple健康原始样本。推断的结构化值会先请你核对。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.footnote)
            }
        }
    }

    private func progressSection(_ session: InterviewSession) -> some View {
        CoachPanel {
            HStack(alignment: .firstTextBaseline) {
                Text("正在了解你的情况").font(.headline)
                Spacer(minLength: 8)
                CoachStatusPill(text: session.phase.title, color: FitnessTheme.violet)
            }
            Text("已确认 \(session.profile.answeredTopics.count) 项资料 · 已聊 \(session.allTurns.count) 轮")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(session.profile.isReadyForPlanning ? "基础条件已具备，仍可继续聊具体目标、能力和生活细节。" : "先了解你，再逐步核对安排训练必需的关键条件。")
                .font(.footnote).foregroundStyle(.secondary)
            if session.pausedAt != nil {
                Label("已暂停，回答和补充都已保留", systemImage: "pause.circle").font(.footnote).foregroundStyle(FitnessTheme.orange)
                Button("恢复访谈") { setPaused(false) }.frame(minHeight: 44)
            }
            if !session.pendingInferences.isEmpty {
                Label("\(session.pendingInferences.count) 项推断等待你核对", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.footnote).foregroundStyle(FitnessTheme.orange)
            }
            if !session.profile.missingRequiredTopics.isEmpty {
                DisclosureGroup("制定计划前还需要的资料") {
                    Text(session.profile.missingRequiredTopics.map(\.title).joined(separator: "、"))
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                }.font(.footnote)
            }
            Button { Task { await askNext() } } label: {
                Label(request == nil ? "继续访谈" : "正在询问…", systemImage: "bubble.left.and.bubble.right")
            }
            .buttonStyle(FitnessPrimaryButtonStyle())
            .disabled(configuration == nil || request != nil || !session.canContinueInterview)
            if request != nil {
                HStack {
                    ProgressView()
                    Text("等待教练回应").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消请求") { request?.cancel() }.font(.footnote).frame(minHeight: 44)
                }
            } else if !session.unansweredQuestions.isEmpty {
                Text("先回答下面的问题。不清楚时，可以明确选择不知道或跳过。")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.profile.isReadyForPlanning, session.canContinueInterview {
                Text("已经可以制定保守首版计划，也能继续补充能力、偏好和坚持困难。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func conversationSection(_ session: InterviewSession) -> some View {
        CoachPanel {
            DisclosureGroup {
                if session.turns.isEmpty {
                    Text("还没有开始。点“继续访谈”，教练会先问你几个问题。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(session.turns.suffix(6)) { turn in
                    ForEach(turn.questions) { question in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(question.prompt).font(.subheadline.weight(.semibold))
                            if let answer = turn.answers.first(where: { $0.questionID == question.id }) {
                                Text("你：\(InterviewAPI.describe(answer))").font(.footnote).foregroundStyle(.secondary)
                            } else {
                                CoachStatusPill(text: "待回答", color: FitnessTheme.orange)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
                        Divider()
                    }
                }
            } label: {
                Label("对话记录 · \(session.turns.count) 轮", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private func answerSection(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "告诉教练", detail: "\(session.unansweredQuestions.count) 个待回答问题")
            CoachPanel {
                ForEach(session.unansweredQuestions) { question in
                    QuestionAnswerRow(question: question, draft: $draft)
                    if question.id != session.unansweredQuestions.last?.id { Divider() }
                }
                Button("提交这些回答") { submitAnswers() }
                    .buttonStyle(FitnessPrimaryButtonStyle()).disabled(request != nil)
            }
        }
    }

    private func inferenceSection(_ session: InterviewSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "这些理解，对吗？", detail: "待你确认")
            CoachPanel {
                ForEach(session.pendingInferences, id: \.self) { topic in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(topic.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            CoachStatusPill(text: "推断", color: FitnessTheme.orange)
                        }
                        Text(InterviewAPI.describe(topic, profile: session.profile))
                            .font(.footnote).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("对，是这样") { confirm(topic, accept: true) }.tint(FitnessTheme.accent)
                            Button("不对，删掉", role: .destructive) { confirm(topic, accept: false) }
                        }.buttonStyle(.bordered).controlSize(.large)
                    }.padding(.vertical, 4)
                }
                Text("推断还不算事实。只有你确认的资料，才会用于安排训练。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func planSection(_ session: InterviewSession) -> some View {
        CoachPanel {
            HStack(spacing: 12) {
                CoachIconBadge(symbol: "calendar.badge.plus", color: FitnessTheme.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text("可以制定第一份计划了").font(.headline)
                    Text("先看完整七天安排，你确认后才生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button { generatePlan(session) } label: { Label("生成第一版计划", systemImage: "calendar.badge.plus") }
                .buttonStyle(FitnessPrimaryButtonStyle())
                .disabled(request != nil || configuration == nil || !session.unansweredQuestions.isEmpty || !session.pendingInferences.isEmpty || unsavedPlan != nil)
        }
    }

    private func syncSection(_ session: InterviewSession) -> some View {
        CoachPanel {
            if request == nil, session.pausedAt == nil {
                Button("暂停，稍后继续") { setPaused(true) }.frame(minHeight: 44)
            }
            NavigationLink { CoachProfileReviewView(store: store) } label: { Label("先核对已聊到的资料", systemImage: "person.crop.rectangle") }.frame(minHeight: 44)
            if !session.unansweredQuestions.isEmpty {
                Button("跳过本轮剩余问题，先核对计划") { reviewingEarly = true }.disabled(request != nil).frame(minHeight: 44)
            }
            DisclosureGroup("访谈管理") {
                Button("保留已确认档案，重新访谈") { restart() }.disabled(request != nil).frame(minHeight: 44)
                Text("已确认资料留在档案里，不会因为重新访谈而消失。")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline)
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
        formatDiagnostic = nil
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
                if turn.formatRepairUsed == true { status = "本轮回复格式已自动纠正一次并通过校验。你的原话保留，尚未改变计划。" }
                else if turn.jsonModeFallbackUsed == true { status = "服务不支持JSON模式，已使用兼容模式并完成结构校验。" }
                if turn.questions.isEmpty, !updated.profile.isReadyForPlanning {
                    status = "教练这次没有提出新问题。可以再点“继续访谈”，或先在档案页手动补充。"
                }
            } catch {
                if let error = error as? InterviewProtocolError { formatDiagnostic = error.diagnostic }
                else if let clientError = error as? CoachClientError, clientError == .outputTruncated {
                    formatDiagnostic = "interview-json-v2\nstage=response-envelope\nfinish_reason=length\ncategory=output_truncated\n原文未保存；已有资料未改变。"
                }
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
            status = "已保留本人确认资料、本人叙述和旧对话归档，仅清除未确认推断，开始新的访谈阶段。"
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
            }.buttonStyle(.bordered).controlSize(.large)
        }.padding(12)
            .background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
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
