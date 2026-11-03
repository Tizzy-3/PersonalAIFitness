import SwiftUI
import FitnessCore

/// Sets up a recurring day off — "every two weeks on Wednesday I have a TCM appointment".
///
/// Kept separate from the safety review on purpose. A recurring appointment is a calendar fact; the
/// safety review exists to convert a *physical restriction* into movement rules. Mixing them meant a
/// fortnightly appointment blocked plan generation behind a clinical confirmation flow.
struct RecurringRestDayView: View {
    let store: TrainingStore
    @Environment(\.dismiss) private var dismiss
    @State private var weekday = 3
    @State private var everyWeeks = 2
    @State private var anchor = Date()
    @State private var note = ""
    @State private var issue: String?
    @State private var clearsOldRestriction = false

    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        Form {
            Section {
                Text("用来登记「每两周的周三有事，不训练」这类固定安排。它只是占掉那一天，不改变任何动作或强度的安全判断。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("哪一天") {
                Picker("星期", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(weekdays[$0 - 1]).tag($0) }
                }
                Picker("重复", selection: $everyWeeks) {
                    Text("每周").tag(1)
                    Text("每 2 周").tag(2)
                    Text("每 3 周").tag(3)
                    Text("每 4 周").tag(4)
                }
            }
            Section {
                DatePicker("其中一次是哪天", selection: $anchor, displayedComponents: .date)
                Text("选定一个确实落在上面这个星期的日期，系统据此判断隔周的哪一天休息。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("起始日期")
            }
            Section("备注（可留空）") {
                TextField("例如：中医埋线", text: $note)
            }
            if let existing = store.oldRestrictionText, !existing.isEmpty {
                Section {
                    // The profile still quotes the old free-text limit, which blocks planning until
                    // it is resolved. This is where the person can retire it, and the appointment
                    // above replaces it as the concrete, schedulable fact.
                    Text("档案里记着一条旧的运动限制原文：「\(existing)」")
                        .font(.footnote)
                    Text("如果它说的就是这类固定安排（而不是伤病或医嘱），可以在这里换成上面的日历规则，之后不再阻塞制定计划。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("用上面的安排替换这条旧记录") { clearsOldRestriction = true }
                        .foregroundStyle(FitnessTheme.accent)
                } header: {
                    Text("旧的限制原文")
                }
            }
            if let existing = store.interview?.profile.constraintReview?.recurringRestDays,
               !existing.isEmpty {
                Section("已设置的重复休息日") {
                    ForEach(Array(existing.enumerated()), id: \.offset) { _, rule in
                        Text(rule.summary).font(.subheadline)
                    }
                }
            }
            Section {
                Button("保存", action: save).buttonStyle(FitnessPrimaryButtonStyle())
            }
        }
        .navigationTitle("重复休息日")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        .fitnessError($issue)
    }

    private func save() {
        do {
            let key = TrainingConstraintReview.dateKey(anchor)
            let rule = RecurringRestDay(weekday: weekday, everyWeeks: everyWeeks,
                                        anchorDateKey: key, note: note)
            try rule.validate()
            try store.saveRecurringRestDay(rule, clearingOldRestriction: clearsOldRestriction)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}
