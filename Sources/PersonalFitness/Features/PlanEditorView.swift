import SwiftUI
import FitnessCore

@MainActor
struct PlanEditorView: View {
    let store: TrainingStore
    let revising: PlanVersion?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var items: [PlannedExercise]
    @State private var picking = false
    @State private var confirmation = false
    @State private var issue: String?

    init(store: TrainingStore, revising: PlanVersion?) {
        self.store = store
        self.revising = revising
        _name = State(initialValue: revising?.name ?? "")
        _items = State(initialValue: revising?.items ?? [])
    }

    var body: some View {
        Form {
            Section("计划名称") {
                TextField("例如：上肢推训练", text: $name)
                if let revising {
                    Text("正在编辑 v\(revising.version) 的副本。确认后产生新版本；旧版及已开始的训练保持原样。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("这是完全手动创建的计划，不是 AI 或算法为你制定的处方。")
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
                        Stepper("目标次数：\(item.targetReps ?? 10) 次", value: Binding(
                            get: { item.targetReps ?? 10 }, set: { item.targetReps = $0 }
                        ), in: 1...100)
                    } else {
                        Stepper("目标时长：\(UIInput.number(item.targetSeconds ?? 30)) 秒", value: Binding(
                            get: { item.targetSeconds ?? 30 }, set: { item.targetSeconds = $0 }
                        ), in: 5...14_400, step: item.exercise.metric == .cardio ? 60 : 5)
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
        .navigationTitle(revising == nil ? "创建手动计划" : "编辑计划副本")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            ToolbarItem(placement: .confirmationAction) { Button("预览确认") { validateDraft() }.disabled(items.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
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
            Text("\(name) · \(items.count) 个动作 · \(items.reduce(0) { $0 + $1.setCount }) 组。\(revising == nil ? "将创建新的生效计划。" : "将产生 v\((revising?.version ?? 0) + 1)，保留旧版本。")")
        }
        .fitnessError($issue)
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
