import SwiftUI
import FitnessCore

/// The profile review screen: every field shows its value, where it came from, and can be edited.
/// Unconfirmed inferences are highlighted as such and never look like settled facts.
@MainActor
struct CoachProfileReviewView: View {
    let store: TrainingStore
    @State private var issue: String?
    @State private var status: String?
    @State private var reopening: InterviewTopic?
    @State private var clearing: InterviewTopic?
    @State private var showingInterview = false

    private var profile: StructuredProfile { store.interview?.profile ?? StructuredProfile() }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                CoachPanel {
                    HStack(spacing: 12) {
                        CoachIconBadge(symbol: "person.crop.rectangle", color: FitnessTheme.violet)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("教练眼中的你").font(.headline)
                            Text("已确认 \(profile.answeredTopics.count) 项资料")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("资料来源与未知项") {
                        Text("每项资料会标明本人回答、本人确认、健康数据或待确认推断。未知不等于没有；你可以逐项核对、修改或重新询问。")
                            .font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                    }.font(.footnote)
                    if let status { Label(status, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(FitnessTheme.teal) }
                }
                if let session = store.interview {
                    CoachPanel {
                        if session.needsSafetyReview { Label("新补充的情况需要重新核对运动限制", systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(FitnessTheme.orange) }
                        DisclosureGroup("本人叙述与深入问答") {
                            ForEach(session.narratives ?? []) { entry in Text(entry.text).font(.footnote).textSelection(.enabled).padding(.vertical, 6) }
                            ForEach(Array(session.dialogueEvidence.enumerated()), id: \.offset) { _, item in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.prompt).font(.subheadline.weight(.medium))
                                    Text(InterviewAPI.describe(item.answer)).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                                }.padding(.vertical, 7)
                            }
                        }.font(.subheadline)
                    }
                }
                ForEach(InterviewTopic.allCases, id: \.self) { topic in
                    CoachPanel { row(topic) }
                }
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
        .background(FitnessTheme.canvas)
        .tint(FitnessTheme.accent)
        .navigationTitle("我的训练档案")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showingInterview) { CoachInterviewView(store: store) }
        .confirmationDialog("重新询问这项资料？", isPresented: Binding(
            get: { reopening != nil }, set: { if !$0 { reopening = nil } }
        ), titleVisibility: .visible) {
            if let topic = reopening {
                Button("重新询问\(topic.title)") { reopen(topic) }
            }
            Button("取消", role: .cancel) { reopening = nil }
        } message: {
            Text("这项资料会重新变为未知，再由你回答 AI 教练的问题。其余档案和已生效训练计划保留；新计划仍须另行确认。")
        }
        .confirmationDialog("将这项资料标记为未知？", isPresented: Binding(
            get: { clearing != nil }, set: { if !$0 { clearing = nil } }
        ), titleVisibility: .visible) {
            if let topic = clearing {
                Button("标记\(topic.title)为未知", role: .destructive) { markUnknown(topic) }
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: {
            Text("原值将从当前档案清除，教练暂时不再追问。需要补充时，可点击“重新询问这项”。这不会修改已生效计划。")
        }
        .fitnessError($issue)
    }

    @ViewBuilder private func row(_ topic: InterviewTopic) -> some View {
        let provenance = profile.provenance(of: topic)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(topic.title).font(.subheadline.weight(.semibold))
                Spacer()
                CoachStatusPill(text: provenance.title, color: color(for: provenance))
            }
            Text(InterviewAPI.describe(topic, profile: profile))
                .font(.footnote).foregroundStyle(.secondary)
            if topic == .restrictions {
                Text("用自然语言描述也可以。制定成人计划前，请本人明确确认当前状态；这不会由AI从句子猜成没有限制。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("本人确认：目前无已知运动限制且无疼痛或异常不适") { confirmNoRestrictions() }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("有或不确定，重新说明") { reopening = topic }.frame(minHeight: 44)
            }
            if provenance == .inferred {
                HStack {
                    Button("确认") { confirm(topic, accept: true) }
                    Button("删掉") { confirm(topic, accept: false) }.foregroundStyle(.red)
                }.buttonStyle(.bordered).controlSize(.large)
            } else {
                HStack {
                    Button(provenance == .unknown ? "重新询问这项" : "修改／重新询问") { reopening = topic }
                    if provenance != .unknown {
                        Button("标记为未知") { clearing = topic }
                            .foregroundStyle(.secondary)
                    }
                }.font(.footnote).buttonStyle(.bordered).controlSize(.large)
            }
        }.padding(.vertical, 3)
    }

    private func color(for provenance: ProfileProvenance) -> Color {
        switch provenance {
        case .stated, .confirmed: return FitnessTheme.teal
        case .healthSource: return FitnessTheme.accent
        case .inferred: return FitnessTheme.orange
        case .unknown: return .secondary
        }
    }

    private func confirmNoRestrictions() {
        guard var session = store.interview else { return }
        do {
            try session.setValue(.text("无"), for: .restrictions)
            try store.saveInterview(session)
            status = "已记录本人对当前运动限制和不适的明确确认。"
        } catch { issue = error.localizedDescription }
    }

    private func confirm(_ topic: InterviewTopic, accept: Bool) {
        guard var session = store.interview else { issue = "还没有进行中的访谈。"; return }
        do {
            try session.confirmInference(topic, accept: accept)
            try store.saveInterview(session)
            status = accept ? "已确认\(topic.title)。" : "已删除这条推断。"
        } catch {
            issue = error.localizedDescription
        }
    }

    private func markUnknown(_ topic: InterviewTopic) {
        guard var session = store.interview else { issue = "还没有进行中的访谈。"; return }
        do {
            try session.markUnknown(topic)
            try store.saveInterview(session)
            clearing = nil
            status = "\(topic.title)已标记为未知。需要补充时，可点击“重新询问这项”。"
        } catch {
            issue = error.localizedDescription
        }
    }

    private func reopen(_ topic: InterviewTopic) {
        guard var session = store.interview else { issue = "还没有进行中的访谈。"; return }
        do {
            try session.reopenTopic(topic)
            try store.saveInterview(session)
            reopening = nil
            showingInterview = true
        } catch {
            issue = error.localizedDescription
        }
    }
}
