import SwiftUI
import FitnessCore

/// Every editable constraint remains a local draft until the person confirms the complete boundary.
@MainActor
struct ConstraintReviewView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ConstraintReviewMode?
    @State private var excludedDays = Set<Int>()
    @State private var dateKeys = Set<String>()
    @State private var addingDate = Date()
    @State private var excludedIDs = Set<String>()
    @State private var allowedIDs = Set<String>()
    @State private var avoidKneeling = false
    @State private var avoidFloor = false
    @State private var limitMinutes = false
    @State private var minutes = "30"
    @State private var professionalNote = ""
    @State private var painFree = false
    @State private var complete = false
    @State private var proposal: ConstraintSuggestion?
    @State private var clarification = ""
    @State private var request: Task<Void, Never>?
    @State private var configuration: AIConfiguration?
    @State private var issue: String?
    @State private var status: String?
    @State private var sending = false
    @State private var loaded = false
    @State private var sourceText = ""
    @State private var legacyText = ""

    private let dayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    private var movements: [Exercise] {
        let ids = Set(PlannerEngine.supportedMovementIDs)
        return ExerciseCatalog.exercises.filter { ids.contains($0.id) }
    }
    private var unresolvedQuestions: [String] { (proposal?.questions ?? []) + (proposal?.unresolved ?? []) }
    private var maySave: Bool {
        mode != nil && painFree && complete && request == nil
            && (unresolvedQuestions.isEmpty || !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (mode != .professionalBoundaries || (!professionalNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !allowedIDs.isEmpty))
    }

    var body: some View {
        Form {
            Section("保留你的原话") {
                LabeledContent("教练档案", value: sourceText.isEmpty ? "尚未填写" : sourceText)
                if !legacyText.isEmpty { LabeledContent("原个人档案", value: legacyText) }
                Text("这里不把限制改成“无”。确认的是哪些约束已明确，以及规则应如何执行。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            aiSection
            if let proposal { proposalSection(proposal) }
            Section("这些限制属于哪种情况？") {
                Picker("本人选择", selection: $mode) {
                    Text("请选择，不由AI判断").tag(Optional<ConstraintReviewMode>.none)
                    Text("时间、能力或偏好限制").tag(Optional(ConstraintReviewMode.practicalOnly))
                    Text("已获得允许活动的专业指导").tag(Optional(ConstraintReviewMode.professionalBoundaries))
                }
                Text("第一项仅用于不涉及尚未明确的伤病、疼痛或治疗恢复问题的安排。仍不清楚身体限制时，先继续说明，不勾选确认。")
                    .font(.footnote).foregroundStyle(.secondary)
                if mode == .professionalBoundaries {
                    TextField("记录允许活动的指导及边界", text: $professionalNote, axis: .vertical).lineLimit(3...8)
                    Text("这是本人记录，不是App或AI验证的医疗许可。若还有限制次数、负重或强度等此表无法完整表达的要求，不要确认全部表达。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("休息时间") {
                DisclosureGroup("每周固定休息日 · 已选\(excludedDays.count)天") {
                    ForEach(1...7, id: \.self) { day in Toggle(dayNames[day - 1], isOn: membership(day, in: $excludedDays)) }
                }
                DatePicker("某一天休息", selection: $addingDate, displayedComponents: .date)
                Button("添加这一天") { dateKeys.insert(Self.dateKey(addingDate)) }
                ForEach(dateKeys.sorted(), id: \.self) { key in
                    HStack { Text(key); Spacer(); Button("移除", role: .destructive) { dateKeys.remove(key) } }
                }
                Text("固定休息日每周执行，具体日期仅当天休息；不会擅自把治疗间隔换算成恢复天数。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("动作和时间边界") {
                Toggle("避免跪姿动作", isOn: $avoidKneeling)
                Toggle("避免地面动作", isOn: $avoidFloor)
                DisclosureGroup("明确不做的动作 · \(excludedIDs.count)个") {
                    ForEach(movements) { movement in Toggle(movement.name, isOn: membership(movement.id, in: $excludedIDs)) }
                }
                Toggle("限制每次训练时间", isOn: $limitMinutes)
                if limitMinutes { TextField("15至120分钟", text: $minutes).keyboardType(.numberPad) }
                if mode == .professionalBoundaries {
                    DisclosureGroup("按指导明确允许的动作 · \(allowedIDs.count)个") {
                        ForEach(movements) { movement in Toggle(movement.name, isOn: membership(movement.id, in: $allowedIDs)) }
                    }
                    Text("仅在本人明确选择的允许名单中安排；不选不会理解成全部允许。不够组成可行计划时会解释缺口。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("本人最后核对") {
                Toggle("我确认当前没有疼痛或异常不适", isOn: $painFree)
                Toggle("我确认所有已知限制均已完整表达，未明确的问题已经核实", isOn: $complete)
                Text("上述两项不会由AI勾选，打开核对页时也不会沿用昨天的确认。核对不会修改已生效计划。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("确认并保存训练约束") { save() }
                    .buttonStyle(FitnessPrimaryButtonStyle()).disabled(!maySave)
            }
            if let status { Section { Label(status, systemImage: "checkmark.circle").foregroundStyle(FitnessTheme.teal) } }
        }
        .navigationTitle("核对训练约束").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas)
        .onAppear { load() }
        .onDisappear { request?.cancel() }
        .confirmationDialog("发送限制给你配置的AI整理？", isPresented: $sending, titleVisibility: .visible) {
            Button("确认发送并整理") { suggest() }
            Button("取消", role: .cancel) { }
        } message: { Text("将发送两份限制原文、已保存的本人补充叙述、当前参考日期/时区和规则支持的动作名称/ID；不发送Apple健康原始样本、完整训练记录或密钥正文。结果只作待核对候选。") }
        .fitnessError($issue)
    }

    private var aiSection: some View {
        Section("让教练先帮我整理") {
            Text("可完全手动核对，也可以让AI提出候选和需要进一步问清的问题。AI不能替你确认身体状态或允许活动的范围。")
                .font(.footnote).foregroundStyle(.secondary)
            Button(request == nil ? "发送已保存限制，整理候选" : "正在整理…") { sending = true }
                .disabled(request != nil || configuration == nil)
            if configuration == nil { NavigationLink("配置AI接口") { AISettingsView() } }
            if request != nil { Button("取消请求") { request?.cancel() } }
        }
    }

    @ViewBuilder private func proposalSection(_ value: ConstraintSuggestion) -> some View {
        Section("AI候选 · 尚未写入档案") {
            if !value.excludedWeekdays.isEmpty { Text("每周休息：" + value.excludedWeekdays.map { dayNames[$0 - 1] }.joined(separator: "、")) }
            if !value.restDateKeys.isEmpty { Text("日期休息：" + value.restDateKeys.joined(separator: "、")) }
            if !value.excludedExerciseIDs.isEmpty { Text("不做动作：" + value.excludedExerciseIDs.compactMap { ExerciseCatalog.exercise(id: $0)?.name }.joined(separator: "、")) }
            if value.avoidedPositions.contains(.kneeling) { Text("避免跪姿") }
            if value.avoidedPositions.contains(.floorWork) { Text("避免地面动作") }
            if let max = value.maxSessionMinutes { Text("单次上限：\(max)分钟") }
            ForEach(Array(unresolvedQuestions.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "questionmark.circle") }
            if !unresolvedQuestions.isEmpty {
                TextField("针对以上待澄清问题，补充已核实的情况", text: $clarification, axis: .vertical).lineLimit(2...6)
                Text("不清楚时继续核实，不要猜成已解决。补充会随你的确认保存为本人叙述。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button("把这些候选带入下方，再由我编辑") {
                excludedDays = Set(value.excludedWeekdays); dateKeys = Set(value.restDateKeys)
                excludedIDs = Set(value.excludedExerciseIDs)
                avoidKneeling = value.avoidedPositions.contains(.kneeling); avoidFloor = value.avoidedPositions.contains(.floorWork)
                limitMinutes = value.maxSessionMinutes != nil; minutes = String(value.maxSessionMinutes ?? 30)
                painFree = false; complete = false
                status = "候选仅填入当前表单；请逐项编辑，并由本人确认。"
            }
        }
    }

    private func load() {
        configuration = try? AIConfigurationStorage.load()
        guard !loaded else { return }; loaded = true
        sourceText = store.interview?.profile.restrictions.value ?? ""
        legacyText = store.profile.restrictions
        if let old = store.interview?.profile.constraintReview {
            excludedDays = Set(old.excludedWeekdays); dateKeys = Set(old.restDateKeys)
            excludedIDs = Set(old.excludedExerciseIDs); allowedIDs = Set(old.allowedExerciseIDs ?? [])
            avoidKneeling = old.avoidedPositions.contains(.kneeling); avoidFloor = old.avoidedPositions.contains(.floorWork)
            limitMinutes = old.maxSessionMinutes != nil; minutes = String(old.maxSessionMinutes ?? 30)
            professionalNote = old.professionalGuidanceNote
        }
        // A saved review is evidence of a previous choice, never today's safety confirmation.
        mode = nil; painFree = false; complete = false
    }

    private func suggest() {
        guard request == nil, let configuration, let start = store.interview else { return }
        do {
            guard let key = try AIKeychain.load(for: configuration) else { throw CoachClientError.configuration("请先填写本机API密钥。") }
            let legacy = store.profile.restrictions
            request = Task {
                defer { request = nil }
                do {
                    let value = try await ConstraintSuggestionAPI().suggest(session: start, legacyRestrictions: legacy, configuration: configuration, key: key)
                    guard store.interview == start, store.profile.restrictions == legacy else { throw CoreError.invalidState("请求期间档案已变化，候选未采用，请重新整理。") }
                    proposal = value; clarification = ""; painFree = false; complete = false
                    status = "AI只返回了候选与问题，尚未修改你的资料或计划。"
                } catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }

    private func save() {
        guard maySave, let mode, var session = store.interview else { return }
        do {
            guard session.profile.restrictions.value == sourceText, store.profile.restrictions == legacyText else {
                throw CoreError.invalidState("原始限制已变化，请返回并重新打开核对页；旧核对未覆盖新资料。")
            }
            let date = Date()
            if !clarification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try session.addNarrative(clarification, at: date)
            }
            let maximum: Int?
            if limitMinutes {
                guard let number = Int(minutes), (15...120).contains(number) else { throw CoreError.invalidInput("请填写15至120分钟的明确时间上限。") }
                maximum = number
            } else { maximum = nil }
            let positions: [ConstraintAvoidance] = (avoidKneeling ? [.kneeling] : []) + (avoidFloor ? [.floorWork] : [])
            let review = TrainingConstraintReview(sourceText: sourceText, legacySourceText: legacyText, mode: mode,
                excludedWeekdays: excludedDays.sorted(), restDateKeys: dateKeys.sorted(), excludedExerciseIDs: excludedIDs.sorted(),
                avoidedPositions: positions, allowedExerciseIDs: mode == .professionalBoundaries ? allowedIDs.sorted() : nil,
                maxSessionMinutes: maximum, painFreeConfirmed: painFree, allLimitsRepresentedConfirmed: complete,
                professionalGuidanceNote: mode == .professionalBoundaries ? professionalNote : "", confirmedAt: date)
            try session.confirmConstraintReview(review, at: date)
            try store.saveInterview(session)
            status = "约束已保存，原限制原话保留。返回教练后可按最新资格制定计划；生效计划没有改变。"
            painFree = false; complete = false
            dismiss()
        } catch { issue = error.localizedDescription }
    }

    private func membership<T: Hashable>(_ item: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(item) }, set: { yes in
            if yes { set.wrappedValue.insert(item) } else { set.wrappedValue.remove(item) }
        })
    }
    private static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
