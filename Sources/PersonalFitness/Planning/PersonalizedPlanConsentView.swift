import SwiftUI
import FitnessCore

struct PreparedPersonalizedPlan: Identifiable {
    let id = UUID()
    let configuration: AIConfiguration
    let session: InterviewSession
    let context: PersonalizedPlanRequest
    let preview: String
}

struct PersonalizedPlanConsentView: View {
    let prepared: PreparedPersonalizedPlan
    let send: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("发送到你配置的服务") {
                LabeledContent("接口", value: prepared.configuration.destination)
                LabeledContent("模型", value: prepared.configuration.model)
                Text("本次会发送你已确认的目标、能力、器械、偏好等档案，以及本地训练数量和允许的动作池。下方是实际发送的内容。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("不包含健康原始样本、未确认推断、旧访谈全文或API密钥。你配置的服务可能留存发送内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("实际发送内容") {
                Text(prepared.preview).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section {
                Button("同意发送，让教练制定计划") { send() }
                    .frame(minHeight: 44)
                Text("模型会在真实动作池内作选择并解释。本地规则负责组次、休息和排程校验；完整方案仍需你确认后才生效。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("制定计划 · 发送前确认")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}
