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
    @State private var canStartSeparate = false
    @State private var confirmSeparate = false
    @State private var copied = false
    @State private var separateStoreNotice = UserDefaults.standard.bool(forKey: "fitness.separateStoreChosen")
    @State private var managingLegacy = false
    @State private var rootIdentity = UUID()
    @State private var erasureNotice = false
    @State private var pendingRestart = false

    init() {
        do {
            let cleaned = try LegacyStoreErasure.processPending(location: LegacyStoreErasure.defaultLocation())
            if cleaned {
                _erasureNotice = State(initialValue: true)
                _separateStoreNotice = State(initialValue: false)
                UserDefaults.standard.set(false, forKey: "fitness.separateStoreChosen")
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--capture-workout") {
                let isolated = try TrainingStore(inMemory: true)
                if let exercise = isolated.allExercises.first(where: { $0.id == "builtin.barbell-bench-press" }) {
                    let plan = try isolated.confirmPlan(name: "界面验证 · 不保存", items: [.init(exercise: exercise)])
                    _ = try isolated.startWorkout(plan: plan)
                }
                _store = State(initialValue: isolated)
            } else if ProcessInfo.processInfo.arguments.contains("--capture-history") {
                _store = State(initialValue: try HistoryValidationData.makeStore())
            } else { _store = State(initialValue: try TrainingStore()) }
            #else
            _store = State(initialValue: try TrainingStore())
            #endif
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
            let (report, separate) = Self.makeDiagnostic(error)
            _diagnosticText = State(initialValue: StartupDiagnostics.text(report))
            _diagnosticURL = State(initialValue: try? StartupDiagnostics.save(report))
            _canStartSeparate = State(initialValue: separate)
        }
    }

    var body: some Scene {
        WindowGroup {
          Group {
            if pendingRestart {
                ContentUnavailableView("重新打开 App 完成清理", systemImage: "arrow.clockwise",
                    description: Text("删除请求已确认，原库尚未物理删除。请从多任务界面关闭本 App，再重新打开。下次启动会先清理原库，再打开独立健身库。"))
            } else if let store {
                RootView(store: store).id(rootIdentity)
                    .safeAreaInset(edge: .top) {
                        if separateStoreNotice {
                            Text("正在使用独立新库，之前的计划与记录尚未恢复。原文件仍保留。")
                                .font(.footnote).padding(12).frame(maxWidth: .infinity).background(.yellow.opacity(0.16))
                        }
                        if erasureNotice {
                            HStack {
                                Label("原数据库已永久删除", systemImage: "checkmark.shield")
                                Spacer()
                                Button("知道了") { erasureNotice = false }
                            }.font(.footnote).padding(12).foregroundStyle(FitnessTheme.teal).background(FitnessTheme.surface)
                        }
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Label("本地数据暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.title2.bold())
                        Text("当前数据暂时无法打开。请记录错误，可在下方导出诊断或管理原数据库。")
                        Text(startupError ?? "未知错误").foregroundStyle(.secondary).textSelection(.enabled)
                        Text("诊断仅含版本、错误代码、模型标识和文件状态，不包含训练、档案、健康明细或 API 密钥。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.string = diagnosticText
                            copied = true
                        } label: {
                            Label(copied ? "已复制诊断信息" : "复制诊断信息", systemImage: "doc.on.doc").frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent)
                        if let diagnosticURL {
                            ShareLink(item: diagnosticURL) {
                                Label("导出诊断文件", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(.bordered)
                        }
                        DisclosureGroup("查看诊断内容") {
                            Text(diagnosticText).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if canStartSeparate {
                            Text("如需暂时继续使用，可明确选择建立独立健身库。此操作不会恢复之前的计划，原文件仍保留。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("保留原文件，使用独立新库") { confirmSeparate = true }
                                .frame(minHeight: 44)
                        }
                        Divider()
                        Button("彻底删除原数据库", role: .destructive) { managingLegacy = true }
                            .frame(maxWidth: .infinity, minHeight: 48)
                        Text("查看原库文件后再确认永久删除；当前独立健身库会保留。")
                            .font(.footnote).foregroundStyle(FitnessTheme.muted)
                    }.padding(24)
                }
                .alert("原计划尚未恢复", isPresented: $confirmSeparate) {
                    Button("取消", role: .cancel) { }
                    Button("确认使用独立新库") { startSeparate() }
                } message: {
                    Text("这会建立一个没有旧计划和训练记录的独立数据库，不是数据恢复。现有数据库文件全部保留。如需找回旧记录，请先发送诊断信息。")
                }
            }
          }
          .tint(FitnessTheme.accent)
          .environment(\.legacyErasureAction, LegacyErasureAction(perform: { review in try eraseLegacy(review) }))
          .sheet(isPresented: $managingLegacy) {
              NavigationStack { LegacyStoreManagementView(currentStoreURL: store?.storageURL) }
          }
        }
    }

    private func eraseLegacy(_ review: LegacyStoreErasure.Review) throws -> LegacyErasureResult {
        let previous = store
        let activeLegacy = previous?.storageURL?.resolvingSymlinksInPath().standardizedFileURL
            == review.location.legacyURL.resolvingSymlinksInPath().standardizedFileURL
        if activeLegacy {
            try LegacyStoreErasure.scheduleForNextLaunch(review)
            previous?.retireForErasure()
            store = nil
            rootIdentity = UUID()
            pendingRestart = true
            return .restartRequired
        }
        do {
            try LegacyStoreErasure.execute(review, confirmed: true,
                liveContainer: activeLegacy ? previous?.container : nil, liveURL: previous?.storageURL)
            UserDefaults.standard.set(false, forKey: "fitness.separateStoreChosen")
            UserDefaults.standard.set(Date(), forKey: "fitness.legacyStoreErasedAt")
            separateStoreNotice = false
            if previous == nil || activeLegacy { store = try TrainingStore(storageURL: review.location.dedicatedURL) }
            erasureNotice = true
            return .erased
        } catch {
            if activeLegacy || previous == nil {
                startupError = error.localizedDescription
                let (report, separate) = Self.makeDiagnostic(error)
                diagnosticText = StartupDiagnostics.text(report)
                diagnosticURL = try? StartupDiagnostics.save(report)
                canStartSeparate = separate
            }
            throw error
        }
    }

    private static func makeDiagnostic(_ error: any Error) -> (StartupDiagnostics.Report, Bool) {
        let scan = (error as? StorageSelectionRequired)?.scan ?? (try? StoreLocator.scanDefault())
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let fallback = ModelConfiguration(schema: schema, cloudKitDatabase: .none).url
        let failure = error as? StoreOpenFailure
        let url = failure?.url ?? scan?.diagnosticURL ?? fallback
        var report = StartupDiagnostics.capture(error: failure?.original ?? error,
            phase: error is StorageSelectionRequired ? "store-selection" : "app-startup", storeURL: url, includeReferences: true)
        report.storageCandidates = scan?.candidates.map(\.info)
        report.storageScanTruncated = scan?.truncated
        report.storageScanErrors = scan?.scanErrors
        return (report, error is StorageSelectionRequired && (scan?.canStartSeparate ?? false))
    }

    private func startSeparate() {
        do {
            let opened = try TrainingStore(explicitlyStartSeparate: true)
            UserDefaults.standard.set(true, forKey: "fitness.separateStoreChosen")
            separateStoreNotice = true
            store = opened
        } catch {
            startupError = error.localizedDescription
            let (report, separate) = Self.makeDiagnostic(error)
            diagnosticText = StartupDiagnostics.text(report)
            diagnosticURL = try? StartupDiagnostics.save(report)
            canStartSeparate = separate
            copied = false
        }
    }
}
