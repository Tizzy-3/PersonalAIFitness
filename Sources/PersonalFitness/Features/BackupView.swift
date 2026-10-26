import SwiftUI
import UniformTypeIdentifiers
import FitnessCore

@MainActor
struct BackupView: View {
    let store: TrainingStore
    @State private var passwordAction: PasswordAction?
    @State private var pendingPassword: String?
    @State private var pendingOperation: PasswordAction?
    @State private var incomingData: Data?
    @State private var importSheet = false
    @State private var exportSheet = false
    @State private var document: BackupFile?
    @State private var restoreCandidate: AppSnapshot?
    @State private var confirmRestore = false
    @State private var working = false
    @State private var issue: String?
    @State private var status: String?

    var body: some View {
        Form {
            Section("加密备份") {
                Text("包含本地档案、计划各版本、训练、自定义动作、收藏和教练记录。没有 API 密钥、原始健康样本或视频缓存。口令丢失无法找回。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("创建加密备份", systemImage: "square.and.arrow.up") { passwordAction = .export }
                Button("从备份恢复", systemImage: "square.and.arrow.down") { importSheet = true }
                    .disabled(store.activeSession != nil)
                if store.activeSession != nil { Text("先结束正在进行的训练，才能恢复备份。").font(.footnote).foregroundStyle(.secondary) }
            }.disabled(working)
            Section("恢复方式") {
                Text("本批次采用替换式恢复，不自动合并两个时间线。恢复前解密并验证，再明确确认；当前本地数据会由备份内容替换，系统会保留恢复前的保护副本。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if working { Section { HStack { ProgressView(); Text("正在处理加密文件…").padding(.leading, 8) } } }
            if let status { Section { Text(status).font(.footnote).foregroundStyle(.secondary) } }
        }
        .navigationTitle("备份与恢复").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $passwordAction, onDismiss: performPendingOperation) { action in
            NavigationStack {
                BackupPasswordView(exporting: action == .export) { password in
                    pendingPassword = password
                    pendingOperation = action
                    passwordAction = nil
                }
            }
        }
        .fileExporter(isPresented: $exportSheet, document: document, contentType: .data,
                      defaultFilename: "PersonalFitness-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).pafbackup") { result in
            switch result {
            case .success: status = "加密备份已导出。请妥善保存文件与口令。"
            case .failure(let error): if !isCancellation(error) { issue = error.localizedDescription }
            }
            document = nil
        }
        .fileImporter(isPresented: $importSheet, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                let urls = try result.get()
                guard let url = urls.first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize > 0, fileSize <= 32 * 1_024 * 1_024 else { throw UIInput.Invalid(message: "备份文件为空或超过 32 MB 上限。") }
                incomingData = try Data(contentsOf: url)
                passwordAction = .decrypt
            } catch { if !isCancellation(error) { issue = error.localizedDescription } }
        }
        .confirmationDialog("确认替换当前本地数据？", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("确认恢复此备份", role: .destructive) { restore() }
            Button("取消", role: .cancel) { restoreCandidate = nil }
        } message: {
            if let restoreCandidate {
                Text("备份包含 \(restoreCandidate.sessions.count) 次训练、\(restoreCandidate.planVersions.count) 个计划版本、\(restoreCandidate.customExercises.count) 个自定义动作、\(restoreCandidate.coachTurns?.count ?? 0) 条教练记录、\(restoreCandidate.favoriteExerciseIDs?.count ?? 0) 个收藏。替换前会保留保护副本；AI 密钥不包含在备份内。")
            }
        }
        .fitnessError($issue)
    }

    private func performPendingOperation() {
        guard let password = pendingPassword, let operation = pendingOperation else {
            incomingData = nil
            return
        }
        pendingPassword = nil
        pendingOperation = nil
        working = true
        Task {
            defer { working = false }
            do {
                switch operation {
                case .export:
                    let snapshot = try store.snapshot()
                    let data = try await Task.detached(priority: .userInitiated) { try BackupCryptor.encrypt(snapshot, passphrase: password) }.value
                    document = BackupFile(data: data)
                    exportSheet = true
                case .decrypt:
                    guard let data = incomingData else { throw UIInput.Invalid(message: "没有可解密的文件，请重新选择备份。") }
                    incomingData = nil
                    let snapshot = try await Task.detached(priority: .userInitiated) { try BackupCryptor.decrypt(data, passphrase: password) }.value
                    restoreCandidate = snapshot
                    confirmRestore = true
                }
            } catch { issue = error.localizedDescription }
        }
    }

    private func restore() {
        guard let candidate = restoreCandidate else { return }
        do {
            try store.restore(candidate)
            restoreCandidate = nil
            status = "备份已恢复。本地数据已重新载入；请核对训练与计划。Apple 健康需要重新读取。"
        } catch { issue = error.localizedDescription }
    }

    private func isCancellation(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError
    }
}

private enum PasswordAction: String, Identifiable {
    case export, decrypt
    var id: String { rawValue }
}

private struct BackupPasswordView: View {
    let exporting: Bool
    let proceed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    var body: some View {
        Form {
            Section(exporting ? "设置备份口令" : "输入备份口令") {
                SecureField("至少 8 个字符", text: $password).textContentType(.password)
                if exporting { SecureField("再次输入口令", text: $confirmation).textContentType(.password) }
                Text("口令仅用于本次加解密，不写入普通设置或备份文件。请在你控制的位置妥善保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(exporting ? "创建加密备份" : "解密备份").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(exporting ? "加密" : "解密") { proceed(password) }
                    .disabled(password.count < 8 || (exporting && password != confirmation))
            }
        }
    }
}
