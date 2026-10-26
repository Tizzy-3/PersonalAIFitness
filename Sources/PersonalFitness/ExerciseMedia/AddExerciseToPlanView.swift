import SwiftUI
import FitnessCore

@MainActor
struct AddExerciseToPlanView: View {
    let exercise: Exercise
    let store: TrainingStore
    private let basePlan: PlanVersion?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var setCount = 3
    @State private var repetitions = "10"
    @State private var seconds = ""
    @State private var rest = "90"
    @State private var issue: String?
    @State private var confirming = false

    init(exercise: Exercise, store: TrainingStore) {
        self.exercise = exercise
        self.store = store
        basePlan = store.currentPlan
        _name = State(initialValue: store.currentPlan?.name ?? "我的训练计划")
    }

    var body: some View {
        Form {
            Section(basePlan == nil ? "新建手动计划" : "加入当前计划的副本") {
                TextField("计划名称", text: $name)
                if let basePlan {
                    Text("原方案：v\(basePlan.version)，\(basePlan.items.count) 个动作、\(basePlan.items.reduce(0) { $0 + $1.setCount }) 组。")
                    ForEach(basePlan.items) { item in
                        LabeledContent(item.exercise.name, value: "\(item.setCount) 组")
                    }
                } else if store.currentWeeklyProgram != nil {
                    Text("当前使用每周安排。确认后另建独立手动计划并切换使用；原周计划和训练历史保留。")
                } else {
                    Text("当前还没有生效计划，确认后创建 v1。")
                }
            }
            Section("新增动作 · \(exercise.name)") {
                Stepper("\(setCount) 组", value: $setCount, in: 1...30)
                if exercise.metric == .repetitions {
                    TextField("目标次数", text: $repetitions).keyboardType(.numberPad)
                } else {
                    TextField("目标时间（秒，可留空）", text: $seconds).keyboardType(.decimalPad)
                }
                TextField("组间休息（秒）", text: $rest).keyboardType(.decimalPad)
                Text("负重口径：\(exercise.loadConvention.title)。实际重量开训时手动填写。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("确认后的方案") {
                Text("\(name) · v\((basePlan?.version ?? 0) + 1)")
                Text("\((basePlan?.items.count ?? 0) + 1) 个动作，原顺序之后加入 \(exercise.name)。")
                Text("保存新的计划版本，保留旧版与训练历史；已开始的训练继续使用原快照。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Text("组数、次数与休息是可编辑的手动表单初值，不是系统为你评估的训练处方。请按个人能力与运动限制调整。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("加入计划").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("预览确认") {
                    do { _ = try draft(); confirming = true } catch { issue = error.localizedDescription }
                }
            }
        }
        .confirmationDialog("确认让这个新版本生效？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认加入并生效") { save() }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("新增 \(exercise.name)，生成 v\((basePlan?.version ?? 0) + 1)。拒绝或取消不会改动原计划。")
        }
        .fitnessError($issue)
    }

    private func draft() throws -> PlannedExercise {
        let reps = exercise.metric == .repetitions ? try UIInput.integer(repetitions, label: "目标次数") : nil
        let duration = exercise.metric == .repetitions ? nil : try UIInput.double(seconds, label: "目标时间")
        guard let restSeconds = try UIInput.double(rest, label: "组间休息") else {
            throw UIInput.Invalid(message: "请明确填写组间休息；不休息请输入 0，空白不会被当成零。")
        }
        let item = PlannedExercise(exercise: exercise, setCount: setCount,
                                   targetReps: reps, targetSeconds: duration,
                                   restSeconds: restSeconds)
        try item.validate()
        return item
    }

    private func save() {
        do {
            guard store.activePlanVersionID == basePlan?.id else { throw StorageError.stalePlan }
            let items = (basePlan?.items ?? []) + [try draft()]
            try store.confirmPlan(name: name.trimmingCharacters(in: .whitespacesAndNewlines), items: items, revising: basePlan)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
