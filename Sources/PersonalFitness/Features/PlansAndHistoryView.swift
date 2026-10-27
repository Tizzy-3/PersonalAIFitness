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
    @State private var panel = 0

    private var showingDeletion: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    var body: some View {
        List {
            Section {
                Picker("训练内容", selection: $panel) {
                    Text("我的计划").tag(0)
                    Text("训练历史").tag(1)
                }.pickerStyle(.segmented)
            }.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowBackground(Color.clear)
            if let active = store.activeSession {
                Section("进行中") {
                    Button { openWorkout(active.id) } label: {
                        TrainingLibraryRow(symbol: "arrow.clockwise", color: FitnessTheme.teal,
                                           title: active.name, subtitle: "\(active.status.title) · \(active.completedWorkingSets) 组已完成")
                    }
                }
            }
            if panel == 0 {
            currentSection
            Section("制定与创建") {
                NavigationLink { CoachInterviewView(store: store) } label: {
                    TrainingLibraryRow(symbol: "sparkles", color: FitnessTheme.violet,
                                       title: "让教练为我安排", subtitle: "先了解你，再确认第一份计划")
                }
                Button { editPlan(nil) } label: {
                    TrainingLibraryRow(symbol: "square.and.pencil", color: FitnessTheme.accent,
                                       title: "创建手动计划", subtitle: "自由选择动作、组数与目标")
                }
                Button {
                    do { openWorkout(try store.startWorkout().id) }
                    catch { issue = error.localizedDescription }
                } label: {
                    TrainingLibraryRow(symbol: "play.fill", color: FitnessTheme.teal,
                                       title: "开始自由训练", subtitle: "边练边添加动作，逐组记录")
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
            if !store.visiblePlans.isEmpty {
            Section("我的手动计划") {
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
            } else {
                historySection
            }
        }
        .navigationTitle("训练")
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas)
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
                TrainingLibraryEmptyState(symbol: "calendar", title: "今天的安排，从这里开始", detail: "选择一份已有计划，或建立适合你的训练安排。")
            }
        }
    }

    private var historySection: some View {
        Section("训练历史") {
            let history = store.sessions.filter { !$0.status.isOngoing }.sorted { $0.startedAt > $1.startedAt }
            if history.isEmpty {
                TrainingLibraryEmptyState(symbol: "clock.arrow.circlepath", title: "每一次训练，都会留下记录", detail: "完成或提前结束训练后，在这里回看。")
            }
            ForEach(history) { session in
                NavigationLink { SessionDetailView(session: session) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        if let exercise = session.exercises.first?.exercise { ExerciseTile(exercise: exercise, size: 58) }
                        else { TrainingLibraryGlyph(symbol: "dumbbell", color: FitnessTheme.accent) }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(session.name).font(.headline)
                            Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(session.completedWorkingSets) 组 · \(UIInput.duration(session.elapsed()))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Text(session.status.title).font(.caption2.weight(.medium))
                            .foregroundStyle(session.status == .completed ? FitnessTheme.teal : FitnessTheme.orange)
                    }.padding(.vertical, 5)
                }
            }
        }
    }

    private func planLabel(_ plan: PlanVersion) -> some View {
        HStack(spacing: 12) {
            if let exercise = plan.items.first?.exercise { ExerciseTile(exercise: exercise, size: 60) }
            else { TrainingLibraryGlyph(symbol: "list.bullet.rectangle", color: FitnessTheme.accent) }
            VStack(alignment: .leading, spacing: 7) {
                Text(plan.name).font(.headline)
                Text("\(plan.items.count) 个动作 · \(plan.items.reduce(0) { $0 + $1.setCount }) 组")
                    .font(.caption).foregroundStyle(.secondary)
                Text("v\(plan.version)\(store.currentPlan?.id == plan.id ? " · 当前生效" : " · 已保存")")
                    .font(.caption2.weight(.medium)).foregroundStyle(store.currentPlan?.id == plan.id ? FitnessTheme.teal : FitnessTheme.muted)
            }
        }.padding(.vertical, 5)
    }

    private func programLabel(_ program: WeeklyProgram) -> some View {
        HStack(spacing: 12) {
            TrainingLibraryGlyph(symbol: "calendar", color: FitnessTheme.violet)
            VStack(alignment: .leading, spacing: 7) {
                Text(program.selectedOption?.title ?? "周计划").font(.headline)
                Text("每周 \(program.draft.input.weekdays.count) 个训练日\(store.currentWeeklyProgram?.id == program.id ? " · 当前生效" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Text(program.confirmedAt, style: .date).font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 5)
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
                            HStack(spacing: 12) {
                                ExerciseTile(exercise: item.exercise, size: 64)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.exercise.name).font(.headline)
                                    Text(planItemSummary(item)).font(.subheadline).foregroundStyle(.secondary)
                                    Text("休息 \(UIInput.number(item.restSeconds)) 秒").font(.caption).foregroundStyle(.secondary)
                                }
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
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas)
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
        }.navigationTitle("已删除计划").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(FitnessTheme.canvas).fitnessError($issue)
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
        }.navigationTitle("已删除周计划").navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(FitnessTheme.canvas).fitnessError($issue)
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
                } header: {
                    HStack(spacing: 10) {
                        ExerciseTile(exercise: item.exercise, size: 44)
                        Text(item.exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                    }.textCase(nil)
                }
            }
            Section { Text("训练历史当前为只读；历史更正界面尚未实现，原始记录不会在这里被覆盖。")
                    .font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden).background(FitnessTheme.canvas)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var recorded: [WorkoutSession] {
        store.sessions.filter { !$0.status.isOngoing && $0.exercises.contains(where: { $0.sets.contains(where: \.isCompleted) }) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("每次训练，都算数").font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "chart.bar.xaxis").foregroundStyle(FitnessTheme.accent)
                }
                Text("只统计已保存、至少完成一组的训练。")
                    .font(.subheadline).foregroundStyle(.secondary)
                TrainingMetricCard(title: "记录的训练", value: String(recorded.count), unit: "次",
                                   symbol: "figure.strengthtraining.traditional", color: FitnessTheme.accent)
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    TrainingMetricCard(title: "完成正式组", value: String(recorded.reduce(0) { $0 + $1.completedWorkingSets }), unit: "组",
                                       symbol: "checkmark.circle", color: FitnessTheme.teal)
                    TrainingMetricCard(title: "会话总时长", value: UIInput.duration(recorded.reduce(0) { $0 + $1.elapsed() }), unit: "",
                                       symbol: "clock", color: FitnessTheme.orange)
                }
                if recorded.isEmpty {
                    TrainingLibraryEmptyState(symbol: "chart.bar", title: "进步，从真实记录开始", detail: "完成一组并保存训练后，这里会展示你的训练分布。")
                        .padding(18).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    activityCard
                }
                NavigationLink { ReviewView(store: store) } label: {
                    HStack(spacing: 12) {
                        TrainingLibraryGlyph(symbol: "calendar.badge.clock", color: FitnessTheme.violet)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("周 / 月复盘").font(.headline).foregroundStyle(FitnessTheme.ink)
                            Text("查看训练执行与数据缺口").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(16).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
                DisclosureGroup("统计口径与功能范围") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("会话时长包含组间休息，排除显式暂停。热身组和未完成组不计入完成正式组；按训练开始日期归入本地自然日。")
                        Text("完整完成率、单动作力量与有氧趋势、身体状态分析仍未全部实现。没有真实记录时，不生成进步曲线或恢复总分。")
                    }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }.font(.subheadline).padding(16).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            }.padding(16)
        }.background(FitnessTheme.canvas).navigationTitle("趋势")
    }

    private var recentDays: [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { index in
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return (day, recorded.filter { $0.startedAt >= day && $0.startedAt < end }.count)
        }
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("最近 7 天").font(.headline)
                Spacer()
                Text("\(recentDays.reduce(0) { $0 + $1.count }) 次训练").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(recentDays.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 8) {
                        Text(String(day.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(day.count > 0 ? FitnessTheme.accent : FitnessTheme.canvas)
                                .frame(height: activityHeight(for: day.count))
                        }.frame(height: 88)
                        Text(day.date, format: .dateTime.weekday(.narrow)).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).accessibilityElement(children: .ignore)
                        .accessibilityLabel(day.date.formatted(.dateTime.month().day()))
                        .accessibilityValue("\(day.count)次训练")
                }
            }
        }.padding(18).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func activityHeight(for count: Int) -> CGFloat {
        guard count > 0 else { return 3 }
        let maximum = max(1, recentDays.map { $0.count }.max() ?? 1)
        return max(8, 88 * CGFloat(count) / CGFloat(maximum))
    }
}

private struct TrainingLibraryGlyph: View {
    let symbol: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(color)
            .frame(width: 48, height: 48).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

private struct TrainingLibraryRow: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            TrainingLibraryGlyph(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.vertical, 4)
    }
}

private struct TrainingLibraryEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TrainingLibraryGlyph(symbol: symbol, color: FitnessTheme.accent)
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
    }
}

private struct TrainingMetricCard: View {
    let title: String
    let value: String
    let unit: String
    let symbol: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(FitnessTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }
}
