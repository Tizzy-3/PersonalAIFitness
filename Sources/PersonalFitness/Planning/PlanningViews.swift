import SwiftUI
import FitnessCore

enum PlanningDisplay {
    static func weekday(_ day: Int) -> String {
        let names = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        return (1...7).contains(day) ? names[day - 1] : "未知星期"
    }
    static func decision(_ value: CoachDecision) -> String {
        switch value { case .pending: return "待确认"; case .accepted: return "已生效"; case .rejected: return "已拒绝" }
    }
    static func target(_ item: PlanningItem) -> String {
        if let reps = item.targetReps { return "\(item.setCount) 组 × \(reps) 次" }
        if let seconds = item.targetSeconds { return "\(item.setCount) 组 × \(UIInput.number(seconds)) 秒" }
        return "\(item.setCount) 组 · 目标未知"
    }
}

@MainActor
struct WeeklyOptionView: View {
    let option: WeeklyPlanOption
    let store: TrainingStore

    var body: some View {
        List {
            Section("方案依据") {
                ForEach(Array(option.rationale.enumerated()), id: \.offset) { _, text in Text(text) }
                Text("规则版本：\(option.rulesVersion)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            ForEach(option.days) { day in
                Section {
                    if day.isRestDay {
                        Label("没有安排正式训练", systemImage: "moon.zzz").foregroundStyle(.secondary)
                    } else {
                        LabeledContent("预计用时", value: "\(day.estimatedMinutesLower)–\(day.estimatedMinutesUpper) 分钟")
                        ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                            if let exercise = ExerciseCatalog.exercise(id: item.exerciseID) {
                                NavigationLink { ExerciseDetailView(exercise: exercise, store: store) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ExerciseListLabel(exercise: exercise)
                                        Text("\(PlanningDisplay.target(item)) · 休息 \(UIInput.number(item.restSeconds)) 秒")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        ForEach(Array(item.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    ForEach(Array(day.notes.enumerated()), id: \.offset) { _, note in Text(note).font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("\(PlanningDisplay.weekday(day.weekday)) · \(day.title)") }
            }
            Section("限制与未知") {
                ForEach(Array(option.limitations.enumerated()), id: \.offset) { _, text in Text(text) }
                Text("时间是包含热身、组间休息与转换的估计区间。实际重量开训时从可控轻重量校准，不存在系统算出的最佳公斤数。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle(option.title).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct WeeklyProgramDetailView: View {
    let store: TrainingStore
    let programID: UUID
    var openWorkout: ((UUID) -> Void)? = nil
    @State private var workoutID: UUID?
    @State private var issue: String?

    private var program: WeeklyProgram? { store.weeklyPrograms.first { $0.id == programID } }

    var body: some View {
        List {
            if let program, let option = program.selectedOption {
                if let review = program.draft.input.constraintReview {
                    PlanningConstraintSummary(review: review)
                }
                Section("已确认周计划") {
                    Text(option.title).font(.headline)
                    Text(program.confirmedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("来源", value: program.draft.selection == nil ? "本地规则方案，由本人确认" : "规则候选 + AI 选择，由本人确认")
                    if let selection = program.draft.selection {
                        if selection.optionID != program.selectedOptionID {
                            Text("你最终选择了另一个可行候选。以下AI说明对应其原推荐，已生效安排以本页的最终方案为准。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(selection.explanation)
                        Text("以上是模型解释，实际动作和剂量以已确认的规则方案为准。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink { WeeklyOptionView(option: option, store: store) } label: { Label("查看完整动作、休息与依据", systemImage: "list.bullet.rectangle") }
                    if !store.visibleWeeklyPrograms.contains(where: { $0.id == programID }) {
                        Text("此周计划已删除，当前仅供查看。训练历史保留；需要重新使用时，先在已删除计划中恢复。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let ongoing = store.activeSession {
                    Section {
                        Button("恢复未结束的训练") { show(ongoing.id) }
                        Text("正在进行的训练保留其开始时快照，不会被本周排程覆盖。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                ForEach(option.days) { day in
                    Section {
                        if day.isRestDay { Text("休息 / 自主轻量日常活动").foregroundStyle(.secondary) }
                        else {
                            Text("\(day.items.count) 个动作 · 预计 \(day.estimatedMinutesLower)–\(day.estimatedMinutesUpper) 分钟")
                                .font(.subheadline)
                            ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(ExerciseCatalog.exercise(id: item.exerciseID)?.name ?? "未知动作")
                                    Spacer()
                                    Text(PlanningDisplay.target(item)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Button("开始\(PlanningDisplay.weekday(day.weekday))这次训练", systemImage: "play.fill") { start(day: day, program: program) }
                                .disabled(store.activeSession != nil || !store.visibleWeeklyPrograms.contains(where: { $0.id == programID }))
                        }
                    } header: { Text("\(PlanningDisplay.weekday(day.weekday)) · \(day.title)") }
                }
                Section("适用范围") {
                    Text("这是每周重复的保守起步安排，不是已经完成长期自动进阶、周期减量或身体恢复评估。需要修改时应重新生成草案并确认；已有训练历史保留。")
                    Text("从此页点击某天表示明确选择该次训练，日历不相同时也不会偷偷移动排期。")
                }.font(.footnote).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("没有找到周计划", systemImage: "calendar.badge.exclamationmark")
            }
        }
        .navigationTitle("每周安排").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $workoutID) { id in WorkoutView(store: store, sessionID: id) }
        .fitnessError($issue)
    }

    private func start(day: PlanningDay, program: WeeklyProgram) {
        do {
            guard let id = program.dayPlanVersionIDs[day.weekday], let plan = store.planVersions.first(where: { $0.id == id }) else {
                throw CoreError.notFound("这天的训练计划")
            }
            show(try store.startWorkout(plan: plan).id)
        } catch { issue = error.localizedDescription }
    }

    private func show(_ id: UUID) {
        if let openWorkout { openWorkout(id) } else { workoutID = id }
    }
}
