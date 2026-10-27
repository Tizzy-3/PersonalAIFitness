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
        .fitnessError($issue)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.weight(.bold).monospacedDigit()).fixedSize(horizontal: false, vertical: true)
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
                    .font(.caption).foregroundStyle(FitnessTheme.orange)
            }
            if session.plannedWorkingSets > 0 {
                ProgressView(value: Double(session.completedWorkingSets), total: Double(session.plannedWorkingSets))
                    .tint(FitnessTheme.teal)
                    .accessibilityLabel("正式组进度")
                    .accessibilityValue("已完成\(session.completedWorkingSets)组，共\(session.plannedWorkingSets)组")
            }
        }.padding(16).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
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
                    Text(item.skipped ? "本次已跳过" : item.exercise.loadConvention.title).font(.caption).foregroundStyle(.secondary)
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

    private func restDock(_ session: WorkoutSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = session.remainingRest(at: context.date)
            Group {
                if dynamicTypeSize >= .xxLarge {
                    VStack(alignment: .leading, spacing: 6) {
                        restHeading(session, seconds: seconds)
                        HStack { Text("休息操作").font(.caption); Spacer(); restControls(seconds: seconds) }
                    }
                } else {
                    HStack(spacing: 6) {
                        restHeading(session, seconds: seconds)
                        restControls(seconds: seconds)
                    }
                }
            }.padding(12).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func restHeading(_ session: WorkoutSession, seconds: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "timer").font(.system(size: 19, weight: .medium)).foregroundStyle(FitnessTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("组间休息").font(.caption.weight(.semibold))
                Text(seconds > 0 ? session.status == .paused ? "暂停中" : "计时中" : "完成一组后开始")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(UIInput.duration(seconds)).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(FitnessTheme.accent)
        }
    }

    private func restControls(seconds: Double) -> some View {
        HStack(spacing: 0) {
            Button { adjustRest(nil) } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 16)).frame(width: 44, height: 44)
            }.accessibilityLabel("跳过休息").disabled(seconds <= 0)
            Menu {
                Button("缩短 15 秒") { adjustRest(-15) }
                Button("延长 15 秒") { adjustRest(15) }
                Button("跳过休息") { adjustRest(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
            }.accessibilityLabel("调整组间休息")
        }.buttonStyle(.borderless).foregroundStyle(FitnessTheme.accent)
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
            pendingFeedback = PostWorkoutRoute(id: sessionID)
        } catch { issue = error.localizedDescription }
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
