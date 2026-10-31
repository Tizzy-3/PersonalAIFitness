import SwiftUI
import FitnessCore

/// How one movement felt, asked once per movement after its sets rather than after the whole
/// workout. Two taps, no modal: a 1–5 scale plus an optional short note.
///
/// Recorded on the exercise, not on the session, because "legs were fine but my shoulder hurt" is
/// the kind of thing a coach has to be able to act on — a single session-level score cannot express it.
struct ExerciseFeelingCard: View {
    let store: TrainingStore
    let sessionID: UUID
    let item: WorkoutExercise
    @State private var note = ""
    @State private var editing = false
    @State private var issue: String?

    private var completedSets: Int {
        item.sets.filter { $0.kind == .working && $0.isCompleted }.count
    }
    private var plannedSets: Int {
        item.sets.filter { $0.kind == .working }.count
    }
    /// Offered once the movement is done, or when the person asks for it.
    private var isDone: Bool { plannedSets > 0 && completedSets >= plannedSets }

    var body: some View {
        Group {
            if isDone || item.hasFeedback || editing {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    scale
                    if editing || item.hasFeedback {
                        TextField("想补充什么？（可留空）", text: $note, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.system(size: 13.5, design: .rounded))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(FitnessTheme.sunken))
                            .onSubmit { save() }
                        if editing {
                            Button("保存") { save() }
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(FitnessTheme.accent)
                                .frame(minHeight: 44)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .onAppear { note = item.feelingNote ?? "" }
        .fitnessError($issue)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("这个动作的感觉")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(FitnessTheme.muted)
            Spacer(minLength: 4)
            if item.hasFeedback, !editing {
                Button("修改") { editing = true }
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(FitnessTheme.faint)
            }
        }
    }

    /// Five dots rather than a slider: the gesture target stays reachable one-handed, and a coarse
    /// scale is honest about how much a single self-report can tell you.
    private var scale: some View {
        HStack(spacing: 7) {
            ForEach(1...5, id: \.self) { value in
                Button { set(value) } label: {
                    VStack(spacing: 3) {
                        Circle()
                            .fill(value <= (item.exertion ?? 0) ? tint(for: item.exertion ?? 0) : FitnessTheme.sunken)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(
                                value <= (item.exertion ?? 0) ? .clear : FitnessTheme.line, lineWidth: 1))
                        Text(label(value))
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(FitnessTheme.faint)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("感受 \(value) 分，\(label(value))")
            }
            Spacer(minLength: 0)
        }
    }

    private func label(_ value: Int) -> String {
        switch value {
        case 1: return "很轻"
        case 2: return "轻"
        case 3: return "刚好"
        case 4: return "吃力"
        default: return "很吃力"
        }
    }

    private func tint(for value: Int) -> Color {
        switch value {
        case 1, 2: return FitnessTheme.teal
        case 3: return FitnessTheme.accent
        default: return FitnessTheme.orange
        }
    }

    private func set(_ value: Int) {
        do {
            try store.updateSession(id: sessionID) { current in
                guard let index = current.exercises.firstIndex(where: { $0.id == item.id }) else {
                    throw CoreError.invalidState("这个动作已变化，请重新打开训练。")
                }
                current.exercises[index].exertion = value
            }
            Haptics.tap()
        } catch { issue = error.localizedDescription }
    }

    private func save() {
        do {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try store.updateSession(id: sessionID) { current in
                guard let index = current.exercises.firstIndex(where: { $0.id == item.id }) else {
                    throw CoreError.invalidState("这个动作已变化，请重新打开训练。")
                }
                current.exercises[index].feelingNote = trimmed.isEmpty ? nil : trimmed
            }
            editing = false
            Haptics.tap()
        } catch { issue = error.localizedDescription }
    }
}
