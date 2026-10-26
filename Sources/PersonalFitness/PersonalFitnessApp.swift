import SwiftUI

@main
@MainActor
struct PersonalFitnessApp: App {
    @State private var store: TrainingStore?
    @State private var startupError: String?

    init() {
        do {
            _store = State(initialValue: try TrainingStore())
        } catch {
            _startupError = State(initialValue: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            if let store {
                RootView(store: store)
            } else {
                ContentUnavailableView {
                    Label("本地数据暂时无法打开", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("没有清空或重建你的数据库。请保留 App，记录错误后再处理恢复。\n\n\(startupError ?? "未知错误")")
                        .textSelection(.enabled)
                }
            }
        }
    }
}
