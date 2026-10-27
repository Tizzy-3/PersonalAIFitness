import SwiftUI
import SwiftData
import UIKit

@main
@MainActor
struct PersonalFitnessApp: App {
    @State private var store: TrainingStore?
    @State private var startupError: String?
    @State private var diagnosticText = ""
    @State private var diagnosticURL: URL?

    init() {
        do {
            _store = State(initialValue: try TrainingStore())
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
            let schema = Schema(versionedSchema: FitnessSchemaV4.self)
            let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            let report = StartupDiagnostics.capture(error: error, phase: "app-startup",
                                                     storeURL: configuration.url, includeReferences: true)
            _diagnosticText = State(initialValue: StartupDiagnostics.text(report))
            _diagnosticURL = State(initialValue: try? StartupDiagnostics.save(report))
        }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView(store: store)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("本地数据暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title2.bold())
                        Text("没有清空或重建你的数据库。请保留 App，将诊断信息交给开发者后再处理恢复。")
                        Text(startupError ?? "未知错误").foregroundStyle(.secondary).textSelection(.enabled)
                        Text("诊断仅含版本、错误代码、模型标识和文件状态，不包含训练、档案、健康明细或 API 密钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = diagnosticText
                        } label: {
                            Label("复制诊断信息", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                        if let diagnosticURL {
                            ShareLink(item: diagnosticURL) {
                                Label("导出诊断文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered)
                        }
                        DisclosureGroup("查看诊断内容") {
                            Text(diagnosticText).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }.padding(24)
                }
            }
        }
    }
}
