import SwiftUI
import FitnessCore

@MainActor
struct ExerciseLibraryView: View {
    let store: TrainingStore
    @State private var search = ""
    @State private var kind: TrainingKind?
    @State private var creating = false

    private var filtered: [Exercise] {
        store.allExercises.filter { exercise in
            (kind == nil || exercise.kind == kind) && (search.isEmpty ||
                "\(exercise.name) \(exercise.englishName) \(exercise.equipment) \(exercise.muscle)"
                    .localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("训练类型", selection: $kind) {
                    Text("全部").tag(nil as TrainingKind?)
                    ForEach(TrainingKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented)
            }
            Section {
                ForEach(filtered) { exercise in
                    NavigationLink { ExerciseDetailView(exercise: exercise, store: store) } label: {
                        ExerciseListLabel(exercise: exercise)
                    }
                }
                if filtered.isEmpty { Text("没有符合条件的动作，请修改筛选或创建自定义动作。").foregroundStyle(.secondary) }
            } footer: {
                Text("通用动作目录不是你的个人训练处方。自定义动作暂不参与自动推荐；教学视频尚未提供。")
            }
        }
        .navigationTitle("动作库").searchable(text: $search, prompt: "名称、英文、器械或肌群")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("自定义", systemImage: "plus") { creating = true } } }
        .sheet(isPresented: $creating) { NavigationStack { CustomExerciseView(store: store) } }
    }
}

struct ExerciseListLabel: View {
    let exercise: Exercise
    var body: some View {
        HStack(spacing: 12) {
            ExerciseTile(exercise: exercise)
            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name).font(.subheadline.weight(.semibold))
                Text("\(exercise.muscle) · \(exercise.equipment)\(exercise.isCustom ? " · 自定义" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }
}

@MainActor
struct ExercisePickerView: View {
    let store: TrainingStore
    let select: (Exercise) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        List(store.allExercises.filter { search.isEmpty || "\($0.name) \($0.englishName) \($0.equipment)".localizedCaseInsensitiveContains(search) }) { exercise in
            Button {
                select(exercise)
                dismiss()
            } label: { ExerciseListLabel(exercise: exercise) }.buttonStyle(.plain)
        }
        .navigationTitle("选择动作").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索真实动作")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

@MainActor
struct ExerciseDetailView: View {
    let exercise: Exercise
    let store: TrainingStore

    var body: some View {
        List {
            Section { ExerciseListLabel(exercise: exercise)
                LabeledContent("英文名称", value: exercise.englishName)
                LabeledContent("记录方式", value: exercise.metric.title)
                LabeledContent("负重口径", value: exercise.loadConvention.title)
            }
            Section("文字提示") {
                if exercise.instructions.isEmpty { Text("这个动作尚未填写经过核验的文字说明。").foregroundStyle(.secondary) }
                ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                    Text("\(index + 1). \(instruction)")
                }
            }
            Section("教学素材") {
                Label("示范动图和完整教学视频尚未提供", systemImage: "video.slash")
                Text("后续逐项核验授权与动作正确性后接入，不用占位播放按钮冒充真实视频。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近个人记录") {
                if let set = store.previousSet(for: exercise.id) {
                    LabeledContent("重量", value: set.loadKG.map { UIInput.number($0) + " kg" } ?? "未记录")
                    LabeledContent("次数", value: set.reps.map(String.init) ?? "未记录")
                    LabeledContent("持续时间", value: set.durationSeconds.map { UIInput.duration($0) } ?? "未记录")
                } else { Text("还没有该动作的已完成记录。").foregroundStyle(.secondary) }
            }
        }.navigationTitle(exercise.name).navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
struct CustomExerciseView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var englishName = ""
    @State private var kind = TrainingKind.strength
    @State private var metric = RecordingMetric.repetitions
    @State private var convention = LoadConvention.total
    @State private var equipment = ""
    @State private var muscle = ""
    @State private var note = ""
    @State private var issue: String?

    var body: some View {
        Form {
            Section("名称与类型") {
                TextField("中文名称（必填）", text: $name)
                TextField("英文名称（可留空）", text: $englishName)
                Picker("类型", selection: $kind) { ForEach(TrainingKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("记录方式", selection: $metric) { ForEach(RecordingMetric.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker("负重口径", selection: $convention) { ForEach(LoadConvention.allCases, id: \.self) { Text($0.title).tag($0) } }
            }
            Section("补充信息") {
                TextField("器械（未知可留空）", text: $equipment)
                TextField("主要肌群（未知可留空）", text: $muscle)
                TextField("个人提示，非已审核教学", text: $note, axis: .vertical)
            }
            Section { Text("保存后获得固定唯一 ID，可用于手动计划和自由训练。自定义内容不代表已获技术审核，不能用于自动推荐。")
                    .font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("自定义动作").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.fitnessError($issue)
    }

    private func save() {
        do {
            let exercise = Exercise(id: "custom.\(UUID().uuidString.lowercased())", name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    englishName: englishName, kind: kind, metric: metric, equipment: equipment.isEmpty ? "未知" : equipment,
                                    muscle: muscle.isEmpty ? "未知" : muscle, loadConvention: convention,
                                    isCustom: true, instructions: note.isEmpty ? [] : ["个人备注：\(note)"])
            try store.addCustomExercise(exercise)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
