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
        List {
            Section {
                Text("这里是教练目前理解的你的情况。每项都标了来源：本人回答、本人确认、健康数据，或还是待确认的推断。未知的项不会被当成“没有”。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(InterviewTopic.allCases, id: \.self) { topic in
                row(topic)
            }
        }
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
                Text(provenance.title)
                    .font(.caption2)
                    .foregroundStyle(color(for: provenance))
            }
            Text(InterviewAPI.describe(topic, profile: profile))
                .font(.footnote).foregroundStyle(.secondary)
            if provenance == .inferred {
                HStack {
                    Button("确认") { confirm(topic, accept: true) }
                    Button("删掉") { confirm(topic, accept: false) }.foregroundStyle(.red)
                }.buttonStyle(.borderless)
            } else {
                HStack {
                    Button(provenance == .unknown ? "重新询问这项" : "修改／重新询问") { reopening = topic }
                    if provenance != .unknown {
                        Button("标记为未知") { clearing = topic }
                            .foregroundStyle(.secondary)
                    }
                }.font(.footnote).buttonStyle(.borderless)
            }
        }.padding(.vertical, 3)
    }

    private func color(for provenance: ProfileProvenance) -> Color {
        switch provenance {
        case .stated, .confirmed: return .secondary
        case .healthSource: return .blue
        case .inferred: return .orange
        case .unknown: return .secondary
        }
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
