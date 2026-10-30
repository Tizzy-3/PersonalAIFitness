import SwiftUI
import FitnessCore

/// The frozen, user-confirmed boundaries that this particular plan actually uses.
struct PlanningConstraintSummary: View {
    let review: TrainingConstraintReview

    var body: some View {
        Section("这份计划遵守的限制") {
            Text(review.sourceText).textSelection(.enabled)
            if !review.legacySourceText.isEmpty, review.legacySourceText != review.sourceText {
                Text("原个人档案：\(review.legacySourceText)").font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("核对方式", value: review.mode.title)
            if let deferred = review.deferredClinicalQuestions, !deferred.isEmpty {
                Text("以下未明确事项仅限所选休息时段，仍保留待确认；这些时段不安排训练。")
                    .font(.footnote).foregroundStyle(.secondary)
                ForEach(Array(deferred.enumerated()), id: \.offset) { _, text in Text(text).font(.footnote) }
            }
            if let activity = review.temporaryActivity {
                LabeledContent("当天轻活动", value: activity.dateKey)
                Text("仅影响这个日期，开始前核对当天身体状态。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !review.excludedWeekdays.isEmpty {
                LabeledContent("每周休息", value: review.excludedWeekdays.map(PlanningDisplay.weekday).joined(separator: "、"))
            }
            if !review.restDateKeys.isEmpty {
                LabeledContent("日期休息例外", value: review.restDateKeys.joined(separator: "、"))
                Text("这些日期优先按休息处理，不因当天通常是训练日而恢复训练；其他星期的重复安排保持。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !review.avoidedPositions.isEmpty {
                LabeledContent("避开姿势", value: review.avoidedPositions.map { $0 == .kneeling ? "跪姿" : "地面动作" }.joined(separator: "、"))
            }
            if !review.excludedExerciseIDs.isEmpty {
                LabeledContent("排除动作", value: names(review.excludedExerciseIDs))
            }
            if let allowed = review.allowedExerciseIDs {
                LabeledContent("只在这些动作内安排", value: names(allowed))
            }
            if let limit = review.maxSessionMinutes { LabeledContent("单次上限", value: "\(limit) 分钟") }
            if !review.professionalGuidanceNote.isEmpty {
                Text("本人记录的指导：\(review.professionalGuidanceNote)").font(.footnote)
            }
            Text("核对时间：\(review.confirmedAt.formatted(date: .abbreviated, time: .shortened)) · 规则 \(review.rulesVersion)")
                .font(.caption).foregroundStyle(.secondary)
            Text("这是本版本冻结的边界。修改档案不会暗中改动已经确认的计划，需要重新生成并由你确认。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func names(_ ids: [String]) -> String {
        ids.map { ExerciseCatalog.exercise(id: $0)?.name ?? "未知动作" }.joined(separator: "、")
    }
}
