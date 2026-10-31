import SwiftUI
import FitnessCore

struct WorkoutTableHeader: View {
    let exercise: Exercise
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize >= .xxLarge {
                HStack { Text("逐组记录"); Spacer(); Text("点组号编辑强度") }
            } else {
                HStack(spacing: 6) {
                    Text("组").frame(width: 44)
                    Text("上次").frame(minWidth: 38, maxWidth: .infinity, alignment: .leading)
                    Text(exercise.metric == .repetitions ? "重量 kg" : exercise.metric == .cardio ? "分钟" : "秒").frame(width: 56)
                    Text(exercise.metric == .repetitions ? "次数" : exercise.metric == .cardio ? "距离 km" : "").frame(width: 52)
                    Text("完成").frame(width: 44)
                }
            }
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 12)
    }
}

struct SetInputDraft: Equatable {
    var kind: SetKind
    var first: String
    var second: String
    var rpe: String
    var rir: String

    init(_ set: LoggedSet, exercise: Exercise) {
        kind = set.kind
        switch exercise.metric {
        case .repetitions:
            first = UIInput.number(set.loadKG)
            second = set.reps.map(String.init) ?? ""
        case .duration:
            first = UIInput.number(set.durationSeconds)
            second = ""
        case .cardio:
            first = UIInput.number(set.durationSeconds.map { $0 / 60 })
            second = UIInput.number(set.distanceMeters.map { $0 / 1_000 })
        }
        rpe = UIInput.number(set.rpe)
        rir = set.rir.map(String.init) ?? ""
    }

    func applying(to source: LoggedSet, exercise: Exercise) throws -> LoggedSet {
        var result = source
        result.kind = kind
        result.rpe = try UIInput.double(rpe, label: "RPE")
        result.rir = try UIInput.integer(rir, label: "RIR")
        switch exercise.metric {
        case .repetitions:
            result.loadKG = exercise.loadConvention == .bodyweight ? nil : try UIInput.double(first, label: "重量")
            result.reps = try UIInput.integer(second, label: "次数")
        case .duration:
            result.durationSeconds = try UIInput.double(first, label: "持续秒数")
        case .cardio:
            result.durationSeconds = try UIInput.double(first, label: "运动分钟数").map { $0 * 60 }
            result.distanceMeters = try UIInput.double(second, label: "距离公里数").map { $0 * 1_000 }
        }
        try result.validate(for: exercise)
        return result
    }
}

@MainActor
struct WorkoutSetRow: View {
    let store: TrainingStore
    let sessionID: UUID
    let item: WorkoutExercise
    let set: LoggedSet
    let number: Int
    let canEdit: Bool
    @State private var draft: SetInputDraft
    @State private var issue: String?
    @State private var details = false
    @FocusState private var inputFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(store: TrainingStore, sessionID: UUID, item: WorkoutExercise, set: LoggedSet, number: Int, canEdit: Bool) {
        self.store = store; self.sessionID = sessionID; self.item = item; self.set = set; self.number = number; self.canEdit = canEdit
        _draft = State(initialValue: SetInputDraft(set, exercise: item.exercise))
    }

