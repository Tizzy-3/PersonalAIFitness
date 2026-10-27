import SwiftUI
import FitnessCore

/// The calendar is the history: selecting a date always opens the actual records below it.
/// No future plan or estimated workload is shown as if it had already been completed.
@MainActor
struct TrainingHistoryCalendarView: View {
    let store: TrainingStore
    var openWorkout: ((UUID) -> Void)? = nil
    @State private var displayedDate: Date
    @State private var selectedDate: Date
    @State private var showDatePicker = false
    @State private var showSettings = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(store: TrainingStore, openWorkout: ((UUID) -> Void)? = nil) {
        self.store = store
        self.openWorkout = openWorkout
        var initial = Date()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--capture-history") { initial = HistoryValidationData.referenceDate }
        #endif
        _displayedDate = State(initialValue: initial)
        _selectedDate = State(initialValue: initial)
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        result.firstWeekday = 2
        return result
    }

    private var now: Date {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--capture-history") { return HistoryValidationData.referenceDate }
        #endif
        return Date()
    }

    private var month: TrainingHistoryMonth? {
        try? TrainingHistoryMonth(containing: displayedDate, sessions: store.sessions, calendar: calendar, now: now)
    }

    private var dayStyle: Date.FormatStyle {
        Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: "zh_CN"),
                         calendar: calendar, timeZone: .current).month().day().weekday(.wide)
    }

    private var fullDayStyle: Date.FormatStyle { dayStyle.year() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--capture-history") {
                    Text("界面验证数据 · 隔离内存记录 · 不保存")
                        .font(.caption).foregroundStyle(FitnessTheme.orange)
                        .frame(maxWidth: .infinity).padding(.top, 4)
                }
                #endif
                monthHeader
                if let month {
                    monthCalendar(month)
                    monthSummary(month)
                    dayRecords(month)
                } else {
                    ContentUnavailableView("无法显示这个月", systemImage: "calendar.badge.exclamationmark",
                                           description: Text("请返回今天，重新选择月份。"))
                }
            }.padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 24)
        }
        .background(FitnessTheme.canvas)
        .navigationTitle("历史").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("设置", systemImage: "gearshape") { showSettings = true }
            }
        }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView(store: store) } }
        .sheet(isPresented: $showDatePicker) {
            NavigationStack {
                DatePicker("跳转到日期", selection: Binding(
                    get: { selectedDate }, set: { selectedDate = $0; displayedDate = $0 }), displayedComponents: .date)
                    .datePickerStyle(.graphical).padding()
                    .navigationTitle("选择月份").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDatePicker = false } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private var monthHeader: some View {
        HStack(alignment: .center, spacing: 4) {
            Button("上个月", systemImage: "chevron.left") { shiftMonth(-1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 48)
            Button { showDatePicker = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(calendar.component(.year, from: displayedDate)))
                        .font(.caption).foregroundStyle(FitnessTheme.muted)
                    HStack(spacing: 6) {
                        Text(String(calendar.component(.month, from: displayedDate)) + "月")
                            .font(.title2.weight(.bold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.foregroundStyle(FitnessTheme.ink)
                }.frame(minHeight: 48, alignment: .leading)
            }.buttonStyle(.plain).accessibilityLabel("\(String(calendar.component(.year, from: displayedDate)))年\(String(calendar.component(.month, from: displayedDate)))月，选择月份")
            Button("下个月", systemImage: "chevron.right") { shiftMonth(1) }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 48)
            Spacer(minLength: 0)
            Button("今天") { displayedDate = now; selectedDate = now }
                .font(.subheadline.weight(.medium)).frame(minWidth: 44, minHeight: 44)
        }.padding(.horizontal, 4)
    }

    private func monthCalendar(_ month: TrainingHistoryMonth) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                    Text(day).font(.caption.weight(.medium)).foregroundStyle(FitnessTheme.muted)
                        .frame(maxWidth: .infinity).accessibilityHidden(true)
                }
            }.padding(.vertical, 8)
            Divider()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 3), count: 7), spacing: 4) {
                ForEach(month.days) { day in
                    calendarDay(day)
                }
            }
        }
    }

    private func calendarDay(_ day: TrainingHistoryDay) -> some View {
        let selected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        return Button {
            selectedDate = day.date
            if !day.isInMonth { displayedDate = day.date }
        } label: {
            VStack(spacing: 7) {
                Text(String(calendar.component(.day, from: day.date)))
                    .font(dynamicTypeSize.isAccessibilitySize ? .caption.weight(.semibold) : .body.weight(.medium))
                    .foregroundStyle(day.isToday ? FitnessTheme.accentInk : FitnessTheme.ink)
                    .frame(minWidth: 30, minHeight: 30)
                    .background(day.isToday ? FitnessTheme.teal : Color.clear, in: Circle())
                if dynamicTypeSize.isAccessibilitySize {
                    if !day.sessions.isEmpty {
                        Text("\(day.sessions.count)")
                            .font(.caption2.weight(.semibold)).foregroundStyle(FitnessTheme.teal)
                    } else { Color.clear.frame(height: 8) }
                } else {
                    VStack(spacing: 3) {
                        ForEach(day.sessions.prefix(2)) { session in
                            calendarRecord(session)
                        }
                        if day.sessions.count > 2 {
                            Text("+\(day.sessions.count - 2)次").font(.caption2).foregroundStyle(FitnessTheme.teal)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2).padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: dynamicTypeSize.isAccessibilitySize ? 82 : 110, alignment: .top)
            .background(selected ? FitnessTheme.teal.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(selected ? FitnessTheme.teal : Color.clear, lineWidth: 1.5) }
            .opacity(day.isInMonth ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.date.formatted(fullDayStyle))
        .accessibilityValue(day.sessions.isEmpty ? "没有训练记录" : day.sessions.map { "\($0.name)，\($0.status.title)" }.joined(separator: "；"))
        .accessibilityHint("查看当天全部记录")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func calendarRecord(_ session: WorkoutSession) -> some View {
        let metrics = TrainingHistoryMetrics(session: session, at: now)
        let tint = session.status == .completed ? FitnessTheme.teal : session.status == .endedEarly ? FitnessTheme.orange : FitnessTheme.accent
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: statusSymbol(session.status))
                Text(compactMetric(metrics))
            }.font(.system(size: 9, weight: .semibold)).lineLimit(1)
                .foregroundStyle(FitnessTheme.accentInk).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2).padding(.vertical, 2).background(tint, in: RoundedRectangle(cornerRadius: 2))
            Text(session.name).font(.system(size: 10, weight: .medium)).foregroundStyle(FitnessTheme.ink)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.bottom, 1)
    }

    private func monthSummary(_ month: TrainingHistoryMonth) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("本月 \(month.sessions.count) 次记录").font(.subheadline.weight(.semibold))
            Spacer()
            NavigationLink { ReviewView(store: store) } label: {
                Label("复盘", systemImage: "doc.text.magnifyingglass").font(.subheadline)
            }.frame(minHeight: 44)
        }.foregroundStyle(FitnessTheme.ink).padding(.horizontal, 8)
    }

    private func dayRecords(_ month: TrainingHistoryMonth) -> some View {
        let selected = month.days.first { calendar.isDate($0.date, inSameDayAs: selectedDate) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(selectedDate.formatted(dayStyle))
                .font(.headline).padding(.horizontal, 6)
            if let selected, !selected.sessions.isEmpty {
                ForEach(selected.sessions) { session in
                    if session.status.isOngoing, let openWorkout {
                        Button { openWorkout(session.id) } label: { historyCard(session, ongoing: true) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink { SessionDetailView(session: session) } label: { historyCard(session, ongoing: false) }
                            .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("这一天还没有训练记录", systemImage: "calendar")
                        .font(.subheadline.weight(.semibold))
                    Text("完成或提前结束的训练会保存在对应日期；计划安排不会当作训练记录。")
                        .font(.footnote).foregroundStyle(FitnessTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                    .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            DisclosureGroup("记录口径") {
                Text("按训练开始时的本地日期归档，跨午夜仍属于开始那天。组数只计已完成正式组；日历 kg·次仅为标记总重量的力量动作重量×次数之和，热身、徒手、辅助重量和每只重量不混加。每只重量会在详情中单列，不推算双手。时长包含休息，扣除显式暂停。")
                    .font(.footnote).foregroundStyle(FitnessTheme.muted).padding(.top, 8)
            }.font(.subheadline).padding(14).background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
        }.padding(.horizontal, 4)
    }

    private func historyCard(_ session: WorkoutSession, ongoing: Bool) -> some View {
        let metrics = TrainingHistoryMetrics(session: session, at: now)
        return HStack(spacing: 12) {
            if let exercise = session.exercises.first?.exercise { ExerciseTile(exercise: exercise, size: 56) }
            else { FitnessIconBadge(symbol: "dumbbell", color: FitnessTheme.teal) }
            VStack(alignment: .leading, spacing: 6) {
                Text(session.name).font(.headline).foregroundStyle(FitnessTheme.ink)
                Label(session.status.title, systemImage: statusSymbol(session.status))
                    .font(.caption.weight(.medium)).foregroundStyle(session.status == .completed ? FitnessTheme.teal : FitnessTheme.orange)
                Text("\(metrics.completedWorkingSets) 组 · \(UIInput.duration(metrics.durationSeconds))")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(FitnessTheme.muted)
                if metrics.totalLoadRepetitionsKG > 0 {
                    Text("总重口径 \(UIInput.number(metrics.totalLoadRepetitionsKG)) kg·次")
                        .font(.caption).foregroundStyle(FitnessTheme.muted)
                }
                if metrics.perHandLoadRepetitionsKG > 0 {
                    Text("每只口径 \(UIInput.number(metrics.perHandLoadRepetitionsKG)) kg·次")
                        .font(.caption).foregroundStyle(FitnessTheme.muted)
                }
                Text(session.startedAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(FitnessTheme.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: ongoing ? "play.circle.fill" : "chevron.right").foregroundStyle(FitnessTheme.accent)
                .accessibilityHidden(true)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(FitnessTheme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func compactMetric(_ metrics: TrainingHistoryMetrics) -> String {
        if metrics.totalLoadRepetitionsKG > 0, metrics.perHandLoadRepetitionsKG == 0 {
            return UIInput.number(metrics.totalLoadRepetitionsKG)
        }
        return "\(metrics.completedWorkingSets)组"
    }

    private func statusSymbol(_ status: SessionStatus) -> String {
        switch status {
        case .completed: return "checkmark"
        case .endedEarly: return "flag"
        case .active: return "play.fill"
        case .paused: return "pause.fill"
        }
    }

    private func shiftMonth(_ offset: Int) {
        guard let month = calendar.dateInterval(of: .month, for: displayedDate),
              let next = calendar.date(byAdding: .month, value: offset, to: month.start) else { return }
        displayedDate = next
        selectedDate = next
    }
}
