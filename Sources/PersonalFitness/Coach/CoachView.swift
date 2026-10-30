import SwiftUI
import FitnessCore

private struct PreparedCoachRequest: Identifiable {
    let id = UUID()
    let configuration: AIConfiguration
    let question: String
    let context: CoachContext
    let preview: String
}

@MainActor
struct CoachView: View {
    let store: TrainingStore
    @State private var question = ""
    @State private var prepared: PreparedCoachRequest?
    @State private var request: Task<Void, Never>?
    @State private var requestQuestion: String?
    @State private var unsavedTurn: CoachTurn?
    @State private var issue: String?
    @State private var status: String?
    @State private var askingQuestions = false
    @State private var lastSavedTurnID: UUID?
    @State private var replanningFromChat = false

    init(store: TrainingStore, initialQuestion: String = "") {
        self.store = store
        _question = State(initialValue: initialQuestion)
        _askingQuestions = State(initialValue: !initialQuestion.isEmpty)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                onboardingCard
                if let program = store.currentWeeklyProgram {
                    NavigationLink { WeeklyProgramDetailView(store: store, programID: program.id) } label: {
                        CoachNavigationLabel(title: "我的训练计划", subtitle: "看看这周怎么练", symbol: "calendar", color: FitnessTheme.accent)
                    }.buttonStyle(.plain)
                }
                if store.pendingAdjustment != nil {
                    NavigationLink { AdjustmentReviewView(store: store) } label: {
                        CoachNavigationLabel(title: "教练有个调整建议", subtitle: "看看原因，再由你决定", symbol: "arrow.triangle.2.circlepath", color: FitnessTheme.violet)
                    }.buttonStyle(.plain)
                }
                DisclosureGroup("今天的状态与复盘") { dailyCard.padding(.top, 12) }
                DisclosureGroup("想单独问教练", isExpanded: $askingQuestions) {
                    questionCard.padding(.top, 12)
                    if request == nil && unsavedTurn == nil { promptsCard }
                }
                if let turn = unsavedTurn { unsavedCard(turn) }
                DisclosureGroup("更多：手动安排与聊天记录") {
                    planningCard.padding(.top, 12)
                    historyCard
                    scopeCard
                }
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(FitnessTheme.canvas)
        .navigationTitle("AI 教练")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AISettingsView() } label: {
                    Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel("配置 AI 接口与本机密钥")
            }
        }
        .sheet(item: $prepared) { prepared in
            NavigationStack { CoachConsentView(prepared: prepared, send: { send(prepared) }) }
        }
        .navigationDestination(isPresented: $replanningFromChat) { CoachInterviewView(store: store) }
        .onDisappear { request?.cancel() }
        .fitnessError($issue)
    }

    private var onboardingCard: some View {
        CoachPanel {
            HStack(alignment: .top, spacing: 12) {
                CoachIconBadge(symbol: "person.text.rectangle", color: FitnessTheme.violet)
                VStack(alignment: .leading, spacing: 6) {
                    Text("先了解你，再安排训练").font(.title3.weight(.semibold))
                    Text("从目标、身体情况与实际条件开始，一起建立适合你的计划。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            NavigationLink { CoachInterviewView(store: store) } label: {
                Label("生成训练计划", systemImage: "calendar.badge.plus")
            }.buttonStyle(FitnessPrimaryButtonStyle())
            Text("需要补资料时，教练会主动问你，你只需回答。进入后会把已存档案和对话发给你配置的 AI 服务。")
                .font(.caption).foregroundStyle(.secondary)
            NavigationLink { CoachInterviewView(store: store, continueInDepth: true) } label: {
                Label("让教练继续问我", systemImage: "bubble.left.and.bubble.right")
            }.frame(minHeight: 44)
            NavigationLink { CoachProfileReviewView(store: store) } label: {
                HStack {
                    Text("核对我的训练档案").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).foregroundStyle(FitnessTheme.accent)
        }
    }

    private var dailyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "每天跟进", detail: "记录 · 判断 · 再调整")
            CoachPanel {
                NavigationLink { CheckInView(store: store) } label: {
                    CoachNavigationLabel(title: "训练前记录", subtitle: "今天的时间、疲劳与不适", symbol: "checklist", color: FitnessTheme.teal)
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { ReadinessView(store: store) } label: {
                    CoachNavigationLabel(title: "身体状态与建议", subtitle: "分别看安全、证据与不确定性", symbol: "waveform.path.ecg", color: FitnessTheme.orange)
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { AdjustmentReviewView(store: store) } label: {
                    CoachNavigationLabel(title: "调整建议", subtitle: store.pendingAdjustment == nil ? "确认后才改变安排" : "有建议等待你确认", symbol: "arrow.triangle.2.circlepath", color: FitnessTheme.violet)
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { ReviewView(store: store) } label: {
                    CoachNavigationLabel(title: "周月复盘", subtitle: "回看实际完成与变化", symbol: "chart.line.uptrend.xyaxis", color: FitnessTheme.accent)
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HealthStatusView(store: store) } label: {
                    CoachNavigationLabel(title: "Apple 健康", subtitle: "来源、更新时间与数据缺口", symbol: "heart.text.square", color: FitnessTheme.teal)
                }.buttonStyle(.plain)
            }
        }
    }

    private var planningCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "训练安排")
            CoachPanel {
                if let program = store.currentWeeklyProgram {
                    NavigationLink { WeeklyProgramDetailView(store: store, programID: program.id) } label: {
                        CoachNavigationLabel(title: "我的每周安排", subtitle: "查看已确认的训练日与休息日", symbol: "calendar", color: FitnessTheme.accent)
                    }.buttonStyle(.plain)
                    Divider()
                }
                NavigationLink { PlannerView(store: store) } label: {
                    CoachNavigationLabel(title: "直接填写训练条件", subtitle: "已明确条件时，查看保守规则候选", symbol: "calendar.badge.plus", color: FitnessTheme.accent)
                }.buttonStyle(.plain)
            }
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "问教练", detail: "发送前可核对资料")
            CoachPanel {
                TextField("想聊训练、计划，还是最近的变化？", text: $question, axis: .vertical)
                    .lineLimit(3...10).padding(12)
                    .background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(request != nil || unsavedTurn != nil)
                    .accessibilityLabel("给教练的问题")
                if question.count > 4_000 { Text("问题超过 4000 字，请缩短。").font(.footnote).foregroundStyle(.red) }
                if request == nil && unsavedTurn == nil {
                    Button("预览数据并准备发送", systemImage: "paperplane") { prepare() }
                        .buttonStyle(FitnessPrimaryButtonStyle())
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4_000)
                }
                if request != nil {
                    HStack {
                        ProgressView()
                        Text("等待模型回答…").font(.subheadline)
                        Spacer()
                        Button("取消") { request?.cancel() }.frame(minHeight: 44)
                    }
                    Text(requestQuestion ?? "").font(.footnote).foregroundStyle(.secondary)
                }
                if let id = lastSavedTurnID, let turn = store.coachTurns.first(where: { $0.id == id }) {
                    Text(turn.reply.answer).font(.callout).textSelection(.enabled)
                    if store.currentWeeklyProgram != nil {
                        Button("让教练按这个情况调整计划") {
                            do {
                                try store.continuePlanning(from: turn.question)
                                replanningFromChat = true
                            } catch { issue = error.localizedDescription }
                        }.buttonStyle(.borderedProminent)
                    }
                }
                if let status { Label(status, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private var promptsCard: some View {
        CoachPanel {
            Text("从一个具体问题开始").font(.subheadline.weight(.semibold))
            Button { question = "请解释当前计划的动作安排与记录方式，指出已有依据和目前缺少的信息，不修改计划。" } label: {
                CoachNavigationLabel(title: "解释当前计划", subtitle: "了解动作与安排的依据", symbol: "list.bullet.rectangle")
            }.buttonStyle(.plain)
            Divider()
            Button { question = "请依据近28天程序统计和最近训练记录复盘，区分已有证据与未知信息，不编造成绩。" } label: {
                CoachNavigationLabel(title: "复盘最近训练", subtitle: "从真实记录里找到下一步", symbol: "clock.arrow.circlepath", color: FitnessTheme.teal)
            }.buttonStyle(.plain)
            Divider()
            Button { question = "今天可训练时间比原计划少。请先解释保留和减少哪些训练的取舍；如依据充分，只提出同动作同顺序的保守减量草案，等待我确认。" } label: {
                CoachNavigationLabel(title: "今天时间不够", subtitle: "讨论保留什么、减少什么", symbol: "timer", color: FitnessTheme.orange)
            }.buttonStyle(.plain)
        }
    }

    private func unsavedCard(_ turn: CoachTurn) -> some View {
        CoachPanel {
            Label("回答尚未保存", systemImage: "exclamationmark.circle").font(.headline).foregroundStyle(FitnessTheme.orange)
            Text(turn.reply.answer).textSelection(.enabled)
            Text("模型已经返回回答，但本地保存失败。请重试保存，无需再次请求模型；离开页面可能丢失这次未保存回答。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("重试保存这次回答") { persist(turn) }.buttonStyle(FitnessPrimaryButtonStyle())
        }
    }

    private var historyCard: some View {
        let turns = store.coachTurns.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 12) {
            CoachSectionHeading(title: "教练记录", detail: "\(store.coachTurns.count) 次对话")
            CoachPanel {
                if store.coachTurns.isEmpty {
                    HStack(spacing: 12) {
                        CoachIconBadge(symbol: "text.bubble", color: FitnessTheme.violet)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("你的第一段对话，还未开始").font(.subheadline.weight(.semibold))
                            Text("保存后的回答和建议会留在这里。").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 6)
                }
                ForEach(turns) { turn in
                    NavigationLink { CoachTurnDetailView(store: store, turnID: turn.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.question).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            Text(turn.reply.answer).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(turn.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if turn.reply.proposal != nil { CoachStatusPill(text: decisionTitle(turn.decision), color: FitnessTheme.violet) }
                            }
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                    if turn.id != turns.last?.id { Divider() }
                }
            }
        }
    }

    private var scopeCard: some View {
        CoachPanel {
            DisclosureGroup("数据与能力说明") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("每次发送前可查看实际数据。AI 的回答本身不会修改生效计划，调整需要你另外确认。")
                    Text("建档访谈会详细询问你的情况与目标；猜测的内容要先核对。已明确训练条件时，可直接填写条件查看保守规则候选。")
                    Text("说出最近的变化后，可以让教练结合已保存资料重新安排一周；确认前不会改变现有计划。模型解释可能有误。")
                    NavigationLink { AISettingsView() } label: { Label("接口、模型与本机密钥", systemImage: "slider.horizontal.3") }
                }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.subheadline)
        }
    }

    private func prepare() {
        do {
            guard let configuration = try AIConfigurationStorage.load() else {
                throw CoachClientError.configuration("请先进入 AI 接口配置，填写并保存完整地址、模型名称和密钥。")
            }
            guard try AIKeychain.load(for: configuration) != nil else {
                throw CoachClientError.configuration("当前服务器还没有本机密钥，请先在 AI 接口中填写。")
            }
            let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = try CoachContext.make(snapshot: store.snapshot()).withMovementKnowledge(for: question)
            let preview = try CoachAPI.requestJSON(question: question, context: context)
            prepared = PreparedCoachRequest(configuration: configuration, question: question, context: context, preview: preview)
        } catch { issue = error.localizedDescription }
    }

    private func send(_ prepared: PreparedCoachRequest) {
        self.prepared = nil
        status = nil
        requestQuestion = prepared.question
        request = Task {
            defer { request = nil; requestQuestion = nil }
            do {
                guard let key = try AIKeychain.load(for: prepared.configuration) else {
                    throw CoachClientError.configuration("本次预览对应服务器的密钥已不存在，请重新填写后发送。")
                }
                let reply = try await CoachAPI().reply(question: prepared.question, context: prepared.context,
                                                       configuration: prepared.configuration, key: key)
                try Task.checkCancellation()
                let turn = CoachTurn(question: prepared.question, context: prepared.context, reply: reply)
                unsavedTurn = turn
                persist(turn)
            } catch is CancellationError { status = "已取消请求，没有自动重试。" }
            catch { issue = error.localizedDescription }
        }
    }

    private func persist(_ turn: CoachTurn) {
        do {
            try store.saveCoachTurn(turn)
            lastSavedTurnID = turn.id
            unsavedTurn = nil
            if question.trimmingCharacters(in: .whitespacesAndNewlines) == turn.question { question = "" }
            status = "回答已保存在教练记录中。含计划建议时，打开记录查看原方案与建议，再决定是否确认。"
        } catch { unsavedTurn = turn; issue = error.localizedDescription }
    }
}

private func decisionTitle(_ decision: CoachDecision) -> String {
    switch decision { case .pending: return "待你确认"; case .accepted: return "已确认"; case .rejected: return "已拒绝" }
}

@MainActor
private struct CoachConsentView: View {
    let prepared: PreparedCoachRequest
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("发送到哪里") {
                Text(prepared.configuration.destination).font(.footnote.monospaced()).textSelection(.enabled)
                LabeledContent("模型", value: prepared.configuration.model)
            }
            Section("本次数据范围") {
                Text("你的问题、已确认的档案摘要、当前安排、最近训练与程序统计，以及实际存在的每日反馈、身体状态和健康摘要。自由备注、伤病原文、未确认推断、HealthKit原始缓存和查询锚点不发送。实际字段和时间以下方JSON为准。")
                Text("API Key 只作为请求认证发往上述服务器，不会出现在下面的数据、教练记录或备份中。服务可能留存你发送的资料。")
                    .font(.footnote).foregroundStyle(.secondary)
                CoachStatisticsRows(context: prepared.context)
            }
            Section("实际发送的数据 JSON") {
                Text(prepared.preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent)
        .navigationTitle("发送前核对").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .safeAreaInset(edge: .bottom) {
            Button("确认将以上数据发送给模型", action: send)
                .buttonStyle(FitnessPrimaryButtonStyle()).padding().background(FitnessTheme.canvas)
        }
    }
}

struct CoachStatisticsRows: View {
    let context: CoachContext
    var body: some View {
        LabeledContent("统计范围", value: "近 \(context.statistics.lookbackDays) 天")
        LabeledContent("已结束训练", value: "\(context.statistics.completedSessions) 次")
        LabeledContent("已完成正式组", value: "\(context.statistics.completedSets) 组")
        LabeledContent("训练时长", value: UIInput.duration(context.statistics.totalTrainingSeconds))
        Text("上述数量由本地程序计算，包含提前结束的训练；没有记录的情况不作推测。")
            .font(.footnote).foregroundStyle(.secondary)
    }
}

@MainActor
struct CoachTurnDetailView: View {
    let store: TrainingStore
    let turnID: UUID
    @State private var issue: String?
    @State private var confirming = false
    @State private var replanning = false

    private var turn: CoachTurn? { store.coachTurns.first { $0.id == turnID } }

    var body: some View {
        List {
            if let turn {
                Section("你的问题") { Text(turn.question).textSelection(.enabled); Text(turn.createdAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                Section("模型解释") {
                    Text(turn.reply.answer).textSelection(.enabled)
                    Text("模型解释可能有误，请结合原始记录核对；回答本身不改变计划。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.currentWeeklyProgram != nil {
                    Section {
                        Button("根据这次情况重新安排") {
                            do {
                                try store.continuePlanning(from: turn.question)
                                replanning = true
                            } catch { issue = error.localizedDescription }
                        }
                        Text("把你刚才说的情况交给教练，结合已有资料重新制定；确认之前原计划继续保留。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("本次记录依据") {
                    CoachStatisticsRows(context: turn.context)
                    if turn.reply.evidence.isEmpty { Text("模型未引用具体记录依据。").foregroundStyle(.secondary) }
                    ForEach(Array(turn.reply.evidence.enumerated()), id: \.offset) { _, id in
                        Label(turn.context.evidenceLabel(id), systemImage: "doc.text.magnifyingglass")
                    }
                    DisclosureGroup("查看当时发送的数据") {
                        Text((try? CoachAPI.requestJSON(question: turn.question, context: turn.context)) ?? "数据无法显示")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                if !turn.reply.limitations.isEmpty {
                    Section("数据限制与不确定性") {
                        ForEach(Array(turn.reply.limitations.enumerated()), id: \.offset) { _, text in Text(text) }
                    }
                }
                if let proposal = turn.reply.proposal {
                    Section("计划调整建议 · \(decisionTitle(turn.decision))") {
                        Text(proposal.reason)
                        Text("原方案：\(turn.context.plan?.name ?? "未知") · v\(turn.context.plan?.version ?? 0)")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(proposal.items.enumerated()), id: \.offset) { index, item in
                            if let plan = turn.context.plan, plan.items.indices.contains(index) {
                                let original = plan.items[index]
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(original.exercise.name).font(.subheadline.weight(.semibold))
                                    LabeledContent("原方案", value: target(sets: original.setCount, reps: original.targetReps, seconds: original.targetSeconds))
                                    LabeledContent("建议方案", value: target(sets: item.setCount, reps: item.targetReps, seconds: item.targetSeconds))
                                    Text("休息 \(UIInput.number(original.restSeconds)) → \(UIInput.number(item.restSeconds)) 秒")
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 4)
                            }
                        }
                        if turn.decision == .pending {
                            let canApply = mayApply(turn)
                            if !canApply {
                                Text(store.activeSession != nil
                                     ? "请先结束正在进行或暂停的训练，再确认计划建议。"
                                     : "这条建议已过期，或档案、计划、相关训练依据已变化。请重新提问并发送最新数据。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("确认生成新的生效计划版本") { confirming = true }
                                .disabled(!canApply)
                            Button("拒绝建议，保留原计划", role: .destructive) { decide(accept: false) }
                        } else if let appliedID = turn.appliedPlanVersionID,
                                  let plan = store.planVersions.first(where: { $0.id == appliedID }) {
                            Text("已生成计划 v\(plan.version)。旧版本和训练历史保留。")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("已拒绝，原计划未因这条建议改变。").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                ContentUnavailableView("找不到这条教练记录", systemImage: "text.bubble", description: Text("恢复备份后记录可能已变化，请返回列表重新打开。"))
            }
        }
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent)
        .navigationTitle("教练记录").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $replanning) { CoachInterviewView(store: store) }
        .confirmationDialog("确认让这条建议生成新计划版本？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认保存并生效") { decide(accept: true) }
            Button("取消", role: .cancel) { }
        } message: {
            Text("本地会重新校验依据是否过期或发生变化。通过后保存新版本，旧计划和已开始的训练记录保留。")
        }
        .fitnessError($issue)
    }

    private func decide(accept: Bool) {
        do { _ = try store.decideCoachTurn(id: turnID, accept: accept) }
        catch { issue = error.localizedDescription }
    }

    private func mayApply(_ turn: CoachTurn) -> Bool {
        guard store.activeSession == nil, let snapshot = try? store.snapshot() else { return false }
        return turn.context.matches(snapshot: snapshot)
    }

    private func target(sets: Int, reps: Int?, seconds: Double?) -> String {
        if let reps { return "\(sets) 组 × \(reps) 次" }
        if let seconds { return "\(sets) 组 × \(UIInput.number(seconds)) 秒" }
        return "\(sets) 组 · 目标未知"
    }
}
