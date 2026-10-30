import SwiftUI
import FitnessCore

/// The adjustment screen: shows what would change, why, and on what evidence, before the user decides.
@MainActor
struct AdjustmentReviewView: View {
    let store: TrainingStore
    /// When opened from Today, the reduction is built on arrival so the person never lands on an
    /// empty screen after tapping "less today". It is still a *proposal*: nothing changes until the
    /// confirmation below.
    var proposeOnOpen: Bool = false
    @State private var issue: String?
    @State private var status: String?

    private var pending: AdjustmentProposal? { store.pendingAdjustment }

    var body: some View {
        List {
            if let proposal = pending {
                Section("建议类型") {
                    LabeledContent("类型", value: proposal.kind.title)
                    Text(proposal.summary).font(.subheadline)
                }
                Section("为什么") {
                    Text(proposal.reason).font(.footnote)
                }
                if let items = proposal.todayItems {
                    Section("今天改成这样") {
                        Text("只影响今天这一次，已确认的长期计划保持不变。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(items) { item in
                            itemRow(item)
                        }
                    }
                }
                if let items = proposal.proposedItems {
                    Section("新的长期版本") {
                        Text("确认后会生成一个新版本并生效；原版本保留在计划记录里。")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(items) { item in
                            itemRow(item)
                        }
                    }
                    if let base = currentBaseItems {
                        Section("与当前版本的差异") {
                            ForEach(differences(base: base, new: items), id: \.self) { line in
                                Text(line).font(.footnote)
                            }
                        }
                    }
                }
                Section("依据") {
                    if proposal.evidenceIDs.isEmpty {
                        Text("这次建议没有引用真实数据。").foregroundStyle(.orange)
                    } else {
                        ForEach(proposal.evidenceIDs, id: \.self) { id in
                            Text(label(for: id)).font(.caption)
                        }
                    }
                }
                Section {
                    Button("确认并应用") { accept(proposal) }.buttonStyle(FitnessPrimaryButtonStyle())
                    Button("拒绝，保持原样") { reject(proposal) }.foregroundStyle(.red)
                } footer: {
                    Text("确认之前原计划完全不变；拒绝之后也完全不变。若期间记录发生变化，这条建议会失效，需要重新生成。")
                }
            } else {
                Section {
                    ContentUnavailableView("没有待确认的调整", systemImage: "checkmark.seal",
                                           description: Text("先做一次状态评估，规则会给出是否需要调整。"))
                    NavigationLink("先记录今天的状态") { CheckInView(store: store) }
                }
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("调整建议")
        .navigationBarTitleDisplayMode(.inline)
        .task { if proposeOnOpen, pending == nil { generate() } }
        .fitnessError($issue)
    }

    /// Builds the conservative proposal from a freshly computed readiness assessment. Storage re-runs
    /// the same assessment before saving, so a stale or hand-edited value cannot slip through.
    private func generate() {
        do {
            let assessment = try store.refreshReadiness()
            _ = try store.proposeAdjustment(readiness: assessment)
            if store.pendingAdjustment?.kind == .keep {
                status = "规则判断今天按原计划即可，没有需要改的地方。"
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private var currentBaseItems: [PlannedExercise]? {
        store.scheduledPlan()?.items
    }

    private func itemRow(_ item: PlannedExercise) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.exercise.name).font(.subheadline.weight(.semibold))
            Text("\(item.setCount) 组" + (item.targetReps.map { " × \($0) 次" } ?? "")
                 + (item.targetSeconds.map { " × \(UIInput.number($0)) 秒" } ?? "")
                 + " · 休息 \(UIInput.number(item.restSeconds)) 秒")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func differences(base: [PlannedExercise], new: [PlannedExercise]) -> [String] {
        var lines: [String] = []
        for item in new {
            if let old = base.first(where: { $0.exercise.id == item.exercise.id }) {
                if old.setCount != item.setCount {
                    lines.append("\(item.exercise.name)：\(old.setCount) 组 → \(item.setCount) 组")
                }
                if old.targetReps != item.targetReps {
                    lines.append("\(item.exercise.name)：目标次数 \(old.targetReps.map(String.init) ?? "未知") → \(item.targetReps.map(String.init) ?? "未知")")
                }
                if old.restSeconds != item.restSeconds {
                    lines.append("\(item.exercise.name)：休息 \(UIInput.number(old.restSeconds)) → \(UIInput.number(item.restSeconds)) 秒")
                }
            } else {
                lines.append("新增动作：\(item.exercise.name)")
            }
        }
        for item in base where !new.contains(where: { $0.exercise.id == item.exercise.id }) {
            lines.append("移除动作：\(item.exercise.name)")
        }
        return lines.isEmpty ? ["没有可显示的差异。"] : lines
    }

    private func label(for evidenceID: String) -> String {
        if evidenceID.hasPrefix("checkin:") { return "训练前自述记录" }
        if evidenceID.hasPrefix("session:") { return "训练记录" }
        if evidenceID.hasPrefix("health:") {
            let raw = String(evidenceID.dropFirst("health:".count))
            return "健康数据：" + (HealthMetric(rawValue: raw)?.title ?? raw)
        }
        return evidenceID
    }

    private func accept(_ proposal: AdjustmentProposal) {
        do {
            let created = try store.acceptAdjustment(id: proposal.id)
            if created != nil { status = "已生成新版本并生效。" }
            else if proposal.kind == .todayOnly {
                status = "已确认。今天下一次按此计划开训时使用调整后的组数，仅使用一次；长期计划没有改动。"
            } else {
                status = "已记录你的确认。请按建议查看今天的状态，长期计划没有改动。"
            }
        } catch {
            issue = error.localizedDescription
        }
    }

    private func reject(_ proposal: AdjustmentProposal) {
        do {
            try store.rejectAdjustment(id: proposal.id)
            status = "已拒绝。当前计划没有任何改动。"
        } catch {
            issue = error.localizedDescription
        }
    }
}

/// Weekly and monthly review, entirely from stored records.
@MainActor
struct ReviewView: View {
    let store: TrainingStore
    @State private var summary: ReviewSummary?
    @State private var period: ReviewSummary.Period = .week
    @State private var issue: String?

    var body: some View {
        List {
            Section {
                Picker("范围", selection: $period) {
                    Text(ReviewSummary.Period.week.title).tag(ReviewSummary.Period.week)
                    Text(ReviewSummary.Period.month.title).tag(ReviewSummary.Period.month)
                }.pickerStyle(.segmented)
                Button("用真实记录重新统计", action: refresh)
            }
            if let summary {
                Section("完成情况") {
                    LabeledContent("完成训练", value: "\(summary.finishedSessionCount) 次")
                    LabeledContent("完成正式组", value: "\(summary.completedWorkingSets) 组")
                    LabeledContent("训练总时长", value: UIInput.duration(summary.totalTrainingSeconds))
                    Text(summary.completionRateText).font(.footnote).foregroundStyle(.secondary)
                }
                Section("训练前记录") {
                    LabeledContent("记录次数", value: "\(summary.checkInCount)")
                    LabeledContent("回答了疼痛", value: "\(summary.answeredPainCount)")
                    LabeledContent("报告有疼痛", value: "\(summary.reportedPainCount)")
                }
                if !summary.exerciseProgress.isEmpty {
                    Section("按动作") {
                        ForEach(summary.exerciseProgress, id: \.exerciseID) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(ExerciseCatalog.exercise(id: item.exerciseID)?.name ?? item.exerciseID)
                                    .font(.subheadline.weight(.semibold))
                                Text(progressText(item)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("这份复盘没能量到的") {
                    if summary.dataGaps.isEmpty {
                        Text("没有发现明显缺口。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(summary.dataGaps.enumerated()), id: \.offset) { _, gap in
                        Text("· " + gap).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section { Text("还没有统计。").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("周月复盘")
        .navigationBarTitleDisplayMode(.inline)
        .task { refresh() }
        .onChange(of: period) { _, _ in refresh() }
        .fitnessError($issue)
    }

    private func progressText(_ item: ExerciseProgress) -> String {
        var parts = ["\(item.sessionCount) 次训练", "\(item.completedSetCount) 组"]
        if let load = item.bestLoadKG { parts.append("最重 \(UIInput.number(load)) kg") }
        if let reps = item.bestReps { parts.append("最多次数 \(reps)") }
        if let seconds = item.bestDurationSeconds { parts.append("最长 \(UIInput.number(seconds)) 秒") }
        return parts.joined(separator: " · ")
    }

    private func refresh() {
        do { summary = try store.refreshReview(period) }
        catch { issue = error.localizedDescription }
    }
}

/// Health status screen: what was read, when, from where, and what is simply missing.
@MainActor
struct HealthStatusView: View {
    let store: TrainingStore
    @State private var issue: String?
    @State private var status: String?
    @State private var reading = false

    var body: some View {
        List {
            Section {
                Text("这里显示本机实际读到的 Apple 健康数据。没有数据不等于你拒绝了授权——系统不会告诉 App 读权限是否被拒绝。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    Task { await read() }
                } label: {
                    Label(reading ? "正在读取…" : "读取 Apple 健康数据", systemImage: "heart.text.square")
                }.disabled(reading)
            }
            if let snapshot = store.healthSnapshot {
                Section("最近一次读取") {
                    Text(snapshot.capturedAt, format: .dateTime.year().month().day().hour().minute())
                    Text(snapshot.userFacingSummary).font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(snapshot.metrics, id: \.metric) { metric in
                    Section(metric.metric.title) {
                        LabeledContent("状态", value: metric.effectiveState(at: Date()).title)
                        if let value = metric.latestValue {
                            LabeledContent("最新数值", value: ReadinessEngine.describe(value, metric: metric.metric))
                        }
                        if let sampleAt = metric.latestSampleAt {
                            LabeledContent("样本时间") { Text(sampleAt, format: .dateTime.month().day().hour().minute()) }
                        }
                        if let syncedAt = metric.syncedAt {
                            LabeledContent("读取时间") { Text(syncedAt, format: .dateTime.month().day().hour().minute()) }
                        }
                        if let source = metric.sourceName { LabeledContent("来源", value: source) }
                        LabeledContent("窗口内样本", value: "\(metric.sampleCountInWindow)")
                        if let note = metric.metric.measurementNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                        if let reason = metric.failureReason {
                            Text("读取失败：" + reason).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Section { Text("还没有读取过。").foregroundStyle(.secondary) }
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Apple 健康")
        .navigationBarTitleDisplayMode(.inline)
        .fitnessError($issue)
    }

    private func read() async {
        reading = true
        defer { reading = false }
        let importer = HealthImporter()
        let outcome = await importer.importAll(existingAnchors: store.healthAnchors(), existingSnapshot: store.healthSnapshot)
        do {
            try store.saveHealthSnapshot(outcome.snapshot)
            status = outcome.notes.isEmpty ? "读取完成。" : outcome.notes.joined(separator: "\n")
        } catch {
            issue = error.localizedDescription
        }
    }
}
