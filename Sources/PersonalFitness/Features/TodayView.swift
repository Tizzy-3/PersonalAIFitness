import SwiftUI
import FitnessCore

@MainActor
struct TodayView: View {
    let store: TrainingStore
    let openWorkout: (UUID) -> Void
    let editPlan: (PlanVersion?) -> Void
    let openSettings: () -> Void
    let openCoach: () -> Void
    @State private var issue: String?
    @State private var showingCheckIn = false
    @Environment(\.dynamicTypeSize) private var typeSize

    private var teaching: Exercise? { store.allExercises.first { ExerciseDetails.details(for: $0.id)?.media != nil } }
    private var weekStart: Date {
        let day = Calendar.current.startOfDay(for: .now)
        let offset = (Calendar.current.component(.weekday, from: day) + 5) % 7
        return Calendar.current.date(byAdding: .day, value: -offset, to: day) ?? day
    }
    private var thisWeek: [WorkoutSession] {
        store.sessions.filter { !$0.status.isOngoing && $0.startedAt >= weekStart && $0.startedAt <= .now
            && $0.exercises.contains(where: { $0.sets.contains(where: \.isCompleted) }) }
    }

    var body: some View {
        let brief = store.todayBrief
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                CoachBriefCard(brief: brief,
                               onCheckIn: store.scheduledPlan() == nil ? nil : { showingCheckIn = true },
                               openCoach: openCoach)
                streakStrip
                if let proposal = store.pendingAdjustment, proposal.kind != .keep {
                    PendingAdjustmentCard(proposal: proposal,
                                          isStale: store.isAdjustmentStale(proposal),
                                          destination: { AdjustmentReviewView(store: store) })
                }
                trainingCard
                if let program = store.currentWeeklyProgram {
                    NavigationLink { WeeklyProgramDetailView(store: store, programID: program.id, openWorkout: openWorkout) } label: {
                        HStack(spacing: 12) {
                            FitnessIconBadge(symbol: "calendar", color: FitnessTheme.teal)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("我的每周安排").font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(FitnessTheme.ink)
                                Text(program.selectedOption?.title ?? "已确认计划").font(.system(size: 12, design: .rounded)).foregroundStyle(FitnessTheme.faint)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(FitnessTheme.faint)
                        }
                        .padding(15)
                        .background(RoundedRectangle(cornerRadius: FitnessTheme.Radius.card, style: .continuous)
                            .fill(FitnessTheme.surface).shadow(color: FitnessTheme.cardShadow, radius: 10, y: 4))
                    }.buttonStyle(.plain)
                }
                healthCard
                if let teaching { teachingCard(teaching) }
                historyCard
            }.padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 28)
        }
        .background(FitnessTheme.canvas).navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCheckIn) {
            NavigationStack { CheckInView(store: store) }
        }
        .onAppear { Haptics.prepare() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(FitnessTheme.muted)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("设置与个人资料")
            }
        }
        .fitnessError($issue)
    }

    /// Consecutive training days, this week's count, and a seven-dot week strip. Replaces the plain
    /// date row: the point is momentum, and a bare calendar does not show it.
    private var streakStrip: some View {
        let weekCount = thisWeek.count
        let streak = consecutiveDayCount
        let planned = store.currentWeeklyProgram?.selectedOption?.days.filter { !$0.isRestDay }.count ?? 0
        return HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 1) {
                RollingNumber(value: streak, size: 27, color: FitnessTheme.teal)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("天连续训练").font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(FitnessTheme.teal)
                Text(planned > 0 ? "本周已完成 \(weekCount) / \(planned) 次" : "本周已完成 \(weekCount) 次")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(FitnessTheme.muted)
            }
            Spacer(minLength: 6)
            weekDots
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(FitnessTheme.tealTint))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("连续训练 \(streak) 天，本周已完成 \(weekCount) 次")
    }

    private var weekDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<7, id: \.self) { offset in
                let date = Calendar.current.date(byAdding: .day, value: offset, to: weekStart) ?? .now
                let trained = store.sessions.contains {
                    !$0.status.isOngoing && Calendar.current.isDate($0.startedAt, inSameDayAs: date)
                        && $0.exercises.contains { $0.sets.contains(where: \.isCompleted) }
                }
                let isToday = Calendar.current.isDateInToday(date)
                Circle()
                    .fill(trained ? FitnessTheme.teal : (isToday ? FitnessTheme.surface : FitnessTheme.teal.opacity(0.22)))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(isToday ? FitnessTheme.teal : .clear, lineWidth: 1.6))
            }
        }
        .accessibilityHidden(true)
    }

    /// Days in a row with a finished session, counting back from today (today counts if trained,
    /// otherwise the streak is measured up to yesterday so an untrained morning does not reset it).
    private var consecutiveDayCount: Int {
        let calendar = Calendar.current
        let days = Set(store.sessions.filter { !$0.status.isOngoing
            && $0.exercises.contains { $0.sets.contains(where: \.isCompleted) } }
            .map { calendar.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }
        var cursor = calendar.startOfDay(for: .now)
        if !days.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// Greeting plus today's headline. The plan name is folded into the sentence, which is what makes
    /// the screen read as "a coach talking to me" rather than "a dashboard".
    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(greeting).font(.system(size: 13, design: .rounded)).foregroundStyle(FitnessTheme.muted)
            headline
        }
        .padding(.top, 4)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 6 ? "凌晨好" : hour < 11 ? "早上好" : hour < 14 ? "中午好" : hour < 18 ? "下午好" : "晚上好"
        return "\(weekdayName)，\(part)"
    }

    private var weekdayName: String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[Calendar.current.component(.weekday, from: .now) - 1]
    }

    @ViewBuilder private var headline: some View {
        let plan = store.scheduledPlan()
        let base = Font.system(size: 29, weight: .bold, design: .rounded)
        if let plan {
            (Text("今天练").font(base)
             + Text(shortName(plan.name)).font(base).foregroundColor(FitnessTheme.accent)
             + Text("，").font(base)
             + Text("不着急。").font(base))
                .foregroundStyle(FitnessTheme.ink)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if store.activeSession != nil {
            Text("正在训练，继续。")
                .font(base).foregroundStyle(FitnessTheme.ink)
        } else if store.currentWeeklyProgram != nil {
            Text("今天休息。")
                .font(base).foregroundStyle(FitnessTheme.ink)
        } else {
            Text("先聊聊，再定计划。")
                .font(base).foregroundStyle(FitnessTheme.ink)
        }
    }

    /// The plan name is often long ("上肢推拉 · 第 3 周"); the headline only needs the movement group.
    private func shortName(_ name: String) -> String {
        let trimmed = name.split(separator: "·").first.map(String.init) ?? name
        return trimmed.trimmingCharacters(in: .whitespaces)
    }

    private var trainingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("今天练什么").font(.headline).foregroundStyle(FitnessTheme.ink)
                Spacer()
                Text(store.activeSession != nil ? "训练中" : store.scheduledPlan() == nil ? "未安排" : "已安排")
                    .font(.caption.weight(.medium)).foregroundStyle(FitnessTheme.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(FitnessTheme.blueTint, in: Capsule())
            }
            if let ongoing = store.activeSession {
                HStack(spacing: 13) {
                    FitnessIconBadge(symbol: ongoing.status == .paused ? "pause.circle" : "figure.strengthtraining.traditional")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ongoing.name).font(.title3.weight(.semibold))
                        Text("已完成 \(ongoing.completedWorkingSets) / \(ongoing.plannedWorkingSets) 正式组")
                            .font(.caption).foregroundStyle(FitnessTheme.muted)
                    }
                }
                Button("继续这次训练") { openWorkout(ongoing.id) }.buttonStyle(FitnessPrimaryButtonStyle())
            } else if let plan = store.scheduledPlan() {
                HStack(alignment: .top, spacing: 13) {
                    if let exercise = plan.items.first?.exercise { ExerciseTile(exercise: exercise, size: 76) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(plan.name).font(.title3.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                        Text("\(plan.items.count) 个动作 · \(plan.items.reduce(0) { $0 + $1.setCount }) 组")
                            .font(.subheadline).foregroundStyle(FitnessTheme.muted)
                        Text("已确认 · 版本 \(plan.version)").font(.caption).foregroundStyle(FitnessTheme.teal)
                    }
                }
                ForEach(plan.items.prefix(3)) { item in
                    NavigationLink { ExerciseDetailView(exercise: item.exercise, store: store) } label: {
                        HStack(spacing: 10) {
                            ExerciseTile(exercise: item.exercise, size: 42)
                            Text(item.exercise.name).font(.subheadline).foregroundStyle(FitnessTheme.ink)
                            Spacer(minLength: 4)
                            Text("\(item.setCount) 组").font(.caption).foregroundStyle(FitnessTheme.muted)
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
                if store.currentWeeklyProgram?.temporaryPlanVersionIDs?[TrainingConstraintReview.dateKey(Date())] == plan.id {
                    NavigationLink("先记录今天的身体状态") { CheckInView(store: store) }
                        .font(.callout)
                }
                Button("开始今天的训练") { start(plan) }.buttonStyle(FitnessPrimaryButtonStyle())
                if store.canProposeReduction(for: plan) {
                    NavigationLink { AdjustmentReviewView(store: store, proposeOnOpen: true) } label: {
                        Text("今天少一点（看方案）")
                    }.font(.subheadline).frame(minHeight: 44)
                }
                if store.currentWeeklyProgram == nil { Button("编辑计划") { editPlan(plan) }.font(.subheadline).frame(minHeight: 44) }
            } else if store.currentWeeklyProgram != nil {
                Label(store.isConstraintRestDay() ? "今天按已确认的限制休息" : "今天按计划休息", systemImage: "moon.zzz").font(.title3.weight(.semibold)).foregroundStyle(FitnessTheme.teal)
                Text(store.isConstraintRestDay() ? "这一天已明确排除训练。日期例外和每周休息日可在已确认周计划的约束里查看。" : "让身体喘口气，其他训练日的安排仍在周计划里。")
                    .font(.subheadline).foregroundStyle(FitnessTheme.muted)
                Button("开始自由训练") { start(nil) }.buttonStyle(.bordered).frame(minHeight: 44)
            } else {
                HStack(spacing: 14) {
                    FitnessIconBadge(symbol: "person.text.rectangle", color: FitnessTheme.violet)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("先让教练了解你").font(.title3.weight(.semibold)).foregroundStyle(FitnessTheme.ink)
                        Text("目标、器械、时间与身体限制，确认后再建立第一份计划。")
                            .font(.caption).foregroundStyle(FitnessTheme.muted)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { interviewButton; manualButton }
                    VStack(spacing: 10) { interviewButton; manualButton }
                }
                Button("直接开始自由训练", systemImage: "plus") { start(nil) }.font(.subheadline).frame(minHeight: 44)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 17))
    }
    private var interviewButton: some View {
        NavigationLink { CoachInterviewView(store: store) } label: { Text("让教练了解我") }.buttonStyle(FitnessPrimaryButtonStyle())
    }
    private var manualButton: some View {
        Button("手动创建") { editPlan(nil) }.font(.body.weight(.semibold)).padding(.horizontal, 16)
            .frame(minHeight: 50).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 14))
    }
    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { HealthStatusView(store: store) } label: {
                HStack { FitnessSectionHeading(title: "身体状态"); Spacer(); Text(store.healthSnapshot == nil ? "未同步健康" : "查看来源与状态").font(.caption).foregroundStyle(FitnessTheme.accent) }
            }.buttonStyle(.plain)
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 14) { healthMetric(.sleepAnalysis, "睡眠", "moon", FitnessTheme.violet); healthMetric(.restingHeartRate, "静息心率", "heart", FitnessTheme.orange); healthMetric(.heartRateVariabilitySDNN, "HRV · SDNN", "waveform.path.ecg", FitnessTheme.teal) }
                } else {
                    HStack(alignment: .top, spacing: 12) { healthMetric(.sleepAnalysis, "睡眠", "moon", FitnessTheme.violet); Divider().frame(height: 68); healthMetric(.restingHeartRate, "静息心率", "heart", FitnessTheme.orange); Divider().frame(height: 68); healthMetric(.heartRateVariabilitySDNN, "HRV · SDNN", "waveform.path.ecg", FitnessTheme.teal) }
                }
            }.padding(16).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 15))
        }
    }
    private func healthMetric(_ kind: HealthMetric, _ title: String, _ symbol: String, _ color: Color) -> some View {
        let metric = store.healthSnapshot?.snapshot(for: kind)
        let current = metric?.effectiveState(at: .now) == .available
        return VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(current ? metric?.latestValue.map { UIInput.number($0) } ?? "—" : "—")
                .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(FitnessTheme.ink)
            Text(current ? (kind == .sleepAnalysis ? "小时" : kind == .restingHeartRate ? "次/分" : "毫秒")
                 : metric?.effectiveState(at: .now).title ?? "暂无数据")
                .font(.caption2).foregroundStyle(FitnessTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
    private func teachingCard(_ exercise: Exercise) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                FitnessSectionHeading(title: "动作教学")
                Spacer()
                NavigationLink("查看全部") { ExerciseLibraryView(store: store) }.font(.caption)
            }
            NavigationLink { ExerciseDetailView(exercise: exercise, store: store) } label: {
                HStack(spacing: 13) {
                    ExerciseTile(exercise: exercise, size: 92)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(exercise.name).font(.headline).foregroundStyle(FitnessTheme.ink)
                        Text("\(exercise.muscle) · \(exercise.equipment)").font(.caption).foregroundStyle(FitnessTheme.muted)
                        Label("离线动作示范", systemImage: "play.circle").font(.caption).foregroundStyle(FitnessTheme.accent)
                    }
                    Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(FitnessTheme.muted)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 15))
            }.buttonStyle(.plain)
        }
    }
    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink { TrainingHistoryCalendarView(store: store, openWorkout: openWorkout) } label: {
                HStack { Label("本周 \(thisWeek.count) 次训练", systemImage: "calendar"); Spacer(); Text("月历历史").font(.caption); Image(systemName: "chevron.right").font(.caption2) }
                    .font(.subheadline).padding(14).background(FitnessTheme.blueTint, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).foregroundStyle(FitnessTheme.accent)
            if let recent = store.sessions.first(where: { !$0.status.isOngoing }) {
                NavigationLink { SessionDetailView(session: recent) } label: {
                    HStack { Image(systemName: "clock.arrow.circlepath"); Text("上次训练"); Spacer(); Text(recent.startedAt, style: .date) }
                        .font(.caption).foregroundStyle(FitnessTheme.muted).frame(minHeight: 44)
                }.buttonStyle(.plain)
            }
        }
    }
    private func start(_ plan: PlanVersion?) {
        do { openWorkout(try store.startWorkout(plan: plan).id) }
        catch { issue = error.localizedDescription }
    }
}
