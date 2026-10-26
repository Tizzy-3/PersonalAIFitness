import SwiftUI
import FitnessCore

@MainActor
struct WorkoutView: View {
    let store: TrainingStore
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var issue: String?
    @State private var adding = false
    @State private var finishing = false
    @State private var noteTarget: NoteRoute?

    private var session: WorkoutSession? { store.session(id: sessionID) }

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 28) {
                            metric("训练时长", value: UIInput.duration(session.elapsed(at: context.date)))
                            metric("完成正式组", value: "\(session.completedWorkingSets) / \(session.plannedWorkingSets)")
                            Spacer(minLength: 0)
                            if session.status == .paused { Text("已暂停").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                        }.padding(.horizontal, 20).padding(.vertical, 14)
                    }.background(FitnessTheme.surface)
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            if session.exercises.isEmpty {
                                ContentUnavailableView("添加你要练的动作", systemImage: "dumbbell", description: Text("从动作库选择，填写每组结果后勾选完成。"))
                            }
                            ForEach(session.exercises) { item in exerciseCard(item, session: session) }
                        }.padding(16)
                    }.background(FitnessTheme.canvas)
                    if session.status.isOngoing { restDock(session) }
                }
                .navigationTitle(session.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button { dismiss() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("收起训练，保留记录") }
                    ToolbarItem(placement: .topBarTrailing) { Button("结束") { hideKeyboard(); finishing = true }.disabled(!session.status.isOngoing) }
                }
                .safeAreaInset(edge: .bottom) {
                    if session.status.isOngoing {
                        HStack(spacing: 12) {
                            Button { togglePause(session) } label: {
                                Image(systemName: session.status == .paused ? "play.fill" : "pause.fill")
                                    .frame(width: 50, height: 48).background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                            }.accessibilityLabel(session.status == .paused ? "恢复训练" : "暂停训练")
                            Button("添加动作", systemImage: "plus") { adding = true }
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(FitnessTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
                                .disabled(session.status == .paused)
                        }.font(.subheadline.weight(.semibold)).padding(.horizontal, 20).padding(.vertical, 10).background(FitnessTheme.surface)
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
        .confirmationDialog("结束并保留这次训练？", isPresented: $finishing, titleVisibility: .visible) {
            Button("正常结束并保存") { finish(early: false) }
            Button("提前结束，保留已做记录") { finish(early: true) }
            Button("继续训练", role: .cancel) { }
        } message: { Text("已保存的组会保留；未完成组不会被标成完成。尚未保存的输入不算训练结果。") }
        .fitnessError($issue)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.7).lineLimit(1)
        }
    }

    private func exerciseCard(_ item: WorkoutExercise, session: WorkoutSession) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ExerciseTile(exercise: item.exercise, size: 54)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.exercise.name).font(.headline)
                    Text(item.skipped ? "本次已跳过" : item.exercise.loadConvention.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("添加热身组") { appendSet(item, kind: .warmup) }
                    Button("备注") { noteTarget = NoteRoute(id: item.id, note: item.note) }
                    Button(item.skipped ? "恢复本次动作" : "跳过本次动作") { skip(item) }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(session.status != .active)
            }.padding(14)
            HStack {
                NavigationLink { ExerciseDetailView(exercise: item.exercise, store: store) } label: { Label("动作说明", systemImage: "info.circle") }
                Spacer()
                Button("备注", systemImage: "note.text") { noteTarget = NoteRoute(id: item.id, note: item.note) }.disabled(session.status != .active)
            }.font(.caption).padding(.horizontal, 16).padding(.bottom, 12)
            if !item.note.isEmpty { Text(item.note).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 10) }
            WorkoutTableHeader(exercise: item.exercise)
            ForEach(Array(item.sets.enumerated()), id: \.element.id) { index, set in
                let number = item.sets.prefix(index + 1).filter { $0.kind == .working }.count
                WorkoutSetRow(store: store, sessionID: sessionID, item: item, set: set, number: number,
                              canEdit: session.status == .active && !item.skipped)
            }
            if !item.skipped {
                Button("添加一组", systemImage: "plus") { appendSet(item, kind: .working) }
                    .font(.subheadline).frame(maxWidth: .infinity, minHeight: 46)
                    .disabled(session.status != .active)
                Divider()
                HStack {
                    Text("完成后开始休息").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制上一组") { copyLast(item) }.font(.caption)
                        .disabled(session.status != .active || item.sets.isEmpty)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }.background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 16))
    }

    private func restDock(_ session: WorkoutSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.secondary)
                Text("组间休息").font(.caption).foregroundStyle(.secondary)
                Text(UIInput.duration(session.remainingRest(at: context.date))).font(.title3.weight(.semibold).monospacedDigit())
                Spacer(minLength: 0)
                Button("−15") { adjustRest(-15) }.accessibilityLabel("缩短休息十五秒")
                Button("+15") { adjustRest(15) }.accessibilityLabel("延长休息十五秒")
                Button("跳过") { adjustRest(nil) }
            }.font(.caption).buttonStyle(.bordered).controlSize(.small)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(FitnessTheme.surface)
        }
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
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

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
