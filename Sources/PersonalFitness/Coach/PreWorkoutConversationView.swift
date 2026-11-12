import SwiftUI
import FitnessCore

/// A short check-in before executing the scheduled day of an accepted weekly plan.
@MainActor
struct PreWorkoutConversationView: View {
    let store: TrainingStore
    let plan: PlanVersion
    let openWorkout: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var messageSize: CGFloat = 15
    @State private var energy: Int?
    @State private var pain: Bool?
    @State private var soreness: Int?
    @State private var otherConcern: Bool?
    @State private var concernText = ""
    @State private var discussion: [CoachMessage] = []
    @State private var askingCoach = false
    @State private var minutes = ""
    @State private var proposal: AdjustmentProposal?
    @State private var verdict: ReadinessAssessment.Verdict?
    @State private var issue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                message((store.scheduledPlan()?.id == plan.id ? "今天原定" : "你选择了")
                        + "「\(plan.name)」。开始前先聊聊你现在的状态，我再看看今天需不需要调整。")
                message("现在精力怎么样？")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 120 : 48), spacing: 6)], alignment: .leading) {
                    ForEach(1...5, id: \.self) { value in
                        Button { energy = value; proposal = nil } label: {
                            Text("\(value)").frame(maxWidth: .infinity)
                        }
                            .buttonStyle(.borderedProminent)
                            .tint(energy == value ? FitnessTheme.accent : FitnessTheme.faint)
                    }
                }
                Text("1 很疲惫 · 5 精力很好").font(.caption).foregroundStyle(.secondary)
                if energy != nil {
                    message("今天肌肉酸痛明显吗？")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 140), spacing: 6)], alignment: .leading) {
                        Button("不明显") { soreness = 1; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(soreness == 1 ? FitnessTheme.accent : FitnessTheme.faint)
                        Button("比较明显") { soreness = 4; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(soreness == 4 ? FitnessTheme.accent : FitnessTheme.faint)
                    }
                }
                if soreness != nil {
                    message("今天有没有疼痛或异常不适？")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 140), spacing: 6)], alignment: .leading) {
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
                    message("今天还有其他会影响训练的情况吗？比如刚做过治疗或有特别的活动限制。")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 280 : 140), spacing: 6)], alignment: .leading) {
                        Button("没有") { otherConcern = false; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(otherConcern == false ? FitnessTheme.accent : FitnessTheme.faint)
                            .disabled(!discussion.isEmpty || askingCoach)
                        Button("有，和教练说") { otherConcern = true; proposal = nil }.buttonStyle(.borderedProminent)
                            .tint(otherConcern == true ? FitnessTheme.accent : FitnessTheme.faint)
                    }
                }
                if otherConcern == false {
                    Button("让教练看看今天的安排", action: assess)
                        .buttonStyle(FitnessPrimaryButtonStyle())
                }
                if otherConcern == true {
                    ForEach(Array(discussion.enumerated()), id: \.offset) { _, line in
                        message((line.role == "user" ? "我：" : "教练：") + line.content)
                    }
                    TextField("告诉教练今天的情况", text: $concernText, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    Button(askingCoach ? "教练正在看…" : "发给教练") { Task { await discussConcern() } }
                        .disabled(askingCoach || concernText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(FitnessPrimaryButtonStyle())
                    if !discussion.isEmpty {
                        Text("如果你现在没有疼痛或异常不适，按已知医嘱可以轻松活动，且已说清所有已知限制，我会安排一个轻松的方案，再请你确认。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("现在没有不适，可以轻松活动，已说明限制", action: suggestGentleActivity)
                            .disabled(askingCoach || pain != false || !concernText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .buttonStyle(.bordered)
                    }
                }
                if let proposal {
                    message(proposal.summary)
                    if let items = proposal.todayItems {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("建议今天这样练").font(.headline)
                            ForEach(items) { item in
                                Text("\(item.exercise.name) · " + (item.targetSeconds.map { "\(Int($0 / 60)) 分钟" } ?? "\(item.setCount) 组"))
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
        CoachMessageText(text: text, size: messageSize, color: FitnessTheme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func assess() {
        do {
            guard let energy, let soreness, let pain, otherConcern == false,
                  store.canDiscussBeforeWorkout(plan) else {
                throw CoreError.invalidState("今天的安排已经变化，请返回后重新开始。")
            }
            let available = try UIInput.integer(minutes, label: "可用分钟数")
            try store.saveCheckIn(PreWorkoutCheckIn(energy: energy, sorenessLevel: soreness,
                                                    painReported: pain, availableMinutes: available))
            let assessment = try store.refreshReadiness()
            verdict = assessment.verdict
            proposal = try store.proposeAdjustment(readiness: assessment, selectedPlan: plan)
        } catch { issue = error.localizedDescription }
    }

    private func discussConcern() async {
        guard let energy, let soreness, let pain else { return }
        askingCoach = true
        defer { askingCoach = false }
        do {
            let statement = concernText.trimmingCharacters(in: .whitespacesAndNewlines)
            let earlier = discussion.filter { $0.role == "user" }.map(\.content)
            let allStatements = (earlier + [statement]).joined(separator: "\n")
            guard allStatements.count <= 2_000 else {
                throw CoreError.invalidInput("今天补充的情况太长，请保留与训练有关的重点。")
            }
            let available = try UIInput.integer(minutes, label: "可用分钟数")
            let checkIn = PreWorkoutCheckIn(energy: energy, sorenessLevel: soreness,
                painReported: pain, availableMinutes: available, note: allStatements)
            try store.saveCheckIn(checkIn)
            let earlierDialogue = discussion.map { "\($0.role == "user" ? "本人" : "教练")：\($0.content)" }.joined(separator: "\n")
            let answer = try await CoachConversationService().reply(
                to: "这是今天训练前的对话：\n\(earlierDialogue)\n本人：\(statement)\n请继续了解当天情况；不要声称修改已生效。", store: store)
            discussion.append(CoachMessage(role: "user", content: statement))
            discussion.append(CoachMessage(role: "assistant", content: answer))
            concernText = ""
        } catch { issue = error.localizedDescription }
    }

    private func suggestGentleActivity() {
        do {
            guard let energy, let soreness, pain == false, store.canDiscussBeforeWorkout(plan) else {
                throw CoreError.invalidState("今天的安排已经变化，请返回后重新开始。")
            }
            let statements = discussion.filter { $0.role == "user" }.map(\.content).joined(separator: "\n")
            let available = try UIInput.integer(minutes, label: "可用分钟数")
            try store.saveCheckIn(PreWorkoutCheckIn(energy: energy, sorenessLevel: soreness,
                painReported: false, availableMinutes: available, note: statements))
            proposal = try store.proposeGentleToday(lightActivityConfirmed: true, limitsCompleteConfirmed: true, selectedPlan: plan)
            verdict = .conservative
        } catch { issue = error.localizedDescription }
    }

    private func acceptAndStart() {
        do {
            guard let proposal, store.canDiscussBeforeWorkout(plan) else {
                throw CoreError.invalidState("今天的安排已经变化，请返回后重新开始。")
            }
            _ = try store.acceptAdjustment(id: proposal.id)
            let session = try store.startWorkout(plan: plan)
            openWorkout(session.id)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
