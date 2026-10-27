import SwiftUI
import FitnessCore

struct WorkoutRoute: Identifiable { let id: UUID }
/// Navigation route for a draft produced by the interview, so it opens the same confirm screen.
struct InterviewDraftRoute: Identifiable, Hashable { let id: UUID }
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
    @State private var capturePlanner = false
    @State private var captureInterview = false

    init(store: TrainingStore) {
        self.store = store
        #if DEBUG
        // CI captures actual empty-state screens, without adding fabricated user data.
        let arguments = ProcessInfo.processInfo.arguments
        _capturePlanner = State(initialValue: arguments.contains("--capture-planner"))
        _captureInterview = State(initialValue: arguments.contains("--capture-interview"))
        _settings = State(initialValue: arguments.contains("--capture-settings"))
        if arguments.contains("--capture-workout"), let active = store.activeSession {
            _workout = State(initialValue: WorkoutRoute(id: active.id))
        }
        if let index = arguments.firstIndex(of: "--capture-tab"), arguments.indices.contains(index + 1),
           let tab = Int(arguments[index + 1]), (0...4).contains(tab) {
            _selectedTab = State(initialValue: tab)
        }
        if arguments.contains("--capture-history") { _selectedTab = State(initialValue: 3) }
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
            NavigationStack { TrainingHistoryCalendarView(store: store, openWorkout: { workout = WorkoutRoute(id: $0) }) }
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }.tag(3)
            NavigationStack { CoachView(store: store) }
                .tabItem { Label("教练", systemImage: "bubble.left.and.text.bubble.right") }.tag(4)
        }
        .tint(FitnessTheme.accent)
        .sheet(item: $planEditor) { route in NavigationStack { PlanEditorView(store: store, revising: route.plan) } }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView(store: store) } }
        .sheet(isPresented: $capturePlanner) { NavigationStack { PlannerView(store: store) } }
        .sheet(isPresented: $captureInterview) { NavigationStack { CoachInterviewView(store: store) } }
        .fullScreenCover(item: $workout) { route in
            NavigationStack { WorkoutView(store: store, sessionID: route.id) }
        }
    }
}
