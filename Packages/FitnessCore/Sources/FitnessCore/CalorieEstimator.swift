import Foundation

/// Calorie estimates for a planned or logged exercise.
///
/// This is deliberately an *estimate* and says so everywhere it is displayed. The method is the
/// standard MET formula — kcal = MET × weight(kg) × hours — which is what consumer apps and exercise
/// equipment use. It cannot know the person's actual effort, muscle mass, rest posture or
/// efficiency, so a real session will differ, often by 20% or more.
///
/// Two honesty rules shape the API:
/// 1. A missing body weight produces no number at all, rather than a default-person guess.
/// 2. Recovery time between sets is only partially counted: the MET value already assumes
///    continuous effort, so counting rest minutes at a full working MET would inflate the total.
public enum CalorieEstimator {

    public static let rulesVersion = "calories-1"

    /// MET values, keyed by training kind. These are broad activity categories from the Compendium
    /// of Physical Activities, not per-exercise measurements — the catalogue does not carry
    /// per-movement metabolic data, and inventing one per movement would be false precision.
    ///
    /// - strength: 5.0 — "resistance training, multiple exercises, 8-15 reps", moderate effort.
    /// - bodyweight: 4.0 — calisthenics at a controlled pace, lighter than loaded strength work.
    /// - cardio: 7.0 — moderate cardiovascular effort (walking briskly / cycling at a steady pace).
    static let metByKind: [TrainingKind: Double] = [
        .strength: 5.0,
        .bodyweight: 4.0,
        .cardio: 7.0
    ]

    /// Rest minutes are counted at this fraction of the working MET: standing or sitting between
    /// sets is above resting but far below the movement itself.
    static let restMetFraction = 0.35

    /// Body weight used when the profile has one. Returns nil when unknown — the caller must then
    /// show nothing rather than a fabricated figure.
    public static func bodyWeightKG(_ profile: StructuredProfile) -> Double? {
        guard profile.weightKG.isUsable, let value = profile.weightKG.value,
              value >= 20, value <= 400 else { return nil }
        return value
    }

    /// Estimate for one planned exercise.
    ///
    /// - Parameters:
    ///   - exercise: the movement, whose `kind` selects the MET category.
    ///   - sets: how many working sets.
    ///   - targetReps: reps per set, for repetition-based movements.
    ///   - targetSeconds: work seconds per set, for timed movements.
    ///   - restSeconds: rest between sets.
    ///   - weightKG: the person's body weight. Nil yields nil.
    public static func estimate(exercise: Exercise, sets: Int, targetReps: Int?,
                                targetSeconds: Double?, restSeconds: Double,
                                weightKG: Double?) -> Int? {
        guard let weightKG, weightKG > 0 else { return nil }
        guard sets > 0 else { return nil }
        let met = metByKind[exercise.kind] ?? 5.0

        // Work time per set. A rep is assumed to take 4 seconds of movement — a deliberate average
        // across tempo styles; it is stated here rather than hidden in a formula.
        let workPerSet: Double
        if let targetSeconds {
            workPerSet = targetSeconds
        } else if let targetReps {
            workPerSet = Double(targetReps) * secondsPerRep
        } else {
            return nil   // unknown target: no honest number exists
        }
        guard workPerSet > 0, workPerSet <= 7_200 else { return nil }

        let workMinutes = Double(sets) * workPerSet / 60
        let restMinutes = Double(max(0, sets - 1)) * max(0, restSeconds) / 60

        let kcal = met * weightKG * (workMinutes + restMinutes * restMetFraction) / 60
        guard kcal.isFinite, kcal >= 0 else { return nil }
        // Rounded to the nearest 5: a single-kcal figure would claim precision this method lacks.
        return max(5, Int((kcal / 5).rounded()) * 5)
    }

    /// Seconds of movement assumed per repetition.
    static let secondsPerRep = 4.0

    /// Estimate for a whole plan version.
    public static func estimate(plan: PlanVersion, weightKG: Double?) -> Int? {
        guard let weightKG else { return nil }
        var total = 0
        var any = false
        for item in plan.items {
            if let value = estimate(exercise: item.exercise, sets: item.setCount,
                                    targetReps: item.targetReps, targetSeconds: item.targetSeconds,
                                    restSeconds: item.restSeconds, weightKG: weightKG) {
                total += value
                any = true
            }
        }
        return any ? total : nil
    }

    /// Estimate for a session that was actually performed, using the sets that were completed.
    public static func estimate(session: WorkoutSession, weightKG: Double?) -> Int? {
        guard let weightKG else { return nil }
        var total = 0
        var any = false
        for exercise in session.exercises where !exercise.skipped {
            let completed = exercise.sets.filter { $0.kind == .working && $0.isCompleted }
            guard !completed.isEmpty else { continue }
            // Use what was actually done where it was recorded, and the target where it was not.
            let reps = completed.compactMap(\.reps).max() ?? 0
            let seconds = completed.compactMap(\.durationSeconds).max() ?? 0
            if let value = estimate(exercise: exercise.exercise, sets: completed.count,
                                    targetReps: reps > 0 ? reps : nil,
                                    targetSeconds: seconds > 0 ? seconds : nil,
                                    restSeconds: exercise.restSeconds, weightKG: weightKG) {
                total += value
                any = true
            }
        }
        return any ? total : nil
    }

    /// A one-line explanation shown next to every calorie figure, so the number never appears
    /// without its limits.
    public static var disclaimer: String {
        "按体重与训练时长的常规估算，不是实测；实际消耗会因强度、动作效率和休息而不同。"
    }
}