    private var dirty: Bool { draft != SetInputDraft(set, exercise: item.exercise) }
    private var previous: String {
        guard let last = store.previousSet(for: item.exercise.id) else { return "—" }
        switch item.exercise.metric {
        case .repetitions:
            return "\(last.loadKG.map { UIInput.number($0) + " × " } ?? "")\(last.reps.map(String.init) ?? "—")"
        case .duration: return last.durationSeconds.map { UIInput.number($0) + " 秒" } ?? "—"
        case .cardio: return last.durationSeconds.map { UIInput.number($0 / 60) + " 分" } ?? "—"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if dynamicTypeSize >= .xxLarge { expandedRow }
                else { compactRow }
            }.padding(.horizontal, 10).padding(.vertical, 7)
            if dirty && !set.isCompleted {
                Text("输入尚未保存，离开输入框或完成本组时保存")
                    .font(.caption2).foregroundStyle(FitnessTheme.orange).padding(.horizontal, 12).padding(.bottom, 6)
            }
        }
        .background(set.isCompleted ? FitnessTheme.success.opacity(0.09) : FitnessTheme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 8).padding(.bottom, 6)
        .onChange(of: set) { _, newValue in
            if !inputFocused { draft = SetInputDraft(newValue, exercise: item.exercise) }
        }
        .onChange(of: inputFocused) { previous, focused in
            if previous && !focused && dirty && canEdit && !set.isCompleted { _ = saveInput() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && dirty && canEdit && !set.isCompleted { _ = saveInput() }
        }
        .sheet(isPresented: $details) {
            NavigationStack { SetDetailEditor(draft: $draft) { saveInput() } }
        }
        .fitnessError($issue)
        .toolbar {
            if inputFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("组别 / RPE / RIR") { details = true }
                    Spacer()
                    Button("保存输入") { if saveInput() { inputFocused = false } }
                }
            }
        }
    }

    private var compactRow: some View {
        HStack(spacing: 6) {
            kindButton
            Text(previous).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 38, maxWidth: .infinity, alignment: .leading).lineLimit(2)
            firstInput(width: 56)
            if item.exercise.metric != .duration {
                numberField(text: $draft.second, label: secondLabel, width: 52, integer: item.exercise.metric == .repetitions)
            } else { Color.clear.frame(width: 52, height: 44).accessibilityHidden(true) }
            completionButton
        }
    }

    private var expandedRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                kindButton
                VStack(alignment: .leading, spacing: 3) {
                    Text(set.kind.title).font(.subheadline.weight(.semibold))
                    Text("上次：\(previous)").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                completionButton
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.exercise.metric == .repetitions ? "重量 kg" : item.exercise.metric == .cardio ? "时长 分钟" : "时长 秒")
                        .font(.caption).foregroundStyle(.secondary)
                    firstInput(width: nil)
                }.frame(maxWidth: .infinity)
                if item.exercise.metric != .duration {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.exercise.metric == .repetitions ? "次数" : "距离 km").font(.caption).foregroundStyle(.secondary)
                        numberField(text: $draft.second, label: secondLabel, width: nil, integer: item.exercise.metric == .repetitions)
                    }.frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var kindButton: some View {
        Button { details = true } label: {
            ZStack {
                Circle()
                    .fill(set.isCompleted ? FitnessTheme.tealTint
                          : set.skipped ? FitnessTheme.sunken
                          : FitnessTheme.blueTint)
                    .frame(width: 30, height: 30)
                Text(set.kind == .warmup ? "W" : String(number))
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .foregroundStyle(set.isCompleted ? FitnessTheme.teal : FitnessTheme.accent)
                    .monospacedDigit()
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel("第\(number)组，组别与可选强度")
            .disabled(!canEdit || set.isCompleted)
    }

    /// A filled circle reads as "done" at a glance; the ring marks the row the person is on now.
    /// The scale animation is what makes completing a set feel like a press, not a checkbox.
    private var completionButton: some View {
        Button { toggleCompletion() } label: {
            ZStack {
                if set.isCompleted {
                    Circle().fill(FitnessTheme.teal)
                        .frame(width: 32, height: 32)
                        .shadow(color: FitnessTheme.teal.opacity(0.35), radius: 6, y: 2)
                    Image(systemName: set.skipped ? "forward.end.fill" : "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else if set.skipped {
                    Circle().fill(FitnessTheme.sunken).frame(width: 32, height: 32)
                    Image(systemName: "forward.end")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FitnessTheme.faint)
                } else {
                    Circle()
                        .strokeBorder(FitnessTheme.accent.opacity(0.55), lineWidth: 2)
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FitnessTheme.accent.opacity(0.55))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .scaleEffect(set.isCompleted ? 1 : 0.96)
            .animation(FitnessTheme.Motion.celebrate, value: set.isCompleted)
        }.buttonStyle(.plain).disabled(!canEdit || set.skipped)
            .accessibilityLabel(set.isCompleted ? "撤销本组完成" : "保存并完成本组")
            .accessibilityValue(set.skipped ? "已跳过" : set.isCompleted ? "已完成" : "未完成")
    }

    private var secondLabel: String {
        item.exercise.metric == .repetitions ? "第\(number)组次数" : "第\(number)组距离公里"
    }

    @ViewBuilder
    private func firstInput(width: CGFloat?) -> some View {
        if item.exercise.metric == .repetitions && item.exercise.loadConvention == .bodyweight {
            Text("自重").font(.caption).foregroundStyle(.secondary).frame(width: width).frame(maxWidth: width == nil ? .infinity : nil, minHeight: 44)
        } else {
            numberField(text: $draft.first, label: item.exercise.metric == .repetitions ? "第\(number)组重量" : "第\(number)组时长", width: width, integer: false)
        }
    }

    private func numberField(text: Binding<String>, label: String, width: CGFloat?, integer: Bool) -> some View {
        TextField("—", text: text)
            .font(.body.weight(.medium).monospacedDigit()).multilineTextAlignment(.center)
            .keyboardType(integer ? .numberPad : .decimalPad).focused($inputFocused)
            .frame(width: width).frame(maxWidth: width == nil ? .infinity : nil, minHeight: 44)
            .background(set.isCompleted ? Color.clear : FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(set.isCompleted ? Color.clear : FitnessTheme.muted.opacity(0.22)))
            .disabled(!canEdit || set.isCompleted || set.skipped).accessibilityLabel(label)
            .onSubmit { _ = saveInput() }
    }

    @discardableResult
    private func saveInput() -> Bool {
        guard canEdit, !set.isCompleted else { return true }
        do {
            let value = try draft.applying(to: set, exercise: item.exercise)
            try store.updateSession(id: sessionID) { current in
                guard let itemIndex = current.exercises.firstIndex(where: { $0.id == item.id }),
                      let setIndex = current.exercises[itemIndex].sets.firstIndex(where: { $0.id == set.id }) else {
                    throw UIInput.Invalid(message: "这组记录已变化，请重新打开训练。")
                }
                // Focus-loss can arrive after a completion command. A stale draft
                // must never clear a completion that already reached storage.
                guard !current.exercises[itemIndex].sets[setIndex].isCompleted else { return }
                current.exercises[itemIndex].sets[setIndex] = value
            }
            return true
        } catch { issue = error.localizedDescription; return false }
    }

    private func toggleCompletion() {
        do {
            if set.isCompleted {
                try store.updateSession(id: sessionID) { try $0.undoSet(exerciseID: item.id, setID: set.id) }
                Haptics.setReverted()
            } else {
                let value = try draft.applying(to: set, exercise: item.exercise)
                try store.updateSession(id: sessionID) { current in
                    guard let itemIndex = current.exercises.firstIndex(where: { $0.id == item.id }),
                          let setIndex = current.exercises[itemIndex].sets.firstIndex(where: { $0.id == set.id }) else {
                        throw UIInput.Invalid(message: "这组记录已变化，请重试。")
                    }
                    guard !current.exercises[itemIndex].sets[setIndex].isCompleted else {
                        throw UIInput.Invalid(message: "这组已经完成，修改前请先明确撤销完成。")
                    }
                    current.exercises[itemIndex].sets[setIndex] = value
                    try current.completeSet(exerciseID: item.id, setID: set.id)
                }
                // Only after storage accepted it: a haptic for a save that failed would be a lie.
                Haptics.setCompleted()
                inputFocused = false
            }
        } catch { Haptics.warning(); issue = error.localizedDescription }
    }
}

private struct SetDetailEditor: View {
    @Binding var draft: SetInputDraft
    let save: () -> Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section("组别") { Picker("组别", selection: $draft.kind) { ForEach(SetKind.allCases, id: \.self) { Text($0.title).tag($0) } } }
            Section("可选强度") {
                TextField("RPE（可留空）", text: $draft.rpe).keyboardType(.decimalPad)
                TextField("RIR（可留空）", text: $draft.rir).keyboardType(.numberPad)
                Text("不填写时保持未知，不根据重量自动猜测。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("组别与强度").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存输入") { if save() { dismiss() } } }
            }
    }
}
