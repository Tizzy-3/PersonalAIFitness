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
    @State private var captureMedia = false
    @State private var captureLibrary = false
    @State private var captureConstraintReview = false
    @State private var captureConstraintDraft = false

    init(store: TrainingStore) {
        self.store = store
        #if DEBUG
        // CI captures actual empty-state screens, without adding fabricated user data.
        let arguments = ProcessInfo.processInfo.arguments
        _capturePlanner = State(initialValue: arguments.contains("--capture-planner"))
        _captureInterview = State(initialValue: arguments.contains("--capture-interview"))
        if arguments.contains("--capture-constraint-interview") { _captureInterview = State(initialValue: true) }
        _captureConstraintReview = State(initialValue: arguments.contains("--capture-constraint-review") || arguments.contains("--capture-constraint-readback") || arguments.contains("--capture-constraint-deferred") || arguments.contains("--capture-constraint-deferred-readback") || arguments.contains("--capture-constraint-gentle-readback"))
        _captureConstraintDraft = State(initialValue: arguments.contains("--capture-constraint-draft"))
        _captureMedia = State(initialValue: arguments.contains("--capture-media"))
        _settings = State(initialValue: arguments.contains("--capture-settings"))
        if arguments.contains("--capture-workout"), let active = store.activeSession {
            _workout = State(initialValue: WorkoutRoute(id: active.id))
        }
        if let index = arguments.firstIndex(of: "--capture-tab"), arguments.indices.contains(index + 1),
           let tab = Int(arguments[index + 1]), (0...2).contains(tab) {
            _selectedTab = State(initialValue: tab)
        }
        if arguments.contains("--capture-history") { _selectedTab = State(initialValue: 1) }
        // The exercise library is no longer a tab; CI opens it directly so the screenshot coverage
        // stays intact.
        _captureLibrary = State(initialValue: arguments.contains("--capture-library"))
        #endif
    }

    var body: some View {
        // Three tabs, not five. The person asked for one place to train and one to talk to the coach;
        // the exercise library and the plan library now live inside those, where they are actually
        // needed, instead of competing for a tab.
        TabView(selection: $selectedTab) {
            NavigationStack {
                TodayView(store: store, openWorkout: { workout = WorkoutRoute(id: $0) },
                          editPlan: { planEditor = PlanEditorRoute(plan: $0) },
                          openSettings: { settings = true },
                          openCoach: { selectedTab = 2 })
            }
            .tabItem { Label("今天", systemImage: "house") }.tag(0)
            NavigationStack {
                TrainingHistoryCalendarView(store: store, openWorkout: { workout = WorkoutRoute(id: $0) })
            }
            .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }.tag(1)
            NavigationStack { CoachConversationView(store: store) }
                .tabItem { Label("教练", systemImage: "bubble.left.and.text.bubble.right") }.tag(2)
        }
        .tint(FitnessTheme.accent)
        // A tab change is a navigation, not a value edit; a light tap keeps it feeling responsive
        // without the heavier "success" pattern that belongs to completing a set.
        .onChange(of: selectedTab) { _, _ in Haptics.tap() }
        .onAppear { Haptics.prepare() }
        .sheet(item: $planEditor) { route in NavigationStack { PlanEditorView(store: store, revising: route.plan) } }
        .sheet(isPresented: $settings) { NavigationStack { SettingsView(store: store) } }
        .sheet(isPresented: $capturePlanner) { NavigationStack { PlannerView(store: store) } }
        .sheet(isPresented: $captureInterview) {
            NavigationStack { CoachInterviewView(store: store).safeAreaInset(edge: .top) { validationLabel } }
        }
        .sheet(isPresented: $captureMedia) {
            NavigationStack {
                if let exercise = ExerciseCatalog.exercise(id: "builtin.barbell-bench-press") {
                    ExerciseDetailView(exercise: exercise, store: store)
                }
            }
        }
        .sheet(isPresented: $captureLibrary) {
            NavigationStack { ExerciseLibraryView(store: store) }
        }
        .sheet(isPresented: $captureConstraintReview) {
            NavigationStack {
                SimpleConstraintChatView(store: store)
                    .safeAreaInset(edge: .top) { validationLabel }
            }
        }
        .sheet(isPresented: $captureConstraintDraft) {
            NavigationStack {
                if let draft = store.planningDrafts.first {
                    PlanningDraftDetailView(store: store, draftID: draft.id)
                        .safeAreaInset(edge: .top) { validationLabel }
                }
            }
        }
        .fullScreenCover(item: $workout) { route in
            NavigationStack { WorkoutView(store: store, sessionID: route.id) }
        }
    }

    @ViewBuilder private var validationLabel: some View {
        #if DEBUG
        if ConstraintValidationData.isActive {
            Text("界面验证数据 · 隔离内存 · 不保存").font(.caption).foregroundStyle(FitnessTheme.orange).padding(8)
        }
        #endif
    }
}
