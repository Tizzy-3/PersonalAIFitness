import SwiftUI
import FitnessCore

private struct PreparedPlanningRequest: Identifiable {
    let id = UUID()
    let draft: PlanningDraft
    let configuration: AIConfiguration
    let preview: String
}

@MainActor
struct PlanningDraftDetailView: View {
    let store: TrainingStore
    let draftID: UUID
    @State private var chosenOptionID: String?
    @State private var localReviewEnabled = false
    @State private var prepared: PreparedPlanningRequest?
    @State private var request: Task<Void, Never>?
    @State private var unsavedDraft: PlanningDraft?
    @State private var confirming = false
    @State private var issue: String?
    @State private var status: String?

    private var draft: PlanningDraft? { unsavedDraft ?? store.planningDrafts.first { $0.id == draftID } }
    private var selectedID: String? { chosenOptionID ?? draft?.selection?.optionID }

    var body: some View {
        List {
            if let draft {
                overview(draft)
                if unsavedDraft != nil {
                    Section("AI 回答尚未保存") {
                        Text("模型已返回选择和解释，但本地保存失败。先重试保存，不需要再次请求模型。离开页面可能丢失这次未保存回答。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重试保存回答") { persist(draft) }
                        Button("放弃未保存回答，保留原草案", role: .destructive) { unsavedDraft = nil }
                    }
                }
                if draft.decision == .pending { requestActions(draft) }
                if let selection = draft.selection { modelSelection(selection, draft: draft) }
                candidateSections(draft)
                if draft.decision == .pending { confirmationSection(draft) }
                else if let programID = draft.appliedProgramID {
                    Section {
                        Label("你已确认此周计划", systemImage: "checkmark.circle")
                        NavigationLink { WeeklyProgramDetailView(store: store, programID: programID) } label: { Text("查看已保存的每周安排") }
                    }
                } else {
                    Section { Text("这份草案已拒绝，没有因它修改当前安排。需要新方案时重新填写并生成草案。") }
                }
            } else {
                ContentUnavailableView("找不到这份计划草案", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(draft?.decision == .pending ? "制定计划 · 待你决定" : "制定计划记录").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $prepared) { prepared in
            NavigationStack { PlannerConsentView(prepared: prepared, send: { send(prepared) }) }
        }
        .confirmationDialog("确认让这份周计划生效？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认创建并启用周计划") { confirm() }
            Button("继续查看", role: .cancel) { }
        } message: {
            Text("保存每日独立训练版本并启用这份每周安排。原计划、已确认安排和训练历史保留；系统会在保存前复核资料是否已变化。")
        }
        .onDisappear { request?.cancel() }
        .fitnessError($issue)
    }

    private func overview(_ draft: PlanningDraft) -> some View {
        Section("本次安排条件") {
            LabeledContent("目标", value: draft.input.goal.title)
            LabeledContent("经验", value: draft.input.experience.title)
            LabeledContent("训练日", value: draft.input.weekdays.map(PlanningDisplay.weekday).joined(separator: "、"))
            LabeledContent("单次预算", value: "\(draft.input.minutesPerSession) 分钟")
            LabeledContent("本地近28天记录", value: "\(draft.input.completedSessionsLast28Days) 次已结束训练")
            LabeledContent("最近训练间隔", value: draft.input.daysSinceLastTraining.map { "\($0) 天" } ?? "未知 / 没有已保存记录")
            Text("档案和真实训练摘要截至 \(draft.createdAt.formatted(date: .abbreviated, time: .shortened))。没有App记录不等于本人没有运动。")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("草案状态", value: PlanningDisplay.decision(draft.decision))
        }
    }

    private func requestActions(_ draft: PlanningDraft) -> some View {
        Section("让 AI 为我选择与解释") {
            if request != nil {
                HStack { ProgressView(); Text("AI 正在比较可行方案…"); Spacer(); Button("取消") { request?.cancel() } }
            } else {
                Button(draft.selection == nil ? "预览数据，请 AI 安排" : "预览数据，重新请求 AI 选择", systemImage: "bubble.left.and.text.bubble.right") { prepareAI(draft) }
                    .disabled(unsavedDraft != nil || !isFresh(draft) || store.activeSession != nil)
            }
            NavigationLink { AISettingsView() } label: { Label("接口配置与本机密钥", systemImage: "slider.horizontal.3") }
            Text("AI只能选择下面已通过本地规则的候选并解释，不能自行改写动作、组数或重量。发送前会展示实际JSON、目标服务器和模型。")
                .font(.footnote).foregroundStyle(.secondary)
            if draft.selection == nil {
                Button("不使用 AI，明确查看离线本地规则方案") {
                    localReviewEnabled = true
                    if chosenOptionID == nil { chosenOptionID = draft.options.first?.id }
                }.disabled(request != nil || unsavedDraft != nil)
                if localReviewEnabled { Text("当前采用本地规则模式，没有请求模型，也不会标记为AI制定成功。")
                        .font(.caption).foregroundStyle(.secondary) }
            }
            if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func modelSelection(_ selection: AISelection, draft: PlanningDraft) -> some View {
        Section("AI 推荐与解释") {
            Text(draft.options.first(where: { $0.id == selection.optionID })?.title ?? "未知候选").font(.headline)
            Text(selection.explanation).textSelection(.enabled)
            ForEach(Array(selection.limitations.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote).foregroundStyle(.secondary) }
            Text("依据：\(selection.evidence.joined(separator: "、"))").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("服务：\(draft.providerHost ?? "未知") · 模型：\(draft.model ?? "未知")")
                .font(.caption).foregroundStyle(.secondary)
            Text(draft.decision == .pending
                 ? "解释是模型文本，可能有误；动作、剂量与时间以本地规则候选为准，目前尚未生效。"
                 : "解释是当时保存的模型文本，可能有误。实际生效内容以你最终确认的方案和状态为准。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func candidateSections(_ draft: PlanningDraft) -> some View {
        Section("查看每个可行方案") {
            ForEach(draft.options) { option in
                NavigationLink { WeeklyOptionView(option: option, store: store) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(option.title).font(.headline)
                        Text("\(option.days.filter { !$0.isRestDay }.count) 个训练日 · 查看七天动作、组数和休息")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("全部候选都需本人核对。预计时间是区间，初次重量需按技术和能力校准；这里没有虚构的最优公斤数。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func confirmationSection(_ draft: PlanningDraft) -> some View {
        Section("对比后确认生效") {
            if let current = store.currentWeeklyProgram, let option = current.selectedOption {
                Text("原安排：\(option.title)，每周 \(option.days.filter { !$0.isRestDay }.count) 个训练日。")
            } else if let plan = store.currentPlan {
                Text("原安排：手动计划「\(plan.name)」v\(plan.version)，\(plan.items.count) 个动作。")
            } else { Text("原安排：当前没有生效计划。") }
            if draft.selection != nil || localReviewEnabled {
                Picker("准备采用", selection: Binding(get: { selectedID ?? "" }, set: { chosenOptionID = $0 })) {
                    ForEach(draft.options) { Text($0.title).tag($0.id) }
                }
                if let chosen = draft.options.first(where: { $0.id == selectedID }) {
                    ForEach(chosen.days) { day in
                        HStack {
                            Text(PlanningDisplay.weekday(day.weekday))
                            Spacer()
                            Text(day.isRestDay ? "休息" : "\(day.title) · \(day.items.count) 动作 · \(day.estimatedMinutesLower)–\(day.estimatedMinutesUpper) 分钟")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let aiID = draft.selection?.optionID, aiID != chosen.id {
                        Text("你选择了另一个规则候选。上方AI解释对应其原推荐，最终采用以这里的选择为准。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("我已核对，确认启用这份周计划") { confirming = true }
                    .font(.headline).disabled(!mayConfirm(draft))
            } else {
                Text("先请求AI选择，或明确进入离线本地规则模式；不会自动将第一个候选作为AI结果。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !isFresh(draft) { Text("这份草案已过期或资料/训练/当前安排发生变化，请生成新的草案再确认。")
                    .font(.footnote).foregroundStyle(.secondary) }
            if store.activeSession != nil { Text("还有未结束的训练，请先恢复或结束，再切换生效周计划。")
                    .font(.footnote).foregroundStyle(.secondary) }
            Button("拒绝这份草案，保留原安排", role: .destructive) { reject() }
                .disabled(request != nil || unsavedDraft != nil)
        }
    }

    private func prepareAI(_ draft: PlanningDraft) {
        do {
            guard isFresh(draft) else { throw UIInput.Invalid(message: "草案依据已经变化，请重新生成。") }
            guard let configuration = try AIConfigurationStorage.load(), try AIKeychain.load(for: configuration) != nil else {
                throw CoachClientError.configuration("请先配置完整HTTPS接口、模型和当前服务器的本机密钥。")
            }
            prepared = PreparedPlanningRequest(draft: draft, configuration: configuration, preview: try PlannerAPI.requestJSON(draft: draft))
        } catch { issue = error.localizedDescription }
    }

    private func send(_ prepared: PreparedPlanningRequest) {
        self.prepared = nil
        status = nil
        request = Task {
            defer { request = nil }
            do {
                guard let key = try AIKeychain.load(for: prepared.configuration) else { throw CoachClientError.configuration("预览对应服务器的密钥已不存在，请重新配置。") }
                let selection = try await PlannerAPI().select(draft: prepared.draft, configuration: prepared.configuration, key: key)
                try Task.checkCancellation()
                var updated = prepared.draft
                updated.selection = selection
                updated.providerHost = try prepared.configuration.validatedURL().host
                updated.model = prepared.configuration.normalized.model
                unsavedDraft = updated
                chosenOptionID = selection.optionID
                persist(updated)
            } catch is CancellationError { status = "已取消，没有自动重试或改变计划。" }
            catch { issue = error.localizedDescription }
        }
    }

    private func persist(_ draft: PlanningDraft) {
        do {
            try store.savePlanningDraft(draft)
            unsavedDraft = nil
            status = "AI选择已保存。请查看每日动作和取舍，再明确确认生效。"
        } catch { unsavedDraft = draft; issue = error.localizedDescription }
    }

    private func isFresh(_ draft: PlanningDraft) -> Bool {
        guard let snapshot = try? store.snapshot() else { return false }
        return draft.matches(snapshot: snapshot)
    }

    private func mayConfirm(_ draft: PlanningDraft) -> Bool {
        draft.decision == .pending && unsavedDraft == nil && request == nil && store.activeSession == nil && isFresh(draft)
            && (draft.selection != nil || localReviewEnabled) && draft.options.contains(where: { $0.id == selectedID })
    }

    private func confirm() {
        do {
            guard let draft, let selectedID, mayConfirm(draft) else { throw UIInput.Invalid(message: "请先核对并选择一个可生效的方案。") }
            _ = try store.confirmWeeklyProgram(draftID: draft.id, optionID: selectedID)
            status = "周计划已保存并生效。"
        } catch { issue = error.localizedDescription }
    }

    private func reject() {
        do { try store.rejectPlanningDraft(id: draftID); status = "草案已拒绝，原安排保持。" }
        catch { issue = error.localizedDescription }
    }
}

@MainActor
private struct PlannerConsentView: View {
    let prepared: PreparedPlanningRequest
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section("发送到哪里") {
                Text(prepared.configuration.destination).font(.footnote.monospaced()).textSelection(.enabled)
                LabeledContent("模型", value: prepared.configuration.model)
            }
            Section("本次实际范围") {
                Text("明确填写的目标、经验、训练日、时间、器械、安全声明与排除动作；本地计算的近期训练次数/间隔；完整规则候选和相关动作定义。")
                Text("不发送档案的伤病原文、出生年份、身高体重、训练备注或API Key文本，也不发送HealthKit数据。API Key仅作为认证发往上述服务器。服务可能按其规则留存你发送的资料。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("实际发送的 JSON") { Text(prepared.preview).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .navigationTitle("AI安排前核对").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .safeAreaInset(edge: .bottom) {
            Button("确认将以上候选发送给 AI", action: send)
                .buttonStyle(FitnessPrimaryButtonStyle()).padding().background(FitnessTheme.canvas)
        }
    }
}
