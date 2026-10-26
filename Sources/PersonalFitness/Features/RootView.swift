import SwiftUI
import FitnessCore

struct WorkoutRoute: Identifiable { let id: UUID }
struct PlanEditorRoute: Identifiable {
    let id = UUID()
    let plan: PlanVersion?
}

@MainActor
struct RootView: View {
    let store: TrainingStore
    @State private var selectedTab = 0
    @State private var workout: WorkoutRoute?
    @State private var planEditor: PlanEditorRoute?
    @State private var settings = false

    init(store: TrainingStore) {
        self.store = store
        #if DEBUG
        // CI captures actual empty-state screens, without adding fabricated user data.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--capture-tab"), arguments.indices.contains(index + 1),
           let tab = Int(arguments[index + 1]), (0...4).contains(tab) {
            _selectedTab = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(store: store, openWorkout: { workout = WorkoutRoute(id: $0) },
                          editPlan: { planEditor = PlanEditorRoute(plan: $0) },
                          openSettings: { settings = true })
            }
            .tabItem { Label("今天", systemImage: "house") }.tag(0)
            NavigationStack {
                PlansAndHistoryView(store: store, openWorkout: { workout = WorkoutRoute(id: $0) },
                                    editPlan: { planEditor = PlanEditorRoute(plan: $0) })
            }
            .tabItem { Label("训练", systemImage: "dumbbell") }.tag(1)
            NavigationStack { ExerciseLibraryView(store: store) }
                .tabItem { Label("动作库", systemImage: "books.vertical") }.tag(2)
            NavigationStack { TrainingInsightsView(store: store) }
                .tabItem { Label("趋势", systemImage: "chart.bar") }.tag(3)
            NavigationStack { CoachView(store: store) }
                .tabItem { Label("教练", systemImage: "bubble.left.and.text.bubble.right") }.tag(4)
        }
        .tint(.primary)
        .sheet(item: $planEditor) { route in NavigationStack { PlanEditorView(store: store, revising: route.plan) } }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView(store: store) } }
        .fullScreenCover(item: $workout) { route in
            NavigationStack { WorkoutView(store: store, sessionID: route.id) }
        }
    }
}

