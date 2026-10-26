import SwiftUI

@MainActor
struct AISettingsView: View {
    @State private var endpoint = ""
    @State private var model = ""
    @State private var keyInput = ""
    @State private var hasSavedKey = false
    @State private var status: String?
    @State private var issue: String?
    @State private var testing: Task<Void, Never>?
    @State private var removing = false

    private var configuration: AIConfiguration { AIConfiguration(endpoint: endpoint, model: model).normalized }

    var body: some View {
        Form {
            Section("OpenAI 兼容服务") {
                TextField("完整 HTTPS 接口地址", text: $endpoint, axis: .vertical)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityHint("需要以 /chat/completions 结尾")
                    .disabled(testing != nil)
                Text("例如 https://你的服务/v1/chat/completions。请填写最终接口地址，本版本不自动跟随跳转。")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("模型名称，例如服务后台给出的 model ID", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(testing != nil)
            }
            Section("此服务器的 API Key") {
                SecureField(hasSavedKey ? "已有密钥；留空则保留" : "在本机填写 API Key", text: $keyInput)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(testing != nil)
                Label(hasSavedKey ? "本机已保存此服务器的密钥" : "此服务器尚未保存密钥",
                      systemImage: hasSavedKey ? "key.fill" : "key")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("密钥只保存在本机 Keychain，按服务器与端口分别保存，不进入训练数据库、备份或日志。更换服务器后需要为新地址填写密钥。")
                    .font(.footnote).foregroundStyle(.secondary)
                if hasSavedKey {
                    Button("移除此服务器的本机密钥", role: .destructive) { removing = true }
                        .disabled(testing != nil)
                }
            }
            Section {
                Button("保存接口与密钥") { save() }.disabled(testing != nil)
                if testing == nil {
                    Button("测试连接 · 不发送个人资料") { test() }
                } else {
                    HStack { ProgressView(); Text("正在请求服务…"); Spacer(); Button("取消") { testing?.cancel() } }
                }
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("发送由你决定") {
                Text("配置和测试不会上传训练档案。每次向教练提问时，先预览实际发送的数据，再明确发送。服务可能按自身规则留存请求，请使用你信任的接口。")
                Text("支持非流式 Chat Completions 文本 JSON。模型必须能按约定返回结构化回答；接口连通并不代表其训练建议正确。Responses API 或其他格式需要单独适配。")
                Text("本 App 不提供模型额度，也不会把证书、私钥或 API Key 上传到 GitHub。")
            }.font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("AI 接口").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
        .onChange(of: endpoint) { _, _ in refreshKeyStatus(); status = nil }
        .onChange(of: model) { _, _ in refreshKeyStatus(); status = nil }
        .onDisappear { testing?.cancel() }
        .confirmationDialog("移除此服务器保存在本机的 API Key？", isPresented: $removing, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) {
                do { try AIKeychain.remove(for: configuration); keyInput = ""; refreshKeyStatus(); status = "已移除本机密钥。" }
                catch { issue = error.localizedDescription }
            }
            Button("取消", role: .cancel) { }
        }
        .fitnessError($issue)
    }

    private func load() {
        do {
            if let value = try AIConfigurationStorage.load() { endpoint = value.endpoint; model = value.model }
            refreshKeyStatus()
        } catch { issue = error.localizedDescription }
    }

    private func refreshKeyStatus() { hasSavedKey = (try? AIKeychain.load(for: configuration)) != nil }

    private func connection() throws -> (AIConfiguration, String) {
        let configuration = configuration
        _ = try configuration.validatedURL()
        let entered = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return (configuration, entered) }
        guard let saved = try AIKeychain.load(for: configuration) else {
            throw CoachClientError.configuration("请为当前服务器填写 API Key。旧服务器的密钥不会用于新地址。")
        }
        return (configuration, saved)
    }

    private func save() {
        do {
            let (configuration, key) = try connection()
            try AIKeychain.save(key, for: configuration)
            try AIConfigurationStorage.save(configuration)
            keyInput = ""
            refreshKeyStatus()
            status = "接口已保存；尚未请求模型。可先测试连接，再回到 AI 教练提问。"
        } catch { issue = error.localizedDescription }
    }

    private func test() {
        do {
            let (configuration, key) = try connection()
            status = nil
            testing = Task {
                defer { testing = nil }
                do {
                    try await CoachAPI().testConnection(configuration: configuration, key: key)
                    try Task.checkCancellation()
                    status = "此接口和模型已返回有效文本。测试未发送个人资料；训练分析和结构化建议仍需实际提问验证。配置仅在点击保存后持久化。"
                } catch is CancellationError { status = "已取消测试，没有自动重试。" }
                catch { issue = error.localizedDescription }
            }
        } catch { issue = error.localizedDescription }
    }
}
