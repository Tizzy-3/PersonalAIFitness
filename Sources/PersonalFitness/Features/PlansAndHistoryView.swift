import SwiftUI
import FitnessCore

@MainActor
struct PlansAndHistoryView: View {
    let store: TrainingStore
    let openWorkout: (UUID) -> Void
    let editPlan: (PlanVersion?) -> Void
    @State private var issue: String?

    var body: some View {
        List {
            if let active = store.activeSession {
                Section("进行中") {
                    Button { openWorkout(active.id) } label: {
                        Label("\(active.name) · \(active.status.title)", systemImage: "arrow.clockwise")
                    }
                }
            }
            Section("当前计划") {
                if let plan = store.currentPlan {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.name).font(.headline)
                            Text("v\(plan.version) · \(plan.items.count) 个动作 · 手动确认")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("编辑副本") { editPlan(plan) }
                    }
                } else { Text("尚无生效计划").foregroundStyle(.secondary) }
                Button("创建新计划", systemImage: "plus") { editPlan(nil) }
                Button("开始自由训练", systemImage: "play") {
                    do { openWorkout(try store.startWorkout().id) }
                    catch { issue = error.localizedDescription }
                }.disabled(store.activeSession != nil)
            }
            Section("训练历史") {
                let history = store.sessions.filter { !$0.status.isOngoing }.sorted { $0.startedAt > $1.startedAt }
                if history.isEmpty { Text("完成的训练会保存在这里。").foregroundStyle(.secondary) }
                ForEach(history) { session in
                    NavigationLink { SessionDetailView(session: session) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(session.name).font(.headline); Spacer(); Text(session.status.title).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Text(session.startedAt, style: .date)
                                Text("· \(session.completedWorkingSets) 组 · \(UIInput.duration(session.elapsed()))")
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
            }
            if !store.planVersions.isEmpty {
                Section("计划版本记录") {
                    ForEach(store.planVersions.sorted { $0.confirmedAt > $1.confirmedAt }) { plan in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(plan.name) · v\(plan.version)")
                            Text(plan.confirmedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            Text("\(plan.items.count) 个动作\(plan.id == store.activePlanVersionID ? " · 当前生效" : " · 保留的历史版本")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }.navigationTitle("训练").fitnessError($issue)
    }
}

struct SessionDetailView: View {
    let session: WorkoutSession

    var body: some View {
        List {
            Section {
                LabeledContent("状态", value: session.status.title)
                LabeledContent("开始时间") { Text(session.startedAt, format: .dateTime.month().day().hour().minute()) }
                LabeledContent("会话时长", value: UIInput.duration(session.elapsed()))
                LabeledContent("完成正式组", value: String(session.completedWorkingSets))
                if session.sourcePlanVersionID != nil { Text("记录保留开训时的计划快照，后续计划修改不会覆盖本次训练。").font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(session.exercises) { item in
                Section {
                    if item.skipped { Label("本次已跳过", systemImage: "forward.end").foregroundStyle(.secondary) }
                    ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                        HStack {
                            Text(set.kind == .warmup ? "W" : String(index + 1)).font(.subheadline.monospacedDigit()).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary(set, metric: item.exercise.metric))
                                Text(item.exercise.loadConvention.title).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(set.skipped ? "已跳过" : set.isCompleted ? "已完成" : "未完成")
                                .font(.caption).foregroundStyle(set.isCompleted ? FitnessTheme.success : .secondary)
                        }
                    }
                    if !item.note.isEmpty { Text(item.note).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text(item.exercise.name) }
            }
            Section { Text("首个试用版历史为只读；历史更正界面尚未实现，原始记录不会在这里被覆盖。")
                    .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ set: LoggedSet, metric: RecordingMetric) -> String {
        switch metric {
        case .repetitions:
            return "\(set.loadKG.map { UIInput.number($0) + " kg × " } ?? "")\(set.reps.map(String.init) ?? "—") 次"
        case .duration:
            return "\(UIInput.number(set.durationSeconds)) 秒"
        case .cardio:
            return "\(set.durationSeconds.map { UIInput.duration($0) } ?? "未记录时长")\(set.distanceMeters.map { " · " + UIInput.number($0 / 1_000) + " km" } ?? "")"
        }
    }
}

@MainActor
struct TrainingInsightsView: View {
    let store: TrainingStore

    private var recorded: [WorkoutSession] {
        store.sessions.filter { !$0.status.isOngoing && $0.exercises.contains(where: { $0.sets.contains(where: \.isCompleted) }) }
    }

    var body: some View {
        List {
            Section("来自实际记录") {
                LabeledContent("记录的训练次数", value: String(recorded.count))
                LabeledContent("完成正式组", value: String(recorded.reduce(0) { $0 + $1.completedWorkingSets }))
                LabeledContent("会话总时长", value: UIInput.duration(recorded.reduce(0) { $0 + $1.elapsed() }))
            }
            Section {
                Text("会话时长包含组间休息、排除显式暂停。没有把热身组或未完成组计入完成正式组。")
                Text("完整周/月报表、完成率、单动作力量趋势、有氧趋势和身体状态分析尚未实现。")
                Text("没有真实记录时不生成进步曲线或 AI 分析。")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("趋势")
    }
}
