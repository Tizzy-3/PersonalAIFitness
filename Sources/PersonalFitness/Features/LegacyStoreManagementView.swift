import SwiftUI

struct LegacyErasureAction: Sendable {
    var perform: (@MainActor @Sendable (LegacyStoreErasure.Review) throws -> Void)?
}
private struct LegacyErasureActionKey: EnvironmentKey {
    static let defaultValue = LegacyErasureAction()
}
extension EnvironmentValues {
    var legacyErasureAction: LegacyErasureAction {
        get { self[LegacyErasureActionKey.self] }
        set { self[LegacyErasureActionKey.self] = newValue }
    }
}

@MainActor
struct LegacyStoreManagementView: View {
    var currentStoreURL: URL?
    @Environment(\.legacyErasureAction) private var erasure
    @Environment(\.dismiss) private var dismiss
    @State private var review: LegacyStoreErasure.Review?
    @State private var loadingIssue: String?
    @State private var issue: String?
    @State private var phrase = ""
    @State private var understood = false
    @State private var confirming = false
    @State private var completed = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    FitnessIconBadge(symbol: completed ? "checkmark.shield" : "externaldrive.badge.minus", color: completed ? FitnessTheme.teal : .red)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(completed ? "原库已彻底删除" : "永久删除原数据库").font(.headline)
                        Text(completed ? "已核验原库文件不存在。" : "删除文件本身，不是从列表隐藏。").font(.caption).foregroundStyle(FitnessTheme.muted)
                    }
                }.padding(.vertical, 6)
            }
            if !completed, let review {
                Section("本次清理范围") {
                    LabeledContent("原库", value: review.location.legacyURL.lastPathComponent)
                    LabeledContent("文件数量", value: "\(review.files.count)")
                    LabeledContent("占用", value: ByteCountFormatter.string(fromByteCount: review.totalBytes, countStyle: .file))
                    if !review.entities.isEmpty {
                        Text(review.entities.joined(separator: "、")).font(.caption).foregroundStyle(FitnessTheme.muted)
                    }
                    ForEach(review.files) { file in
                        Label(file.isRecoveryCopy ? "原库自动恢复副本" : file.url.lastPathComponent,
                              systemImage: file.isRecoveryCopy ? "doc.badge.clock" : "doc")
                            .font(.subheadline)
                    }
                    Text("原库中的计划、训练与其他记录将永久删除。本次不保留自动副本，无法撤销。")
                        .font(.footnote).foregroundStyle(.red)
                }
                Section("当前独立健身库会保留") {
                    Text("PersonalFitness/Training.store、手动导出的备份、AI 接口密钥与 Apple 健康数据不在删除范围内。")
                        .font(.footnote).foregroundStyle(FitnessTheme.muted)
                    if currentStoreURL?.resolvingSymlinksInPath() == review.location.legacyURL.resolvingSymlinksInPath() {
                        Label("当前正在使用原库，确认后会停止该数据容器并重新开始。", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(FitnessTheme.orange)
                    }
                }
                Section {
                    Toggle("我理解原库记录将永久删除", isOn: $understood)
                    TextField("输入：删除原库", text: $phrase).autocorrectionDisabled()
                    Button("彻底删除原库", role: .destructive) { confirming = true }
                        .frame(minHeight: 44).disabled(!understood || phrase != "删除原库")
                }
            } else if !completed {
                Section {
                    Text(loadingIssue ?? "正在检查原库文件…").font(.subheadline).foregroundStyle(FitnessTheme.muted)
                    Button("重新检查", action: refresh)
                }
            }
        }
        .scrollContentBackground(.hidden).background(FitnessTheme.canvas).tint(FitnessTheme.accent)
        .navigationTitle("原库清理").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .onAppear(perform: refresh)
        .confirmationDialog("永久删除列出的原库文件？", isPresented: $confirming, titleVisibility: .visible) {
            Button("确认彻底删除", role: .destructive) { erase() }
            Button("取消", role: .cancel) { }
        } message: { Text("这是不可撤回的物理删除。当前独立健身库会保留。") }
        .fitnessError($issue)
    }

    private func refresh() {
        do {
            review = try LegacyStoreErasure.prepare(location: LegacyStoreErasure.defaultLocation())
            loadingIssue = nil
        } catch { review = nil; loadingIssue = error.localizedDescription }
        phrase = ""; understood = false
    }
    private func erase() {
        guard let review, understood, phrase == "删除原库", let perform = erasure.perform else {
            issue = "删除条件尚未确认，未清理文件。"; return
        }
        do { try perform(review); completed = true; self.review = nil }
        catch { issue = error.localizedDescription; refresh() }
    }
}
