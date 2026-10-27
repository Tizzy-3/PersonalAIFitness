import SwiftUI
import FitnessCore

@MainActor
struct SettingsView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("我的资料") {
                NavigationLink { ProfileView(store: store) } label: { Label("个人档案与运动限制", systemImage: "person.crop.rectangle") }
                NavigationLink { HealthDiagnosticsView() } label: { Label("Apple 健康基础读取", systemImage: "heart") }
            }
            Section("AI 教练") {
                NavigationLink { PlannerView(store: store) } label: { Label("为我制定每周训练计划", systemImage: "calendar.badge.plus") }
                NavigationLink { AISettingsView() } label: { Label("接口、模型与密钥", systemImage: "slider.horizontal.3") }
                NavigationLink { CoachView(store: store) } label: { Label("问答、复盘与调整建议", systemImage: "bubble.left.and.text.bubble.right") }
            }
            Section("本地数据") {
                NavigationLink { BackupView(store: store) } label: { Label("加密备份与恢复", systemImage: "externaldrive") }
                NavigationLink { LegacyStoreManagementView(currentStoreURL: store.storageURL) } label: {
                    Label("彻底删除原数据库", systemImage: "externaldrive.badge.minus").foregroundStyle(.red)
                }
                LabeledContent("训练会话", value: "\(store.sessions.count)")
                LabeledContent("计划版本", value: "\(store.planVersions.count)")
            }
            Section("功能实现状态") {
                LabeledContent("手动计划与本地训练", value: "首个试用批次")
                LabeledContent("健康历史/增量/来源去重", value: "本批实现，真机待验")
                LabeledContent("身体状态评估", value: "本批实现，无综合分")
                LabeledContent("规则与 AI 制定计划", value: "档案组合 + 候选选择")
                LabeledContent("长期周期与自动进阶", value: "未实现")
                LabeledContent("计划删除与恢复", value: "保留训练和版本")
                LabeledContent("AI 教练与服务配置", value: "OpenAI 兼容接口")
                LabeledContent("AI 计划调整", value: "保持/仅本次/渐进建议")
                LabeledContent("建档访谈", value: "本批实现，需联网")
                LabeledContent("动作素材", value: "按动作详情显示覆盖范围")
                LabeledContent("历史更正与完整趋势", value: "未实现")
            }
            Section("关于这个试用版") {
                LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知")（\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")）")
                Text("仅供本人使用。数据本地保存，没有账户、广告、订阅或社交。仅在你预览并明确发送后请求所配置的 AI；不会后台发送 Apple 健康数据。")
                Text("未签名构建需要你自行签名安装。升级前保留可用备份，不通过卸载重装更新，避免清除本地沙盒。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent)
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
