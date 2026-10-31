import SwiftUI
import FitnessCore

@MainActor
struct WorkoutView: View {
    let store: TrainingStore
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var issue: String?
    @State private var adding = false
    @State private var finishing = false
    @State private var noteTarget: NoteRoute?
    @State private var pendingFeedback: PostWorkoutRoute?
    @State private var showingProfileForWeight = false

    private var session: WorkoutSession? { store.session(id: sessionID) }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--capture-workout") {
                        Text("界面验证数据 · 内存临时会话 · 不保存")
                            .font(.caption).foregroundStyle(FitnessTheme.orange).frame(maxWidth: .infinity).padding(8)
                            .background(FitnessTheme.surface)
                    }
                    #endif
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        summary(session, at: context.date)
                    }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if session.exercises.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    Image(systemName: "dumbbell.fill")
                                        .font(.largeTitle).foregroundStyle(FitnessTheme.accent)
                                        .frame(width: 72, height: 72).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 18))
                                    Text("从第一个动作开始").font(.title3.weight(.semibold))
                                    Text("从动作库添加动作，再逐组填写实际结果。")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    Button("选择动作", systemImage: "plus") { adding = true }
                                        .buttonStyle(FitnessPrimaryButtonStyle()).disabled(session.status != .active)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                                    .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                            }
                            ForEach(session.exercises) { item in exerciseCard(item, session: session) }
                        }.padding(16)
                    }.scrollDismissesKeyboard(.interactively)
                }
                .background(FitnessTheme.canvas)
                .navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { hideKeyboard(); dismiss() } label: { Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("收起训练，保留记录") }
                    ToolbarItem(placement: .topBarTrailing) { Button("结束") { hideKeyboard(); finishing = true }.disabled(!session.status.isOngoing) }
                }
                .safeAreaInset(edge: .bottom) {
                    if session.status.isOngoing {
                        VStack(spacing: 4) {
                            restDock(session).padding(.bottom, 8)
                            Button("添加动作", systemImage: "plus") { adding = true }
                                .buttonStyle(FitnessPrimaryButtonStyle())
                                .disabled(session.status == .paused)
                            HStack {
                                Button("收起训练") { hideKeyboard(); dismiss() }.frame(minHeight: 44)
                                Spacer(minLength: 8)
                                Label("本地记录", systemImage: "externaldrive.badge.checkmark")
                                    .foregroundStyle(FitnessTheme.teal)
                            }.font(.caption)
                        }.padding(.horizontal, 16).padding(.top, 10).background(FitnessTheme.surface)
                    }
                }
            } else {
                ContentUnavailableView("无法找到这次训练", systemImage: "exclamationmark.triangle")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                ExercisePickerView(store: store) { exercise in
                    mutate { current in
                        let blank = LoggedSet()
                        current.exercises.append(WorkoutExercise(exercise: exercise, sets: [blank]))
                    }
                }
            }
        }
        .sheet(item: $noteTarget) { route in
            NavigationStack { WorkoutNoteView(note: route.note) { text in
                try store.updateSession(id: sessionID) { current in
                    guard let index = current.exercises.firstIndex(where: { $0.id == route.id }) else { throw UIInput.Invalid(message: "动作已变化，请重新打开备注。") }
                    current.exercises[index].note = text
                }
            } }
        }
        .sheet(isPresented: $showingProfileForWeight) {
            NavigationStack { CoachProfileReviewView(store: store) }
        }
        .sheet(item: $pendingFeedback) { route in
            NavigationStack {
                PostWorkoutFeedbackView(store: store, sessionID: route.id) { dismiss() }
            }
        }
        .confirmationDialog("结束并保留这次训练？", isPresented: $finishing, titleVisibility: .visible) {
            Button("正常结束并保存") { finish(early: false) }
            Button("提前结束，保留已做记录") { finish(early: true) }
            Button("继续训练", role: .cancel) { }
        } message: { Text("已保存的组会保留；未完成组不会被标成完成。尚未保存的输入不算训练结果。") }
        .onAppear { Haptics.prepare() }
        .fitnessError($issue)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, design: .rounded)).foregroundStyle(FitnessTheme.faint)
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(FitnessTheme.ink)
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(FitnessTheme.Motion.state, value: value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ session: WorkoutSession, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if dynamicTypeSize.isAccessibilitySize {
                metric("本次时长", value: UIInput.duration(session.elapsed(at: date)))
                metric("完成正式组", value: "\(session.completedWorkingSets) / \(session.plannedWorkingSets)")
                if session.status.isOngoing { pauseButton(session) }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    metric("本次时长", value: UIInput.duration(session.elapsed(at: date))).frame(maxWidth: .infinity, alignment: .leading)
                    metric("完成正式组", value: "\(session.completedWorkingSets) / \(session.plannedWorkingSets)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.status.isOngoing { pauseButton(session) }
                }
            }
            if session.status == .paused {
                Label("训练已暂停，恢复后继续记录", systemImage: "pause.circle.fill")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(FitnessTheme.orange)
            }
            if let kcal = sessionCalories {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill").font(.system(size: 12))
                    Text("已消耗约 \(kcal) 千卡")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    Spacer(minLength: 0)
                    Text("估算").font(.system(size: 10, design: .rounded)).foregroundStyle(FitnessTheme.faint)
                }
                .foregroundStyle(FitnessTheme.accent)
                .accessibilityLabel("本次已消耗约 \(kcal) 千卡，估算")
            }
            if session.plannedWorkingSets > 0 {
                // Segmented bar instead of a thin system ProgressView: one segment per planned set,
                // so progress is countable without reading the fraction.
                setProgressBar(completed: session.completedWorkingSets,
                               planned: session.plannedWorkingSets)
                    .accessibilityLabel("正式组进度")
                    .accessibilityValue("已完成\(session.completedWorkingSets)组，共\(session.plannedWorkingSets)组")
            }
        }.padding(16)
            .background(RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
                .fill(FitnessTheme.surface)
                .shadow(color: FitnessTheme.cardShadow, radius: 10, y: 4))
    }

    private func setProgressBar(completed: Int, planned: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<max(1, planned), id: \.self) { index in
                Capsule()
                    .fill(index < completed ? FitnessTheme.teal : FitnessTheme.line)
                    .frame(height: 4)
            }
        }
        .animation(FitnessTheme.Motion.state, value: completed)
    }

    /// Calories for one movement, using the planned target while training and the completed sets
    /// afterwards. `nil` whenever the estimate cannot be made honestly (no body weight, no target).
    private func itemCalories(_ item: WorkoutExercise) -> Int? {
        let weight = CalorieEstimator.bodyWeightKG(store.interview?.profile ?? StructuredProfile())
        let completed = item.sets.filter { $0.kind == .working && $0.isCompleted }
        if !completed.isEmpty {
            let reps = completed.compactMap(\.reps).max()
            let seconds = completed.compactMap(\.durationSeconds).max()
            return CalorieEstimator.estimate(
                exercise: item.exercise, sets: completed.count,
                targetReps: reps ?? item.sets.first(where: { $0.kind == .working })?.reps,
                targetSeconds: seconds ?? item.sets.first(where: { $0.kind == .working })?.durationSeconds,
                restSeconds: item.restSeconds, weightKG: weight)
        }
        let planned = item.sets.filter { $0.kind == .working }
        guard let first = planned.first else { return nil }
        return CalorieEstimator.estimate(
            exercise: item.exercise, sets: planned.count,
            targetReps: first.reps, targetSeconds: first.durationSeconds,
            restSeconds: item.restSeconds, weightKG: weight)
    }

    /// Total for this session so far, and the label that keeps it honest.
    private var sessionCalories: Int? {
        guard let session else { return nil }
        return CalorieEstimator.estimate(
            session: session,
            weightKG: CalorieEstimator.bodyWeightKG(store.interview?.profile ?? StructuredProfile()))
    }


    private func pauseButton(_ session: WorkoutSession) -> some View {
        Button { togglePause(session) } label: {
            Image(systemName: session.status == .paused ? "play.fill" : "pause.fill")
                .font(.body.weight(.semibold)).foregroundStyle(FitnessTheme.accent)
                .frame(width: 46, height: 48).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(session.status == .paused ? "恢复训练" : "暂停训练")
    }

    private func exerciseCard(_ item: WorkoutExercise, session: WorkoutSession) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                ExerciseTile(exercise: item.exercise, size: dynamicTypeSize.isAccessibilitySize ? 64 : 98,
                             animated: session.status == .active && item.id == session.exercises.first(where: {
                                 !$0.skipped && $0.sets.contains(where: { !$0.isCompleted && !$0.skipped })
                             })?.id)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.exercise.name).font(.headline)
                    HStack(spacing: 8) {
                        Text(item.skipped ? "本次已跳过" : item.exercise.loadConvention.title)
                            .font(.caption).foregroundStyle(.secondary)
                        // No body weight means no calorie number, and the person needs to know why
                        // instead of assuming the feature is missing.
                        if itemCalories(item) == nil, store.interview?.profile.weightKG.isUsable != true {
                            Button { showingProfileForWeight = true } label: {
                                Text("填体重可估算千卡")
                                    .font(.system(size: 11, design: .rounded))
                                    .foregroundStyle(FitnessTheme.faint)
                            }
                            .buttonStyle(.plain)
                        }
                        if let kcal = itemCalories(item) {
                            // An estimate, and labelled as one wherever it appears.
                            Text("\(kcal) 千卡")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(FitnessTheme.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(FitnessTheme.blueTint, in: Capsule())
                                .accessibilityLabel("预计消耗 \(kcal) 千卡，估算")
                        }
                    }
                    NavigationLink { ExerciseDetailView(exercise: item.exercise, store: store) } label: {
                        Label(ExerciseDetails.details(for: item.exercise.id)?.media?.kind == .video ? "动作示范" : "动作要点",
                              systemImage: ExerciseDetails.details(for: item.exercise.id)?.media?.kind == .video ? "play.rectangle" : "text.book.closed")
                            .font(.caption.weight(.semibold)).padding(.horizontal, 10).frame(minHeight: 44)
                            .background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).foregroundStyle(FitnessTheme.accent)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("添加热身组") { appendSet(item, kind: .warmup) }
                    Button("备注") { noteTarget = NoteRoute(id: item.id, note: item.note) }
                    Button(item.skipped ? "恢复本次动作" : "跳过本次动作") { skip(item) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 44, height: 44) }
                    .disabled(session.status != .active)
                    .accessibilityLabel("\(item.exercise.name)的更多操作")
            }.padding(16)
            if !item.note.isEmpty { Text(item.note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10) }
            WorkoutTableHeader(exercise: item.exercise)
            ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                let number = item.sets.prefix(index + 1).filter { $0.kind == .working }.count
                WorkoutSetRow(store: store, sessionID: sessionID, item: item, set: set, number: number,
                              canEdit: session.status == .active && !item.skipped)
            }
            // Feeling is asked per movement, right after its sets, where the memory is fresh.
            if !item.skipped, session.status.isOngoing || item.hasFeedback {
                Divider()
                ExerciseFeelingCard(store: store, sessionID: sessionID, item: item)
            }
            if !item.skipped {
                Divider()
                HStack {
                    Button("增加一组", systemImage: "plus") { appendSet(item, kind: .working) }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 46)
                        .disabled(session.status != .active)
                    Spacer()
                    Button("复制上一组") { copyLast(item) }.font(.caption)
                        .frame(minHeight: 46)
                        .disabled(session.status != .active || item.sets.isEmpty)
                }.padding(.horizontal, 16)
            }
        }.background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    /// The rest dock: a countdown ring, the next set, and two thumb-sized shortcuts. The ring is the
    /// whole point — a number alone does not tell you how much is left without reading it.
    private func restDock(_ session: WorkoutSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = session.remainingRest(at: context.date)
            let total = max(1, session.exercises.first?.restSeconds ?? 90)
            let progress = seconds > 0 ? 1 - (seconds / total) : 1
            Group {
                if dynamicTypeSize >= .xxLarge {
                    VStack(alignment: .leading, spacing: 8) {
                        restHeading(session, seconds: seconds, progress: progress)
                        HStack { Text("休息操作").font(.system(size: 12, design: .rounded)); Spacer(); restControls(seconds: seconds) }
                    }
                } else {
                    HStack(spacing: 12) {
                        restRing(seconds: seconds, progress: progress)
                        restHeading(session, seconds: seconds, progress: progress)
                        restControls(seconds: seconds)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(seconds > 0 ? FitnessTheme.blueTint : FitnessTheme.sunken)
            )
            .onChange(of: seconds > 0) { wasRunning, running in
                if wasRunning && !running { Haptics.timerDone() }
            }
        }
    }

    private func restRing(seconds: Double, progress: Double) -> some View {
        ProgressRing(progress: progress, lineWidth: 3.5,
                     tint: seconds > 0 ? FitnessTheme.accent : FitnessTheme.faint,
                     track: FitnessTheme.accent.opacity(0.16)) {
            Text(seconds > 0 ? UIInput.duration(seconds) : "0:00")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(seconds > 0 ? FitnessTheme.accent : FitnessTheme.faint)
                .monospacedDigit()
        }
        .frame(width: 46, height: 46)
        .animation(FitnessTheme.Motion.quick, value: seconds > 0)
    }

    private func restHeading(_ session: WorkoutSession, seconds: Double, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(seconds > 0 ? (session.status == .paused ? "休息 · 已暂停" : "休息中") : "休息")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(seconds > 0 ? FitnessTheme.accent : FitnessTheme.faint)
            Text(nextSetHint(session, seconds: seconds))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(FitnessTheme.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What comes next, so the person does not have to scroll to find out during a rest.
    private func nextSetHint(_ session: WorkoutSession, seconds: Double) -> String {
        guard seconds > 0 else { return "完成一组后自动开始" }
        for exercise in session.exercises where !exercise.skipped {
            if let pending = exercise.sets.first(where: { !$0.isCompleted && !$0.skipped }) {
                let load = pending.loadKG.map { UIInput.number($0) + "kg" } ?? ""
                let reps = pending.reps.map { " × \($0)" } ?? ""
                return "下一组 · \(exercise.exercise.name)\(load.isEmpty ? "" : " " + load)\(reps)"
            }
        }
        return "全部组已完成"
    }

    private func restControls(seconds: Double) -> some View {
        HStack(spacing: 6) {
            Button { adjustRest(15) } label: {
                Text("+15s")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FitnessTheme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(FitnessTheme.surface, in: Capsule())
            }.accessibilityLabel("延长休息十五秒")
            Button { adjustRest(nil) } label: {
                Text("跳过")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FitnessTheme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(FitnessTheme.surface, in: Capsule())
            }.accessibilityLabel("跳过休息").disabled(seconds <= 0)
        }
        .buttonStyle(.plain)
    }

    private func mutate(_ action: (inout WorkoutSession) throws -> Void) {
        do { try store.updateSession(id: sessionID, action) }
        catch { issue = error.localizedDescription }
    }
    private func appendSet(_ item: WorkoutExercise, kind: SetKind) {
        mutate { current in
            guard let index = current.exercises.firstIndex(where: { $0.id == item.id }) else { return }
            current.exercises[index].sets.append(LoggedSet(kind: kind))
        }
    }
    private func copyLast(_ item: WorkoutExercise) {
        mutate { current in
            guard let index = current.exercises.firstIndex(where: { $0.id == item.id }), let source = current.exercises[index].sets.last(where: { $0.isCompleted }) ?? current.exercises[index].sets.last else { return }
            var copy = source.copied()
            if let destination = current.exercises[index].sets.firstIndex(where: { !$0.isCompleted && !$0.skipped }) {
                copy.id = current.exercises[index].sets[destination].id
                copy.kind = current.exercises[index].sets[destination].kind
                current.exercises[index].sets[destination] = copy
            } else {
                current.exercises[index].sets.append(copy)
            }
        }
    }
    private func skip(_ item: WorkoutExercise) {
        mutate { current in
            guard let index = current.exercises.firstIndex(where: { $0.id == item.id }) else { return }
            current.exercises[index].skipped.toggle()
            for setIndex in current.exercises[index].sets.indices where !current.exercises[index].sets[setIndex].isCompleted {
                current.exercises[index].sets[setIndex].skipped = current.exercises[index].skipped
            }
        }
    }
    private func togglePause(_ session: WorkoutSession) {
        hideKeyboard()
        mutate { current in
            if session.status == .paused { try current.resume() } else { try current.pause() }
        }
    }
    private func adjustRest(_ difference: Double?) {
        mutate { current in
            let seconds = difference.map { max(0, current.remainingRest() + $0) } ?? 0
            if current.status == .paused { current.pausedRestSeconds = seconds }
            else { current.restEndsAt = seconds > 0 ? Date.now.addingTimeInterval(seconds) : nil }
        }
    }
    private func finish(early: Bool) {
        do {
            try store.updateSession(id: sessionID) { try $0.finish(early: early) }
            Haptics.sessionSaved()
            pendingFeedback = PostWorkoutRoute(id: sessionID)
        } catch { Haptics.warning(); issue = error.localizedDescription }
    }
}

/// Route for the post-workout feedback sheet shown after a session is saved.
struct PostWorkoutRoute: Identifiable, Hashable { let id: UUID }

private struct NoteRoute: Identifiable { let id: UUID; let note: String }

private struct WorkoutNoteView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var note: String
    let save: (String) throws -> Void
    @State private var issue: String?
    init(note: String, save: @escaping (String) throws -> Void) { _note = State(initialValue: note); self.save = save }
    var body: some View {
        Form { Section("本次动作备注") { TextEditor(text: $note).frame(minHeight: 160) } }
            .navigationTitle("备注").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do { try save(note); dismiss() }
                        catch { issue = error.localizedDescription }
                    }
                }
            }.fitnessError($issue)
    }
}
