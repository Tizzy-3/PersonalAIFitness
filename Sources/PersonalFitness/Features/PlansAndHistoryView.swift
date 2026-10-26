import SwiftUI
import FitnessCore

private enum PlanLibraryDeletion {
    case plan(PlanVersion)
    case program(WeeklyProgram)

    var name: String {
        switch self {
        case .plan(let plan): return plan.name
        case .program(let program): return program.selectedOption?.title ?? "周计划"
        }
    }
}

@MainActor
struct PlansAndHistoryView: View {
    let store: TrainingStore
    let openWorkout: (UUID) -> Void
    let editPlan: (PlanVersion?) -> Void
    @State private var issue: String?
    @State private var deleting: PlanLibraryDeletion?

    private var showingDeletion: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    var body: some View {
        List {
            if let active = store.activeSession {
                Section("进行中") {
                    Button { openWorkout(active.id) } label: {
                        Label("\(active.name) · \(active.status.title)", systemImage: "arrow.clockwise")
                    }
                }
            }
            currentSection
            Section("制定与创建") {
                NavigationLink { PlannerView(store: store) } label: {
                    Label("AI 为我制定周计划", systemImage: "calendar.badge.plus")
                }
                Button("创建手动计划", systemImage: "plus") { editPlan(nil) }
                Button("开始自由训练", systemImage: "play") {
                    do { openWorkout(try store.startWorkout().id) }
                    catch { issue = error.localizedDescription }
                }.disabled(store.activeSession != nil)
            }
            if !store.visibleWeeklyPrograms.isEmpty {
                Section("我的周计划") {
                    ForEach(store.visibleWeeklyPrograms.sorted { $0.confirmedAt > $1.confirmedAt }) { program in
                        NavigationLink { WeeklyProgramDetailView(store: store, programID: program.id, openWorkout: openWorkout) } label: {
                            programLabel(program)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", role: .destructive) { deleting = .program(program) }
                        }
                        .contextMenu {
                            if store.currentWeeklyProgram?.id != program.id {
                                Button("设为当前周计划", systemImage: "checkmark.circle") { activate(program) }
                            }
                            Button("删除周计划", systemImage: "trash", role: .destructive) { deleting = .program(program) }
                        }
                    }
                }
            }
            Section("我的手动计划") {
                if store.visiblePlans.isEmpty { Text("手动创建的计划会显示在这里。").foregroundStyle(.secondary) }
                ForEach(store.visiblePlans.sorted { $0.confirmedAt > $1.confirmedAt }) { plan in
                    NavigationLink { PlanLibraryDetailView(store: store, planID: plan.planID, editPlan: editPlan) } label: {
                        planLabel(plan)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { deleting = .plan(plan) }
                    }
                    .contextMenu {
                        if store.currentPlan?.id != plan.id {
                            Button("设为当前计划", systemImage: "checkmark.circle") { activate(plan) }
                        }
                        Button("编辑副本", systemImage: "square.and.pencil") { editPlan(plan) }
                        Button("删除计划", systemImage: "trash", role: .destructive) { deleting = .plan(plan) }
                    }
                }
            }
            Section {
                NavigationLink { DeletedPlanLibraryView(store: store) } label: {
                    HStack {
                        Label("已删除计划", systemImage: "trash")
                        Spacer()
                        Text("\(store.deletedPlans.count + store.deletedWeeklyPrograms.count)").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("删除只从计划库移除，旧版本和训练记录保留。可在已删除计划中恢复，恢复后不会自动生效。")
            }
            historySection
            if !retainedVersions.isEmpty {
                Section {
                    DisclosureGroup("计划版本记录 · 只读") {
                        ForEach(retainedVersions) { plan in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(plan.name) · v\(plan.version)")
                                Text(plan.confirmedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                Text("\(plan.items.count) 个动作\(plan.id == store.activePlanVersionID ? " · 当前生效" : " · 保留的版本")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: { Text("不能单独删除一个历史版本，以免破坏训练来源和版本链。") }
            }
        }
        .navigationTitle("训练")
        .confirmationDialog("删除“\(deleting?.name ?? "计划")”？", isPresented: showingDeletion, titleVisibility: .visible) {
            if let deleting {
                Button("删除计划，保留训练历史", role: .destructive) { remove(deleting) }
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            Text("计划会从当前安排和计划列表移除。旧版本、已完成记录和正在进行的训练都会保留；之后可在“已删除计划”中恢复。")
        }
        .fitnessError($issue)
    }

    private var retainedVersions: [PlanVersion] {
        store.planVersions.filter { !store.deletedPlanIDs.contains($0.planID) }.sorted { $0.confirmedAt > $1.confirmedAt }
    }

    private var currentSection: some View {
        Section("当前安排") {
            if let program = store.currentWeeklyProgram {
                NavigationLink { WeeklyProgramDetailView(store: store, programID: program.id, openWorkout: openWorkout) } label: {
                    programLabel(program)
                }
                Button("删除当前周计划", systemImage: "trash", role: .destructive) { deleting = .program(program) }
            } else if let plan = store.currentPlan {
                NavigationLink { PlanLibraryDetailView(store: store, planID: plan.planID, editPlan: editPlan) } label: { planLabel(plan) }
                HStack {
                    Button("编辑副本", systemImage: "square.and.pencil") { editPlan(plan) }
                    Spacer()
                    Button("删除计划", systemImage: "trash", role: .destructive) { deleting = .plan(plan) }
                }.buttonStyle(.borderless)
            } else {
                Text("尚无生效计划。选择已有计划，或让 AI 帮你安排一周。").foregroundStyle(.secondary)
            }
        }
    }

    private var historySection: some View {
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
    }

    private func planLabel(_ plan: PlanVersion) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(plan.name).font(.headline)
            Text("v\(plan.version) · \(plan.items.count) 个动作\(store.currentPlan?.id == plan.id ? " · 当前生效" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }

    private func programLabel(_ program: WeeklyProgram) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(program.selectedOption?.title ?? "周计划").font(.headline)
            Text("每周 \(program.draft.input.weekdays.count) 个训练日\(store.currentWeeklyProgram?.id == program.id ? " · 当前生效" : "")")
                .font(.caption).foregroundStyle(.secondary)
            Text(program.confirmedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }

    private func activate(_ plan: PlanVersion) {
        do { try store.activatePlan(versionID: plan.id) }
        catch { issue = error.localizedDescription }
    }

    private func activate(_ program: WeeklyProgram) {
        do { try store.activateWeeklyProgram(id: program.id) }
        catch { issue = error.localizedDescription }
    }

    private func remove(_ target: PlanLibraryDeletion) {
        deleting = nil
        do {
            switch target {
            case .plan(let plan): try store.deletePlan(planID: plan.planID)
            case .program(let program): try store.deleteWeeklyProgram(id: program.id)
            }
        } catch { issue = error.localizedDescription }
    }
}

@MainActor
private struct PlanLibraryDetailView: View {
    let store: TrainingStore
    let planID: UUID
    var editPlan: ((PlanVersion?) -> Void)? = nil
    @State private var issue: String?
    @State private var confirmingDelete = false

    private var plan: PlanVersion? {
        store.planVersions.filter { $0.planID == planID }.max { $0.version < $1.version }
    }
    private var isDeleted: Bool { store.deletedPlanIDs.contains(planID) }

    var body: some View {
        List {
            if let plan {
                Section {
                    LabeledContent("版本", value: "v\(plan.version)")
                    LabeledContent("状态", value: isDeleted ? "已删除 · 记录保留" : store.currentPlan?.id == plan.id ? "当前生效" : "已保存")
                    Text(plan.confirmedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                }
                Section("动作与目标") {
                    ForEach(plan.items) { item in
                        NavigationLink { ExerciseDetailView(exercise: item.exercise, store: store) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.exercise.name).font(.headline)
                                Text(planItemSummary(item)).font(.subheadline).foregroundStyle(.secondary)
                                Text("休息 \(UIInput.number(item.restSeconds)) 秒").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                }
                Section {
                    if isDeleted {
                        Button("恢复计划") { perform { try store.restorePlan(planID: planID) } }
                        Text("恢复到计划库，不自动设为当前。旧版本和训练记录一直保留。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if let editPlan {
                        if store.currentPlan?.id != plan.id {
                            Button("设为当前计划") { perform { try store.activatePlan(versionID: plan.id) } }
                            if store.currentWeeklyProgram != nil {
                                Text("设为当前后切换为手动安排；原周计划保留在计划库。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        Button("编辑副本") { editPlan(plan) }
                        Button("删除计划", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } else {
                        Text("计划已恢复到计划库，尚未自动生效。返回“训练”页面后可选择设为当前或编辑。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView("没有找到计划", systemImage: "doc.questionmark")
            }
        }
        .navigationTitle(plan?.name ?? "计划详情").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("删除这个计划？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除计划，保留训练历史", role: .destructive) { perform { try store.deletePlan(planID: planID) } }
            Button("取消", role: .cancel) { }
        } message: { Text("旧版本、已完成记录和进行中的训练保留。可从“已删除计划”恢复。") }
        .fitnessError($issue)
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { issue = error.localizedDescription }
    }
}

@MainActor
private struct DeletedPlanLibraryView: View {
    let store: TrainingStore
    @State private var issue: String?
    @State private var status: String?

    var body: some View {
        List {
            Section {
                Text("这些计划已从当前安排移除，旧版本和训练记录保留。恢复后需要你再选择是否生效。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if store.deletedPlans.isEmpty && store.deletedWeeklyPrograms.isEmpty {
                ContentUnavailableView("没有已删除计划", systemImage: "trash", description: Text("删除的计划会显示在这里，可以查看和恢复。"))
            }
            if !store.deletedPlans.isEmpty {
                Section("手动计划") {
                    ForEach(store.deletedPlans.sorted { $0.confirmedAt > $1.confirmedAt }) { plan in
                        NavigationLink { PlanLibraryDetailView(store: store, planID: plan.planID) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(plan.name).font(.headline)
                                Text("v\(plan.version) · \(plan.items.count) 个动作").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("恢复", systemImage: "arrow.uturn.backward") {
                                do { try store.restorePlan(planID: plan.planID); status = "已恢复“\(plan.name)”，尚未设为当前。" }
                                catch { issue = error.localizedDescription }
                            }.tint(.green)
                        }
                    }
                }
            }
            if !store.deletedWeeklyPrograms.isEmpty {
                Section("周计划") {
                    ForEach(store.deletedWeeklyPrograms.sorted { $0.confirmedAt > $1.confirmedAt }) { program in
                        NavigationLink { DeletedWeeklyProgramView(store: store, programID: program.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(program.selectedOption?.title ?? "周计划").font(.headline)
                                Text(program.confirmedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("恢复", systemImage: "arrow.uturn.backward") {
                                do { try store.restoreWeeklyProgram(id: program.id); status = "周计划已恢复，尚未设为当前。" }
                                catch { issue = error.localizedDescription }
                            }.tint(.green)
                        }
                    }
                }
            }
        }.navigationTitle("已删除计划").navigationBarTitleDisplayMode(.inline).fitnessError($issue)
    }
}

@MainActor
private struct DeletedWeeklyProgramView: View {
    let store: TrainingStore
    let programID: UUID
    @State private var issue: String?

    private var program: WeeklyProgram? { store.weeklyPrograms.first { $0.id == programID } }
    private var isDeleted: Bool { store.deletedWeeklyPrograms.contains { $0.id == programID } }

    var body: some View {
        List {
            if let program, let option = program.selectedOption {
                Section {
                    Text(option.title).font(.headline)
                    LabeledContent("状态", value: isDeleted ? "已删除 · 记录保留" : store.currentWeeklyProgram?.id == programID ? "已恢复 · 当前生效" : "已恢复 · 尚未生效")
                    Text(program.confirmedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    if isDeleted { Button("恢复这份周计划") { restore() } }
                }
                ForEach(option.days.sorted { $0.weekday < $1.weekday }) { day in
                    Section("\(weekdayTitle(day.weekday)) · \(day.title)") {
                        if day.isRestDay { Text("休息日").foregroundStyle(.secondary) }
                        ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ExerciseCatalog.exercise(id: item.exerciseID)?.name ?? "未找到动作")
                                Text(planningItemSummary(item))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section { Text("这是保留的周计划内容。恢复不会自动生效；不会从这里删除或覆盖训练历史。")
                        .font(.footnote).foregroundStyle(.secondary) }
            } else { ContentUnavailableView("没有找到周计划", systemImage: "calendar.badge.exclamationmark") }
        }.navigationTitle("已删除周计划").navigationBarTitleDisplayMode(.inline).fitnessError($issue)
    }

    private func restore() {
        do { try store.restoreWeeklyProgram(id: programID) }
        catch { issue = error.localizedDescription }
    }
}

private func planItemSummary(_ item: PlannedExercise) -> String {
    if let reps = item.targetReps { return "\(item.setCount) 组 × \(reps) 次" }
    if let seconds = item.targetSeconds { return "\(item.setCount) 组 × \(UIInput.number(seconds)) 秒" }
    return "\(item.setCount) 组 · 目标未知"
}

private func weekdayTitle(_ weekday: Int) -> String {
    [1: "周一", 2: "周二", 3: "周三", 4: "周四", 5: "周五", 6: "周六", 7: "周日"][weekday] ?? "未知日期"
}

private func planningItemSummary(_ item: PlanningItem) -> String {
    if let reps = item.targetReps { return "\(item.setCount) 组 × \(reps) 次" }
    if let seconds = item.targetSeconds { return "\(item.setCount) 组 × \(UIInput.number(seconds)) 秒" }
    return "\(item.setCount) 组 · 目标未知"
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
            Section { Text("训练历史当前为只读；历史更正界面尚未实现，原始记录不会在这里被覆盖。")
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
