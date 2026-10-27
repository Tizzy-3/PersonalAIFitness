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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var muscles: [String] {
        let order = ["胸部", "背部", "肩部", "肩后束", "腿部", "股四头肌", "腘绳肌", "臀部", "肱二头肌", "肱三头肌", "核心"]
        return Array(Set(store.allExercises.map(\.muscle))).filter { $0 != "全部" }.sorted {
            let first = order.firstIndex(of: $0) ?? order.count
            let second = order.firstIndex(of: $1) ?? order.count
            return first == second ? $0 < $1 : first < second
        }
    }
    private let equipmentOptions = ["全部", "徒手", "哑铃", "杠铃", "器械", "弹力带", "单车"]

    private var filtered: [Exercise] {
        let matches = store.allExercises.filter { exercise in
            (kind == nil || exercise.kind == kind) &&
            (muscle == "全部" || exercise.muscle == muscle) &&
            (equipment == "全部" || exercise.equipment.contains(equipment) || (equipment == "徒手" && exercise.kind == .bodyweight)) &&
            (!onlyFavorites || store.favoriteExerciseIDs.contains(exercise.id)) &&
            ExerciseDetails.matches(exercise, query: search)
        }
        // Keep source order within each group; show the already supplied teaching assets first.
        return matches.filter { ExerciseDetails.details(for: $0.id)?.media != nil }
            + matches.filter { ExerciseDetails.details(for: $0.id)?.media == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            HStack(alignment: .top, spacing: 0) {
                if !dynamicTypeSize.isAccessibilitySize { muscleSidebar }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(muscle == "全部" ? "全部动作" : muscle).font(.headline)
                                Text("\(filtered.count) 个动作 · 示范优先").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            equipmentMenu
                        }
                        if filtered.isEmpty {
                            libraryEmptyState
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                                    count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                                ForEach(filtered) { exercise in
                                    NavigationLink { ExerciseDetailView(exercise: exercise, store: store) } label: {
                                        ExerciseLibraryCard(exercise: exercise, favorite: store.favoriteExerciseIDs.contains(exercise.id))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { toggleFavorite(exercise.id) } label: {
                                            Label(store.favoriteExerciseIDs.contains(exercise.id) ? "取消收藏" : "收藏动作", systemImage: "star")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 24)
                }
            }
        }
        .background(FitnessTheme.canvas)
        .navigationTitle("动作库").navigationBarTitleDisplayMode(.large)
        .tint(FitnessTheme.accent)
        .sheet(isPresented: $creating) { NavigationStack { CustomExerciseView(store: store) } }
        .fitnessError($issue)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("按肌群找动作，也能按器械筛选").font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("搜索动作名称", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("搜索动作名称、别名、英文或器械")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .accessibilityLabel("清空搜索").frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.leading, 13).padding(.trailing, 3).frame(minHeight: 48)
                .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                Button { creating = true } label: {
                    Image(systemName: "plus").font(.title3.weight(.medium)).frame(width: 48, height: 48)
                        .foregroundStyle(FitnessTheme.accent).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 12))
                }.accessibilityLabel("创建自定义动作")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    typeChip("全部", selection: nil)
                    ForEach(TrainingKind.allCases, id: \.self) { value in typeChip(value.title, selection: value) }
                    Button { onlyFavorites.toggle() } label: {
                        Label("收藏", systemImage: onlyFavorites ? "star.fill" : "star")
                            .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(minHeight: 44)
                            .foregroundStyle(onlyFavorites ? FitnessTheme.accent : .secondary)
                            .background(onlyFavorites ? FitnessTheme.blueTint : FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityAddTraits(onlyFavorites ? .isSelected : [])
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    Picker("主要肌群", selection: $muscle) {
                        Text("全部肌群").tag("全部")
                        ForEach(muscles, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(muscle == "全部" ? "全部肌群" : muscle, systemImage: "figure.strengthtraining.traditional")
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10)
    }

    private func typeChip(_ title: String, selection: TrainingKind?) -> some View {
        Button { kind = selection } label: {
            Text(title).font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
                .foregroundStyle(kind == selection ? FitnessTheme.accent : .secondary)
                .background(kind == selection ? FitnessTheme.blueTint : FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).accessibilityAddTraits(kind == selection ? .isSelected : [])
    }

    private var muscleSidebar: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 6) {
                ForEach(["全部"] + muscles, id: \.self) { value in
                    Button { muscle = value } label: {
                        Text(value).font(.subheadline.weight(muscle == value ? .semibold : .regular))
                            .foregroundStyle(muscle == value ? FitnessTheme.accent : .secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 48)
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(muscle == value ? FitnessTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .leading) {
                                if muscle == value { Capsule().fill(FitnessTheme.accent).frame(width: 3, height: 26) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(muscle == value ? .isSelected : [])
                }
            }.padding(.horizontal, 8).padding(.vertical, 14)
        }
        .frame(width: 82).background(FitnessTheme.blueTint.opacity(0.35))
    }

    private var equipmentMenu: some View {
        Menu {
            Picker("器械", selection: $equipment) {
                ForEach(equipmentOptions, id: \.self) { Text($0 == "全部" ? "全部器械" : $0).tag($0) }
            }
        } label: {
            Label(equipment == "全部" ? "器械筛选" : equipment, systemImage: "slider.horizontal.3")
                .font(.caption.weight(.medium)).foregroundStyle(FitnessTheme.accent).frame(minHeight: 44)
        }
    }

    private var libraryEmptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: onlyFavorites ? "star" : "line.3.horizontal.decrease.circle")
                .font(.title).foregroundStyle(FitnessTheme.accent).accessibilityHidden(true)
            Text(onlyFavorites ? "这里还没有收藏的动作" : "没有符合条件的动作").font(.headline)
            Text("调整类型、肌群或器械，或添加自己的动作。").font(.subheadline).foregroundStyle(.secondary)
            Button("重置筛选") { kind = nil; muscle = "全部"; equipment = "全部"; onlyFavorites = false; search = "" }
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            Button("创建自定义动作", systemImage: "plus") { creating = true }
                .font(.subheadline.weight(.medium)).frame(minHeight: 44)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggleFavorite(_ id: String) {
        do { try store.toggleFavorite(exerciseID: id) }
        catch { issue = error.localizedDescription }
    }
}

struct ExerciseListLabel: View {
    let exercise: Exercise
    var body: some View {
        HStack(spacing: 12) {
            ExerciseTile(exercise: exercise, size: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(exercise.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
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
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent)
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
            Section("动作档案") { ExerciseListLabel(exercise: exercise)
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
                    ExerciseInstructionRow(number: index + 1, text: instruction)
                }
                NavigationLink {
                    CoachView(store: store, initialQuestion: "请依据本地动作资料解释「\(exercise.name)」的步骤与常见错误，说明适用性未知，不修改计划。")
                } label: {
                    Label("让 AI 解释这个动作", systemImage: "bubble.left.and.bubble.right")
                }
            }
            if let detail {
                Section("常见错误") {
                    ForEach(detail.commonMistakes, id: \.self) { mistake in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(FitnessTheme.orange)
                                .padding(.top, 3).accessibilityHidden(true)
                            Text(mistake).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 3)
                    }
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
            Section {
                DisclosureGroup("素材、许可与教学范围") {
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
            }
            Section("最近个人记录") {
                if let set = store.previousSet(for: exercise.id) {
                    LabeledContent("重量", value: set.loadKG.map { UIInput.number($0) + " kg" } ?? "未记录")
                    LabeledContent("次数", value: set.reps.map(String.init) ?? "未记录")
                    LabeledContent("持续时间", value: set.durationSeconds.map { UIInput.duration($0) } ?? "未记录")
                } else { Text("还没有该动作的已完成记录。").foregroundStyle(.secondary) }
            }
        }.navigationTitle(exercise.name).navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(FitnessTheme.canvas)
        .tint(FitnessTheme.accent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    do { try store.toggleFavorite(exerciseID: exercise.id) }
                    catch { issue = error.localizedDescription }
                } label: { Image(systemName: store.favoriteExerciseIDs.contains(exercise.id) ? "star.fill" : "star") }
                .foregroundStyle(store.favoriteExerciseIDs.contains(exercise.id) ? FitnessTheme.orange : FitnessTheme.accent)
                .accessibilityLabel(store.favoriteExerciseIDs.contains(exercise.id) ? "取消收藏" : "收藏动作")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button("加入训练计划", systemImage: "plus") { addingToPlan = true }
                .buttonStyle(FitnessPrimaryButtonStyle()).padding(.horizontal, 18).padding(.vertical, 10).background(FitnessTheme.canvas)
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
        }.scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent).fitnessError($issue)
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
