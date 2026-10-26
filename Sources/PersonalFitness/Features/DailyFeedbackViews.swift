import SwiftUI
import FitnessCore

/// Today's check-in. Deliberately all-optional: skipping is recorded as skipped, not as "fine".
@MainActor
struct CheckInView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss
    @State private var energy: Int?
    @State private var sorenessLevel: Int?
    @State private var painReported: Bool?
    @State private var painAreas = ""
    @State private var availableMinutes: String = ""
    @State private var note = ""
    @State private var issue: String?

    var body: some View {
        Form {
            Section {
                Text("这些只用于今天的建议，不会自动改动你已确认的计划。不回答的项会显示为“未回答”，不会当成“没问题”。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("精力") {
                Picker("现在感觉", selection: $energy) {
                    Text("未回答").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }.pickerStyle(.segmented)
                Text("1 = 很疲惫，5 = 精神很好").font(.caption).foregroundStyle(.secondary)
            }
            Section("酸痛") {
                Picker("酸痛程度", selection: $sorenessLevel) {
                    Text("未回答").tag(Int?.none)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }.pickerStyle(.segmented)
            }
            Section("疼痛") {
                Picker("有没有疼痛或异常不适", selection: $painReported) {
                    Text("未回答").tag(Bool?.none)
                    Text("没有").tag(Bool?.some(false))
                    Text("有").tag(Bool?.some(true))
                }.pickerStyle(.segmented)
                if painReported == true {
                    TextField("在哪些部位（可留空）", text: $painAreas)
                    Text("有疼痛时，本地规则不会自动改计划，也会建议停止相关动作。")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("今天有多少时间") {
                TextField("分钟（可留空）", text: $availableMinutes).keyboardType(.numberPad)
            }
            Section("备注") {
                TextField("想补充的情况（可留空）", text: $note, axis: .vertical).lineLimit(1...4)
            }
            Section {
                Button("保存今天的记录", action: save).buttonStyle(FitnessPrimaryButtonStyle())
            }
        }
        .navigationTitle("训练前记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .fitnessError($issue)
    }

    private func load() {
        guard let existing = store.todaysCheckIn() else { return }
        energy = existing.energy
        sorenessLevel = existing.sorenessLevel
        painReported = existing.painReported
        painAreas = existing.painAreas.joined(separator: "、")
        availableMinutes = existing.availableMinutes.map(String.init) ?? ""
        note = existing.note
    }

    private func save() {
        do {
            let areas = painAreas.split(whereSeparator: { $0 == "、" || $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let minutes = try UIInput.integer(availableMinutes, label: "可用分钟数")
            let checkIn = PreWorkoutCheckIn(createdAt: Date(), energy: energy,
                                            sorenessLevel: sorenessLevel,
                                            painReported: painReported,
                                            painAreas: painReported == true ? areas : [],
                                            availableMinutes: minutes, note: note)
            try store.saveCheckIn(checkIn)
            dismiss()
        } catch {
            issue = error.localizedDescription
        }
    }
}

/// The readiness screen. Six separate parts, and no combined score anywhere.
@MainActor
struct ReadinessView: View {
    let store: TrainingStore
    @State private var assessment: ReadinessAssessment?
    @State private var issue: String?
    @State private var status: String?

    var body: some View {
        List {
            if let assessment {
                Section("1 · 安全") {
                    Text(assessment.safety).font(.subheadline)
                }
                Section("2 · 恢复证据") {
                    if assessment.recoveryEvidence.isEmpty {
                        Text("没有可用的恢复证据。").foregroundStyle(.secondary)
                    }
                    ForEach(Array(assessment.recoveryEvidence.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.footnote)
                    }
                }
                Section("3 · 表现趋势") {
                    Text(assessment.performanceTrend).font(.footnote)
                }
                Section("4 · 可信度") {
                    LabeledContent("信息完整度", value: "\(assessment.confidenceLevel)/5")
                    Text(assessment.confidence).font(.footnote)
                }
                Section("5 · 今天的建议") {
                    Text(assessment.verdict.title).font(.headline)
                    Text(assessment.todaySuggestion).font(.subheadline)
                }
                Section("6 · 依据") {
                    if assessment.evidence.isEmpty {
                        Text("这次没有可引用的真实数据。").foregroundStyle(.secondary)
                    }
                    ForEach(assessment.evidence) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.footnote.weight(.semibold))
                            if let value = item.value { Text(value).font(.caption).foregroundStyle(.secondary) }
                            if let observed = item.observedAt {
                                Text(observed, style: .date).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    ForEach(Array(assessment.limitations.enumerated()), id: \.offset) { _, line in
                        Text("· " + line).font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("这里不合成“恢复分”，也不做医学诊断。缺失的数据就是缺失，不会被当成状态良好。")
                }
                Section {
                    Button("提出今天可以做的调整", action: proposeAdjustment)
                    NavigationLink("看这份状态对应的训练前记录") { CheckInView(store: store) }
                }
            } else {
                Section {
                    Button("现在评估今天的状态", action: refresh).buttonStyle(FitnessPrimaryButtonStyle())
                } footer: {
                    Text("评估只用你本机保存的记录和已读取的健康数据。")
                }
            }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("今天的状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { if assessment == nil { refresh() } }
        .fitnessError($issue)
    }

    private func refresh() {
        do {
            assessment = try store.refreshReadiness()
            status = nil
        } catch {
            issue = error.localizedDescription
        }
    }

    private func proposeAdjustment() {
        guard let assessment else { return }
        do {
            let proposal = try store.proposeAdjustment(readiness: assessment)
            status = "已生成建议：\(proposal.kind.title)。去“调整建议”里看差异后决定。"
        } catch {
            issue = error.localizedDescription
        }
    }
}
