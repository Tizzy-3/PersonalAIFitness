import SwiftUI
import FitnessCore

struct WorkoutTableHeader: View {
    let exercise: Exercise
    var body: some View {
        HStack(spacing: 8) {
            Text("组").frame(width: 24)
            Text("上次").frame(maxWidth: .infinity, alignment: .leading)
            Text(exercise.metric == .repetitions ? "重量 kg" : exercise.metric == .cardio ? "分钟" : "秒").frame(width: 62)
            Text(exercise.metric == .repetitions ? "次数" : exercise.metric == .cardio ? "距离 km" : "").frame(width: 58)
            Text("完成").frame(width: 44)
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 10)
            .background(FitnessTheme.canvas.opacity(0.6))
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
            HStack(spacing: 8) {
                Button { details = true } label: {
                    Text(set.kind == .warmup ? "W" : String(number)).font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 24, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("组别与可选强度")
                    .disabled(!canEdit || set.isCompleted)
                Text(previous).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                if item.exercise.metric == .repetitions && item.exercise.loadConvention == .bodyweight {
                    Text("自重").font(.caption).foregroundStyle(.secondary).frame(width: 62, height: 44)
                } else {
                    numberField(text: $draft.first, label: item.exercise.metric == .repetitions ? "第\(number)组重量" : "第\(number)组时长", width: 62, integer: false)
                }
                if item.exercise.metric != .duration {
                    numberField(text: $draft.second, label: item.exercise.metric == .repetitions ? "第\(number)组次数" : "第\(number)组距离公里", width: 58, integer: item.exercise.metric == .repetitions)
                } else { Color.clear.frame(width: 58, height: 44).accessibilityHidden(true) }
                Button { toggleCompletion() } label: {
                    Image(systemName: set.skipped ? "forward.end" : set.isCompleted ? "checkmark.square.fill" : "checkmark.square")
                        .font(.system(size: 23, weight: .medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(set.isCompleted ? FitnessTheme.success : Color.primary)
                        .background(!set.isCompleted && !set.skipped ? FitnessTheme.accent : .clear, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(!canEdit || set.skipped)
                    .accessibilityLabel(set.isCompleted ? "撤销本组完成" : "保存并完成本组")
            }.padding(.horizontal, 12).padding(.vertical, 7)
            if dirty && !set.isCompleted {
                Text("输入尚未保存，离开输入框或完成本组时保存")
                    .font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
        }
        .background(set.isCompleted ? FitnessTheme.success.opacity(0.08) : Color.clear)
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

    private func numberField(text: Binding<String>, label: String, width: CGFloat, integer: Bool) -> some View {
        TextField("—", text: text)
            .font(.body.weight(.medium).monospacedDigit()).multilineTextAlignment(.center)
            .keyboardType(integer ? .numberPad : .decimalPad).focused($inputFocused)
            .frame(width: width, height: 44)
            .background(set.isCompleted ? .clear : FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
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
                inputFocused = false
            }
        } catch { issue = error.localizedDescription }
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
