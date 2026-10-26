import SwiftUI
import FitnessCore

@MainActor
struct PlanEditorView: View {
    let store: TrainingStore
    let revising: PlanVersion?
    let template: PlanVersion?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var items: [PlannedExercise]
    @State private var picking = false
    @State private var confirmation = false
    @State private var issue: String?

    init(store: TrainingStore, revising: PlanVersion?, template: PlanVersion? = nil) {
        self.store = store
        self.revising = revising
        self.template = template
        _name = State(initialValue: revising?.name ?? template.map { $0.name + "副本" } ?? "")
        let copiedItems: [PlannedExercise] = template?.items.map { item in
            var copy = item
            copy.id = UUID()
            return copy
        } ?? []
        _items = State(initialValue: revising?.items ?? copiedItems)
    }

    var body: some View {
        Form {
            Section("计划名称") {
                TextField("例如：上肢推训练", text: $name)
                if let revising {
                    Text("正在编辑 v\(revising.version) 的副本。确认后产生新版本；旧版及已开始的训练保持原样。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let template {
                    Text("以“\(template.name)”为起点，另存为独立的手动计划。确认前不会修改原计划或周安排。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("这是完全手动创建的计划，不是 AI 或算法为你制定的处方。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if store.currentWeeklyProgram != nil {
                    Text("确认保存后会切换为这个手动计划；原周计划保留在计划库，内容和训练历史不变。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let revising, store.deletedPlanIDs.contains(revising.planID) {
                    Text("这个计划已被删除，不能继续保存此编辑副本。请取消后从“已删除计划”恢复，再重新编辑。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("动作顺序") {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack { Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary); Text(item.exercise.name) }
                }.onDelete { items.remove(atOffsets: $0) }.onMove { items.move(fromOffsets: $0, toOffset: $1) }
                Button("添加动作", systemImage: "plus") { picking = true }
            }
            ForEach($items) { $item in
                Section(item.exercise.name) {
                    Stepper("正式组：\(item.setCount) 组", value: $item.setCount, in: 1...30)
                    if item.exercise.metric == .repetitions {
                        if let reps = item.targetReps {
                            Stepper("目标次数：\(reps) 次", value: Binding(
                                get: { item.targetReps ?? reps }, set: { item.targetReps = $0 }
                            ), in: 1...100)
                        } else {
                            LabeledContent("目标次数", value: "未知")
                            Button("填写目标次数（初值 10 次）") { item.targetReps = 10 }
                        }
                    } else {
                        if let seconds = item.targetSeconds {
                            Stepper("目标时长：\(UIInput.number(seconds)) 秒", value: Binding(
                                get: { item.targetSeconds ?? seconds }, set: { item.targetSeconds = $0 }
                            ), in: 5...14_400, step: item.exercise.metric == .cardio ? 60 : 5)
                        } else {
                            LabeledContent("目标时长", value: "未知")
                            Button(item.exercise.metric == .cardio ? "填写目标时长（初值 10 分钟）" : "填写目标时长（初值 30 秒）") {
                                item.targetSeconds = item.exercise.metric == .cardio ? 600 : 30
                            }
                        }
                    }
                    Stepper("组间休息：\(UIInput.number(item.restSeconds)) 秒", value: $item.restSeconds, in: 0...900, step: 15)
                    Text("负重口径：\(item.exercise.loadConvention.title)。实际重量开训后由你填写，系统不猜最佳重量。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("新动作的 3 组/10 次等是可编辑的手动表单初值，不是经过身体状态评估的个人建议。确认前请按你的真实能力和运动限制修改。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(revising != nil ? "编辑计划副本" : template != nil ? "另存手动副本" : "创建手动计划")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .confirmationAction) {
                Button("预览确认") { validateDraft() }
                    .disabled(items.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDeletedRevision)
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ExercisePickerView(store: store) { exercise in
                    items.append(PlannedExercise(exercise: exercise, targetReps: exercise.metric == .repetitions ? 10 : nil,
                                                 targetSeconds: exercise.metric == .repetitions ? nil : exercise.metric == .cardio ? 600 : 30))
                }
            }
        }
        .confirmationDialog("确认使这个计划版本生效？", isPresented: $confirmation, titleVisibility: .visible) {
            Button("确认保存并生效") { confirm() }
            Button("继续编辑", role: .cancel) { }
        } message: {
            Text("\(name) · \(items.count) 个动作 · \(items.reduce(0) { $0 + $1.setCount }) 组。\(revising == nil ? "将创建独立的新计划并设为当前。" : "将产生 v\((revising?.version ?? 0) + 1) 并设为当前，保留旧版本。")\(store.currentWeeklyProgram != nil ? "原周计划将保留在计划库，不再作为当前安排。" : "")")
        }
        .fitnessError($issue)
    }

    private var isDeletedRevision: Bool {
        revising.map { store.deletedPlanIDs.contains($0.planID) } ?? false
    }

    private func validateDraft() {
        do {
            try PlanVersion(name: name.trimmingCharacters(in: .whitespacesAndNewlines), items: items).validate()
            confirmation = true
        } catch { issue = error.localizedDescription }
    }

    private func confirm() {
        do {
            try store.confirmPlan(name: name.trimmingCharacters(in: .whitespacesAndNewlines), items: items, revising: revising)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
