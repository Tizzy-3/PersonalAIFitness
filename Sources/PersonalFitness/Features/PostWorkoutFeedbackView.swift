import SwiftUI
import FitnessCore

/// Post-workout feedback. The objective half is filled in by the app from the saved session; only the
/// subjective half is the user's.
@MainActor
struct PostWorkoutFeedbackView: View {
    let store: TrainingStore
    let sessionID: UUID
    let onFinish: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var exertion: Int?
    @State private var tooHard: Bool?
    @State private var painReported: Bool?
    @State private var painAreas = ""
    @State private var barrier = ""
    @State private var issue: String?

    private var session: WorkoutSession? { store.session(id: sessionID) }

    var body: some View {
        Form {
            if let session {
                Section("这次训练（程序统计）") {
                    LabeledContent("完成正式组", value: "\(session.completedWorkingSets)")
                    LabeledContent("总时长", value: UIInput.duration(session.elapsed()))
                    Text("这两个数字由程序从已保存的记录算出，不能手动修改。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("主观用力") {
                Picker("整体感觉多累", selection: $exertion) {
                    Text("不回答").tag(Int?.none)
                    ForEach(1...10, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }.pickerStyle(.menu)
                Picker("比预期更难吗", selection: $tooHard) {
                    Text("不回答").tag(Bool?.none)
                    Text("比预期轻松").tag(Bool?.some(false))
                    Text("比预期更难").tag(Bool?.some(true))
                }.pickerStyle(.segmented)
            }
            Section("疼痛") {
                Picker("训练中有没有疼痛", selection: $painReported) {
                    Text("不回答").tag(Bool?.none)
                    Text("没有").tag(Bool?.some(false))
                    Text("有").tag(Bool?.some(true))
                }.pickerStyle(.segmented)
                if painReported == true { TextField("部位（可留空）", text: $painAreas) }
            }
            Section("其他") {
                TextField("今天的困难或坚持障碍（可留空）", text: $barrier, axis: .vertical).lineLimit(1...4)
            }
            Section {
                Button("保存并关闭", action: save).buttonStyle(FitnessPrimaryButtonStyle())
                Button("跳过", action: skip).foregroundStyle(.secondary)
            } footer: {
                Text("跳过就记为“没有反馈”，不会被当成“状态良好”。")
            }
        }
        .navigationTitle("训练后反馈")
        .navigationBarTitleDisplayMode(.inline)
        .fitnessError($issue)
    }

    private func save() {
        do {
            let areas = painAreas.split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let feedback = SessionFeedback(sessionID: sessionID, createdAt: Date(),
                                           perceivedExertion: exertion, tooHard: tooHard,
                                           painReported: painReported,
                                           painAreas: painReported == true ? areas : [],
                                           barrierNote: barrier)
            try store.saveSessionFeedback(feedback)
            finish()
        } catch {
            issue = error.localizedDescription
        }
    }

    private func skip() { finish() }

    private func finish() {
        dismiss()
        onFinish()
    }
}
