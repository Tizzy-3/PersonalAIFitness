#if DEBUG
import Foundation
import FitnessCore

/// Opt-in screenshot fixture. Its SwiftData store is memory-only, isolated from the user's files.
/// The view keeps a visible validation label; Release excludes this fixture entirely.
@MainActor
enum HistoryValidationData {
    static let referenceDate = Date()

    static func makeStore() throws -> TrainingStore {
        let store = try TrainingStore(inMemory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let bench = store.allExercises.first(where: { $0.id == "builtin.barbell-bench-press" }),
              let row = store.allExercises.first(where: { $0.id == "builtin.dumbbell-row" }) else {
            throw CoreError.notFound("界面验证动作")
        }
        let today = calendar.component(.day, from: referenceDate)
        let days = [3, 5, 9, 12, 14, 17, 19, 21, 23, 26].filter { $0 < today } + [today]
        for (index, day) in days.enumerated() {
            var components = calendar.dateComponents([.year, .month], from: referenceDate)
            components.day = day
            components.hour = 18
            guard let earlier = calendar.date(from: components) else {
                throw CoreError.invalidInput("界面验证日期无效。")
            }
            let start = day == today ? referenceDate.addingTimeInterval(-3 * 3_600) : earlier
            let session = try store.startWorkout(at: start)
            try store.updateSession(id: session.id) { value in
                value.name = index.isMultiple(of: 2) ? "Day A · 上肢推" : "Day B · 背部力量"
                let exercise = index.isMultiple(of: 2) ? bench : row
                value.exercises = [WorkoutExercise(exercise: exercise, sets: (0..<3).map { set in
                    LoggedSet(loadKG: index.isMultiple(of: 2) ? 40 : 16, reps: 10,
                              completedAt: start.addingTimeInterval(Double(180 + set * 180)))
                })]
                try value.finish(early: index == 7, at: start.addingTimeInterval(30 * 60))
            }
        }
        let start = referenceDate.addingTimeInterval(-45 * 60)
        let active = try store.startWorkout(at: start)
        try store.updateSession(id: active.id) { value in
            value.name = "晚间补练 · 已暂停"
            value.exercises = [WorkoutExercise(exercise: bench, sets: [
                LoggedSet(loadKG: 30, reps: 8, completedAt: start.addingTimeInterval(180)), LoggedSet(loadKG: 30, reps: 8)
            ])]
            try value.pause(at: start.addingTimeInterval(12 * 60))
        }
        return store
    }
}
#endif
