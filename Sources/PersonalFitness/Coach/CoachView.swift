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

    init(store: TrainingStore, initialQuestion: String = "") {
        self.store = store
        _question = State(initialValue: initialQuestion)
    }

    var body: some View {
        List {
            Section {
                Text("从你的实际记录出发").font(.title3.weight(.semibold))
                Text("解释计划、查看最近训练、讨论怎样调整。每次发送前都可以核对数据，计划不会因一句回答自动改变。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { AISettingsView() } label: { Label("配置 AI 接口与本机密钥", systemImage: "slider.horizontal.3") }
            }
            Section("问教练") {
                TextField("例如：根据最近的训练记录，哪些地方需要关注？", text: $question, axis: .vertical)
                    .lineLimit(3...10)
                    .disabled(request != nil || unsavedTurn != nil)
                if question.count > 4_000 { Text("问题超过 4000 字，请缩短。").font(.footnote).foregroundStyle(.red) }
                if request == nil && unsavedTurn == nil {
                    Button("预览数据并准备发送", systemImage: "paperplane") { prepare() }
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || question.count > 4_000)
                }
                if request != nil {
                    HStack { ProgressView(); Text("等待模型回答…"); Spacer(); Button("取消请求") { request?.cancel() } }
                    Text("\(requestQuestion ?? "")").font(.footnote).foregroundStyle(.secondary)
                }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if request == nil && unsavedTurn == nil {
                Section("可以从这里开始") {
                    Button("解释当前计划的安排") { question = "请解释当前计划的动作安排与记录方式，指出已有依据和目前缺少的信息，不修改计划。" }
                    Button("复盘最近训练") { question = "请依据近28天程序统计和最近训练记录复盘，区分已有证据与未知信息，不编造成绩。" }
                    Button("今天时间不够，怎样减量？") { question = "今天可训练时间比原计划少。请先解释保留和减少哪些训练的取舍；如依据充分，只提出同动作同顺序的保守减量草案，等待我确认。" }
                }
            }
            if let turn = unsavedTurn {
                Section("回答尚未保存") {
                    Text(turn.reply.answer).textSelection(.enabled)
                    Text("模型已经返回回答，但本地保存失败。请先重试保存，不需要再次请求模型；离开此页面可能丢失未保存回答。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试保存这次回答") { persist(turn) }
                }
            }
            Section("教练记录") {
                if store.coachTurns.isEmpty {
                    ContentUnavailableView("还没有教练记录", systemImage: "text.bubble", description: Text("配置接口后发送你的第一个问题。这里不会显示预设的 AI 回答。"))
                }
                ForEach(store.coachTurns.sorted { $0.createdAt > $1.createdAt }) { turn in
                    NavigationLink { CoachTurnDetailView(store: store, turnID: turn.id) } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(turn.question).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(turn.reply.answer).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            HStack {
                                Text(turn.createdAt, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                if turn.reply.proposal != nil { Text(decisionTitle(turn.decision)) }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section {
                Text("AI 回答是模型解释，不能保证每句话准确。计划变更还要经过本地结构校验和你的确认。当前只支持现有计划的保守减量，自动制定训练周期、完整健康评估与动作替换仍未实现。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("AI 教练")
        .sheet(item: $prepared) { prepared in
            NavigationStack { CoachConsentView(prepared: prepared, send: { send(prepared) }) }
        }
        .onDisappear { request?.cancel() }
        .fitnessError($issue)
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
                Text("你的问题、已保存档案摘要、当前计划、最近最多10次训练及近28天程序统计，并按问题和计划附最多8个本地动作的通用提示。运动限制只发送存在标记，训练备注不发送；没有接入 HealthKit 摘要。")
                Text("API Key 只作为请求认证发往上述服务器，不会出现在下面的数据、教练记录或备份中。服务可能留存你发送的资料。")
                    .font(.footnote).foregroundStyle(.secondary)
                CoachStatisticsRows(context: prepared.context)
            }
            Section("实际发送的数据 JSON") {
                Text(prepared.preview).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
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
        .navigationTitle("教练记录").navigationBarTitleDisplayMode(.inline)
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
