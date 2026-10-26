import SwiftUI
import FitnessCore

@MainActor
struct PlannerView: View {
    let store: TrainingStore
    @State private var goal: PlanningGoal?
    @State private var experience: PlanningExperience?
    @State private var weekdays: Set<Int> = []
    @State private var minutes: String
    @State private var equipment: Set<PlanningEquipment> = []
    @State private var adultConfirmed = false
    @State private var safety = PlanningSafety.unknown
    @State private var painToday: Bool?
    @State private var excluded: Set<String> = []
    @State private var pickingExclusions = false
    @State private var draftID: UUID?
    @State private var unsavedDraft: PlanningDraft?
    @State private var issue: String?

    init(store: TrainingStore) {
        self.store = store
        _minutes = State(initialValue: store.profile.minutesPerSession.map(String.init) ?? "")
    }

    var body: some View {
        Form {
            Section {
                Text("先把安排做实，再让 AI 选择与解释").font(.headline)
                Text("填写实际可训练条件，本地规则生成可行的七天候选；AI 只能从候选中选择并说明取舍。你看完每日动作后明确确认，才替换当前安排。")
                    .font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { AISettingsView() } label: { Label("配置 AI 接口与密钥", systemImage: "slider.horizontal.3") }
            }
            goalsSection
            scheduleSection
            equipmentSection
            safetySection
            Section("不安排的动作") {
                Button("选择排除动作（\(excluded.count) 项）") { pickingExclusions = true }
                Text("从真实动作库选择不喜欢或明确不做的动作。排除不等于已完成伤病适配；存在运动限制时，本批不自动生成。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                if let unsavedDraft {
                    Text("候选已生成，但尚未保存。重试保存不会重新请求 AI。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("重试保存并查看候选") { persist(unsavedDraft) }
                } else {
                    Button("生成可行周计划，进入 AI 安排", systemImage: "calendar.badge.plus") { generate() }
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(store.activeSession != nil)
                }
                if store.activeSession != nil {
                    Text("请先恢复或结束未完成的训练，再制定新的生效安排，避免训练数据变化使草案立即失效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("生成候选不联网、不改变生效计划。下一页可预览后请求 AI，或明确采用离线本地规则方案。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !store.planningDrafts.isEmpty {
                Section("最近制定记录") {
                    ForEach(store.planningDrafts.sorted { $0.createdAt > $1.createdAt }) { draft in
                        NavigationLink { PlanningDraftDetailView(store: store, draftID: draft.id) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(draft.input.goal.title).font(.subheadline.weight(.semibold))
                                Text("每周 \(draft.input.weekdays.count) 天 · \(draft.input.minutesPerSession) 分钟 · \(PlanningDisplay.decision(draft.decision))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(draft.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("本批范围") {
                Text("当前是健康成人的保守起步周计划，支持力量、有氧和徒手。完整身体状态评估、医学限制适配与长期自动进阶尚未完成；没有健康资料时不会编造恢复结论或最佳重量。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("为我制定计划").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $draftID) { id in PlanningDraftDetailView(store: store, draftID: id) }
        .sheet(isPresented: $pickingExclusions) { NavigationStack { PlanningExclusionPicker(selected: $excluded) } }
        .fitnessError($issue)
    }

    private var goalsSection: some View {
        Section("训练方向") {
            Picker("主要目标", selection: $goal) {
                Text("请选择，不猜测目标").tag(nil as PlanningGoal?)
                ForEach(PlanningGoal.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            Picker("训练经验", selection: $experience) {
                Text("请选择当前情况").tag(nil as PlanningExperience?)
                ForEach(PlanningExperience.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }
            if !store.profile.goal.isEmpty { Text("档案目标：\(store.profile.goal)").font(.caption).foregroundStyle(.secondary) }
            if !store.profile.experience.isEmpty { Text("档案经验：\(store.profile.experience)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var scheduleSection: some View {
        Section("实际可训练日与时间") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 8) {
                ForEach(1...7, id: \.self) { day in
                    Button {
                        if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                    } label: {
                        Text(PlanningDisplay.weekday(day)).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(weekdays.contains(day) ? FitnessTheme.accentInk : Color.primary)
                            .background(weekdays.contains(day) ? FitnessTheme.accent : FitnessTheme.canvas,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                }
            }
            HStack {
                Text("每次可用时间")
                Spacer()
                TextField("未知", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 100).accessibilityLabel("每次可训练分钟")
                Text("分钟").foregroundStyle(.secondary)
            }
            Text("填写15–120分钟。估时包含热身、休息与动作转换；不会把所有空闲日都排成高负荷力量日。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var equipmentSection: some View {
        Section("实际可用条件") {
            DisclosureGroup("器械与空间（已选 \(equipment.count) 项）") {
                ForEach(PlanningEquipment.allCases, id: \.self) { item in
                    Toggle(item.title, isOn: Binding(get: { equipment.contains(item) }, set: { value in
                        if value { equipment.insert(item) } else { equipment.remove(item) }
                    }))
                }
            }
            Text("仅选择实际具备且会安全使用的器械。没有器械也请明确选徒手空间；步行或跑步空间需另行确认。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var safetySection: some View {
        Section("生成前确认") {
            Toggle("我确认已年满18岁", isOn: $adultConfirmed)
            Picker("已知运动限制", selection: $safety) {
                ForEach(PlanningSafety.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("今天有疼痛或异常不适吗", selection: $painToday) {
                Text("尚未确认").tag(nil as Bool?)
                Text("没有").tag(Optional(false))
                Text("有").tag(Optional(true))
            }
            if safety != .noKnownRestrictions || painToday != false || !adultConfirmed {
                Text("未知、存在限制或疼痛时不会自动安排训练。你仍可按已有专业建议手动创建与记录。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !store.profile.restrictions.isEmpty {
                Text("档案已填写运动限制或相关说明；生成时会核对冲突，不能用本次选择覆盖已有伤病记录。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink("核对个人档案") { ProfileView(store: store) }
            }
        }
    }

    private func generate() {
        do {
            guard store.activeSession == nil else { throw UIInput.Invalid(message: "请先恢复或结束正在进行的训练。") }
            guard let goal, let experience else { throw UIInput.Invalid(message: "请明确选择主要目标和当前训练经验。") }
            guard let time = try UIInput.integer(minutes, label: "每次分钟数") else { throw UIInput.Invalid(message: "请填写实际可训练分钟数。") }
            let input = PlanningInput(goal: goal, experience: experience, weekdays: weekdays.sorted(), minutesPerSession: time,
                                      equipment: equipment, adultConfirmed: adultConfirmed, safety: safety, painToday: painToday,
                                      excludedExerciseIDs: excluded.sorted())
            let draft = try PlanningDraft.make(input: input, snapshot: store.snapshot())
            unsavedDraft = draft
            persist(draft)
        } catch { issue = error.localizedDescription }
    }

    private func persist(_ draft: PlanningDraft) {
        do { try store.savePlanningDraft(draft); unsavedDraft = nil; draftID = draft.id }
        catch { unsavedDraft = draft; issue = error.localizedDescription }
    }
}

@MainActor
private struct PlanningExclusionPicker: View {
    @Binding var selected: Set<String>
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List(ExerciseCatalog.exercises.filter { ExerciseDetails.matches($0, query: search) }) { exercise in
            Toggle(isOn: Binding(get: { selected.contains(exercise.id) }, set: { value in
                if value { selected.insert(exercise.id) } else { selected.remove(exercise.id) }
            })) { ExerciseListLabel(exercise: exercise) }
        }
        .navigationTitle("排除动作").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索真实动作")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
