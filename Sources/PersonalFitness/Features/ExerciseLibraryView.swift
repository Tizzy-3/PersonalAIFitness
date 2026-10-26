import SwiftUI
import FitnessCore

@MainActor
struct ExerciseLibraryView: View {
    let store: TrainingStore
    @State private var search = ""
    @State private var kind: TrainingKind?
    @State private var creating = false
    @State private var muscle = "全部"
    @State private var equipment = "全部"
    @State private var onlyFavorites = false
    @State private var issue: String?

    private var muscles: [String] { Array(Set(store.allExercises.map(\.muscle))).sorted() }
    private let equipmentOptions = ["全部", "徒手", "哑铃", "杠铃", "器械", "弹力带", "单车"]

    private var filtered: [Exercise] {
        store.allExercises.filter { exercise in
            (kind == nil || exercise.kind == kind) &&
            (muscle == "全部" || exercise.muscle == muscle) &&
            (equipment == "全部" || exercise.equipment.contains(equipment) || (equipment == "徒手" && exercise.kind == .bodyweight)) &&
            (!onlyFavorites || store.favoriteExerciseIDs.contains(exercise.id)) &&
            ExerciseDetails.matches(exercise, query: search)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("训练类型", selection: $kind) {
                    Text("全部").tag(nil as TrainingKind?)
                    ForEach(TrainingKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }.pickerStyle(.segmented)
                HStack {
                    Menu {
                        Picker("主要肌群", selection: $muscle) {
                            Text("全部肌群").tag("全部")
                            ForEach(muscles, id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Label(muscle == "全部" ? "全部肌群" : muscle, systemImage: "figure.strengthtraining.traditional") }
                    Spacer()
                    Menu {
                        Picker("器械", selection: $equipment) {
                            ForEach(equipmentOptions, id: \.self) { Text($0 == "全部" ? "全部器械" : $0).tag($0) }
                        }
                    } label: { Label(equipment == "全部" ? "全部器械" : equipment, systemImage: "slider.horizontal.3") }
                }.font(.subheadline)
                Toggle("只看收藏", isOn: $onlyFavorites)
            }
            Section {
                ForEach(filtered) { exercise in
                    NavigationLink { ExerciseDetailView(exercise: exercise, store: store) } label: {
                        ExerciseListLabel(exercise: exercise)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            do { try store.toggleFavorite(exerciseID: exercise.id) }
                            catch { issue = error.localizedDescription }
                        } label: {
                            Label(store.favoriteExerciseIDs.contains(exercise.id) ? "取消收藏" : "收藏", systemImage: "star")
                        }.tint(.orange)
                    }
                }
                if filtered.isEmpty { Text("没有符合条件的动作，请修改筛选或创建自定义动作。").foregroundStyle(.secondary) }
            } header: {
                Text("\(filtered.count) 个动作")
            } footer: {
                Text("通用动作提示不代表适合你的个人处方。已提供素材的动作可离线查看；示范短片与完整教学视频分开标记。")
            }
        }
        .navigationTitle("动作库").searchable(text: $search, prompt: "名称、别名、英文、器械或动作模式")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("自定义", systemImage: "plus") { creating = true } } }
        .sheet(isPresented: $creating) { NavigationStack { CustomExerciseView(store: store) } }
        .fitnessError($issue)
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
        List(store.allExercises.filter { ExerciseDetails.matches($0, query: search) }) { exercise in
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
    @State private var addingToPlan = false
    @State private var issue: String?

    private var detail: ExerciseDetail? { ExerciseDetails.details(for: exercise.id) }

    var body: some View {
        List {
            Section { ExerciseDemonstrationView(exerciseID: exercise.id) }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            Section { ExerciseListLabel(exercise: exercise)
                LabeledContent("英文名称", value: exercise.englishName)
                if let detail {
                    if !detail.aliases.isEmpty { LabeledContent("别名", value: detail.aliases.joined(separator: "、")) }
                    LabeledContent("动作模式", value: detail.movementPattern)
                    LabeledContent("技术难度", value: detail.difficulty)
                    LabeledContent("主要肌群", value: exercise.muscle)
                    LabeledContent("辅助肌群", value: detail.secondaryMuscles.joined(separator: "、"))
                }
                LabeledContent("记录方式", value: exercise.metric.title)
                LabeledContent("负重口径", value: exercise.loadConvention.title)
            }
            Section("分步骤提示") {
                if exercise.instructions.isEmpty { Text("这个动作尚未填写经过核验的文字说明。").foregroundStyle(.secondary) }
                ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                    Text("\(index + 1). \(instruction)")
                }
                NavigationLink {
                    CoachView(store: store, initialQuestion: "请依据本地动作资料解释「\(exercise.name)」的步骤与常见错误，说明适用性未知，不修改计划。")
                } label: {
                    Label("让 AI 解释这个动作", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if let detail {
                Section("常见错误") {
                    ForEach(detail.commonMistakes, id: \.self) { Text($0) }
                }
                Section("可比较的替代动作") {
                    ForEach(detail.alternativeIDs, id: \.self) { id in
                        if let alternative = ExerciseCatalog.exercise(id: id) {
                            NavigationLink { ExerciseDetailView(exercise: alternative, store: store) } label: { ExerciseListLabel(exercise: alternative) }
                        }
                    }
                    Text("替代项只用于比较，不保证适合你的伤病、器械或能力；不会自动替换计划。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !detail.progressionIDs.isEmpty {
                    Section("可了解的进阶变式") {
                        ForEach(detail.progressionIDs, id: \.self) { id in
                            if let progression = ExerciseCatalog.exercise(id: id) {
                                NavigationLink { ExerciseDetailView(exercise: progression, store: store) } label: { ExerciseListLabel(exercise: progression) }
                            }
                        }
                        Text("了解变式不代表现在应该升级难度，先以稳定、无痛的执行为前提。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("素材与来源") {
                if let media = detail?.media {
                    LabeledContent("素材类型", value: media.kind == .video ? "动作示范短片" : "静态动作图示")
                    LabeledContent("作者", value: media.author)
                    if let license = URL(string: media.licenseURL), let source = URL(string: media.sourceURL) {
                        Link("许可：\(media.licenseName)", destination: license)
                        Link("查看 wger 原始媒体", destination: source)
                    }
                    Text("媒体已压缩或调整尺寸供离线查看，衍生媒体沿用原许可。来源不等于已完成针对你个人的动作评估。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("这个动作暂未提供已核验的示范媒体。").foregroundStyle(.secondary)
                }
                Label("完整教学视频尚未接入", systemImage: "video.slash")
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    do { try store.toggleFavorite(exerciseID: exercise.id) }
                    catch { issue = error.localizedDescription }
                } label: { Image(systemName: store.favoriteExerciseIDs.contains(exercise.id) ? "star.fill" : "star") }
                .accessibilityLabel(store.favoriteExerciseIDs.contains(exercise.id) ? "取消收藏" : "收藏动作")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("加入训练计划", systemImage: "plus") { addingToPlan = true }
                .buttonStyle(FitnessPrimaryButtonStyle()).padding().background(FitnessTheme.canvas)
        }
        .sheet(isPresented: $addingToPlan) { NavigationStack { AddExerciseToPlanView(exercise: exercise, store: store) } }
        .fitnessError($issue)
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