@MainActor
struct TodayView: View {
    let store: TrainingStore
    let openWorkout: (UUID) -> Void
    let editPlan: (PlanVersion?) -> Void
    let openSettings: () -> Void
    @State private var issue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                weekStrip
                if let ongoing = store.activeSession {
                    Button { openWorkout(ongoing.id) } label: {
                        Label("恢复\(ongoing.status == .paused ? "已暂停" : "未结束")的训练", systemImage: "arrow.clockwise")
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding()
                            .background(FitnessTheme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                if let plan = store.currentPlan {
                    planCover(plan)
                    HStack {
                        Text("这次要练的动作").font(.headline)
                        Spacer()
                        Button("编辑计划") { editPlan(plan) }.font(.subheadline)
                    }
                    VStack(spacing: 0) {
                        ForEach(plan.items) { item in
                            NavigationLink { ExerciseDetailView(exercise: item.exercise, store: store) } label: {
                                HStack(spacing: 12) {
                                    ExerciseTile(exercise: item.exercise,
                                                 animated: item.id == plan.items.first(where: { ExerciseDetails.details(for: $0.exercise.id)?.media?.previewGIFFileName != nil })?.id)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.exercise.name).font(.subheadline.weight(.semibold))
                                        Text(item.exercise.muscle).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(item.exercise.metric == .repetitions
                                         ? "\(item.setCount) × \(item.targetReps.map(String.init) ?? "—")"
                                         : "\(item.setCount) 组 · \(item.targetSeconds.map { UIInput.number($0) + " 秒" } ?? "按实际记录")")
                                        .font(.caption.monospacedDigit())
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if item.id != plan.items.last?.id { Divider().padding(.leading, 72) }
                        }
                    }.background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    ContentUnavailableView("从你的计划开始", systemImage: "calendar.badge.plus", description: Text("手动选择动作、组数与目标，确认后开始训练。这里没有预置的个人训练成绩。"))
                    Button("创建手动计划") { editPlan(nil) }.buttonStyle(FitnessPrimaryButtonStyle())
                }
                NavigationLink { ProfileView(store: store) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("个人档案与运动限制").font(.subheadline.weight(.semibold))
                            Text("未填写的资料明确保留为未知").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "person.crop.rectangle") }
                }
                NavigationLink { HealthDiagnosticsView() } label: {
                    Label("Apple 健康 · 基础读取验证", systemImage: "heart").font(.subheadline)
                }
                if let last = store.sessions.first(where: { !$0.status.isOngoing }) {
                    NavigationLink { SessionDetailView(session: last) } label: {
                        HStack {
                            Label("上次训练", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Text(last.startedAt, style: .date).foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                }
                NavigationLink { CoachView(store: store) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI 教练", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
                        Text("解释当前计划、复盘已保存记录。发送前核对资料，调整先看对比再确认。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain)
                Text("身体状态评估与规则自动计划尚未实现；AI 回答不是恢复评估或医学诊断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(20)
        }
        .background(FitnessTheme.canvas)
        .navigationTitle("今天")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Text(Date.now, format: .dateTime.month().day().weekday()).font(.caption).foregroundStyle(.secondary) }
            ToolbarItem(placement: .topBarTrailing) { Button(action: openSettings) { Image(systemName: "person.crop.circle") }.accessibilityLabel("设置与个人资料") }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let active = store.activeSession {
                    Button("继续这次训练") { openWorkout(active.id) }.buttonStyle(FitnessPrimaryButtonStyle())
                } else {
                    Button(store.currentPlan == nil ? "开始自由训练" : "开始这次训练") { start() }
                        .buttonStyle(FitnessPrimaryButtonStyle())
                }
            }.padding(.horizontal, 20).padding(.vertical, 10).background(FitnessTheme.canvas)
        }
        .fitnessError($issue)
    }

    private var weekStrip: some View {
        HStack {
            ForEach(0..<7) { offset in
                let calendar = Calendar.current
                let weekStart = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
                let date = calendar.date(byAdding: .day, value: offset, to: weekStart) ?? .now
                let isToday = calendar.isDateInToday(date)
                VStack(spacing: 9) {
                    Text(date, format: .dateTime.weekday(.narrow)).font(.caption2).foregroundStyle(.secondary)
                    Text(date, format: .dateTime.day()).font(.subheadline.weight(.semibold))
                        .frame(width: 35, height: 35)
                        .foregroundStyle(isToday ? FitnessTheme.surface : Color.primary)
                        .background(isToday ? Color.primary : .clear, in: Circle())
                }.frame(maxWidth: .infinity)
            }
        }
    }

    private func planCover(_ plan: PlanVersion) -> some View {
        ZStack(alignment: .leading) {
            HStack { Spacer(); Image("Equipment").resizable().scaledToFit().frame(width: 230).opacity(0.65).offset(x: 40) }
            VStack(alignment: .leading, spacing: 12) {
                Text("当前手动计划 · v\(plan.version)").font(.caption).foregroundStyle(.white.opacity(0.75))
                Text(plan.name).font(.title2.weight(.bold)).lineLimit(3).frame(maxWidth: 250, alignment: .leading)
                Spacer(minLength: 15)
                Text("\(plan.items.count) 个动作  ·  \(plan.items.reduce(0) { $0 + $1.setCount }) 组")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }.padding(20)
        }.foregroundStyle(.white).frame(height: 190).background(FitnessTheme.cover, in: RoundedRectangle(cornerRadius: 18)).clipped()
    }

    private func start() {
        do { openWorkout(try store.startWorkout(plan: store.currentPlan).id) }
        catch { issue = error.localizedDescription }
    }
}
