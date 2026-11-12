import SwiftUI
import FitnessCore

/// A short check-in before executing the scheduled day of an accepted weekly plan.
@MainActor
struct PreWorkoutConversationView: View {
    let store: TrainingStore
    let plan: PlanVersion
    let openWorkout: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var energy: Int?
    @State private var pain: Bool?
    @State private var minutes = ""
    @State private var proposal: AdjustmentProposal?
    @State private var verdict: ReadinessAssessment.Verdict?
    @State private var issue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                message("今天原定「\(plan.name)」。开始前先聊聊你现在的状态，我再看看今天需不需要调整。")
                message("现在精力怎么样？")
                HStack {
                    ForEach(1...5, id: \.self) { value in
                        Button("\(value)") { energy = value; proposal = nil }
                            .buttonStyle(.borderedProminent)
                            .tint(energy == value ? FitnessTheme.accent : FitnessTheme.faint)
                    }
                }
                Text("1 很疲惫 · 5 精力很好").font(.caption).foregroundStyle(.secondary)
                if energy != nil {
                    message("今天有没有疼痛或异常不适？")
                    HStack {
                        Button("没有") { pain = false; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(pain == false ? FitnessTheme.accent : FitnessTheme.faint)
                        Button("有") { pain = true; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(pain == true ? FitnessTheme.accent : FitnessTheme.faint)
                    }
                }
                if pain != nil {
                    message("今天有多少分钟？不确定可以留空。")
                    TextField("可用分钟数", text: $minutes).keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: minutes) { _, _ in proposal = nil }
                    Button("让教练看看今天的安排", action: assess)
                        .buttonStyle(FitnessPrimaryButtonStyle())
                }
                if let proposal {
                    message(proposal.summary)
                    if let items = proposal.todayItems {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("建议今天这样练").font(.headline)
                            ForEach(items) { item in
                                Text("\(item.exercise.name) · \(item.setCount) 组")
                            }
                            Text("只影响今天这次训练，一周安排不变。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("确认调整并开始", action: acceptAndStart)
                            .buttonStyle(FitnessPrimaryButtonStyle())
                    } else if verdict == .normal {
                        Button("按原计划开始", action: acceptAndStart)
                            .buttonStyle(FitnessPrimaryButtonStyle())
                    } else {
                        Text("这次没有可直接开始的调整，请先处理不适或补充情况。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }.padding(18)
        }
        .navigationTitle("开练前聊聊")
        .navigationBarTitleDisplayMode(.inline)
        .fitnessError($issue)
    }

    private func message(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func assess() {
        do {
            guard let energy, let pain, store.scheduledPlan()?.id == plan.id else {
                throw CoreError.invalidState("今天的安排已经变化，请返回后重新开始。")
            }
            let available = try UIInput.integer(minutes, label: "可用分钟数")
            try store.saveCheckIn(PreWorkoutCheckIn(energy: energy, painReported: pain, availableMinutes: available))
            let assessment = try store.refreshReadiness()
            verdict = assessment.verdict
            proposal = try store.proposeAdjustment(readiness: assessment)
        } catch { issue = error.localizedDescription }
    }

    private func acceptAndStart() {
        do {
            guard let proposal, store.scheduledPlan()?.id == plan.id else {
                throw CoreError.invalidState("今天的安排已经变化，请返回后重新开始。")
            }
            _ = try store.acceptAdjustment(id: proposal.id)
            let session = try store.startWorkout(plan: plan)
            dismiss()
            openWorkout(session.id)
        } catch { issue = error.localizedDescription }
    }
}
