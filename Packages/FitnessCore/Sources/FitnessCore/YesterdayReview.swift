import Foundation

/// What the coach opens with the next day, built from yesterday's real numbers.
///
/// This is the part of "拟人教练" that a dashboard cannot do: it refers to what actually happened,
/// notices how it felt, and — when the person says they do not want to train — pushes back once
/// with something concrete instead of immediately agreeing to skip.
///
/// Two rules hold throughout:
/// 1. Every sentence is built from a saved record. No invented progress, no invented fatigue.
/// 2. Encouragement never overrides safety. A reported pain or a confirmed restriction short-circuits
///    everything below, exactly as in `DailyCoachBrief`.
public struct YesterdayReview: Equatable, Sendable {
    /// What the coach says first, in its own voice.
    public var headline: String
    /// One or two supporting lines built from the numbers.
    public var details: [String]
    /// True when the person trained yesterday, so the follow-up can acknowledge the work.
    public var trainedYesterday: Bool
    /// How yesterday felt, when the person recorded it per movement. Drives the tone.
    public var feltHard: Bool
    /// A concrete reason to train today, used when the person wants to skip. Nil when there is no
    /// honest reason to give.
    public var encouragement: String?

    public init(headline: String, details: [String] = [], trainedYesterday: Bool,
                feltHard: Bool = false, encouragement: String? = nil) {
        self.headline = headline
        self.details = Array(details.prefix(2))
        self.trainedYesterday = trainedYesterday
        self.feltHard = feltHard
        self.encouragement = encouragement
    }

    public static func make(session: WorkoutSession?, feedback: SessionFeedback?,
                            calories: Int?, plan: PlanVersion?,
                            now: Date = Date(), calendar: Calendar = .current) -> YesterdayReview {
        guard let session else {
            return YesterdayReview(
                headline: "昨天没有训练记录。",
                details: ["不打紧，今天开始也算数。想练什么直接跟教练说。"],
                trainedYesterday: false,
                encouragement: plan != nil ? "今天有安排，按计划走一遍就够。" : nil)
        }
        let sets = session.completedWorkingSets
        let planned = session.plannedWorkingSets
        let minutes = max(1, Int((session.elapsed(at: session.endedAt ?? now) / 60).rounded()))
        var details: [String] = []
        details.append("完成 \(sets) / \(planned) 组，用时 \(minutes) 分钟"
                       + (calories.map { "，约 \($0) 千卡" } ?? "") + "。")

        // Per-movement feelings beat a single session score: they say *which* movement was hard.
        let hard = session.exercises.compactMap { exercise -> String? in
            guard let exertion = exercise.exertion, exertion >= 4 else { return nil }
            return exercise.exercise.name
        }
        let feltHard = !hard.isEmpty || feedback?.tooHard == true || (feedback?.perceivedExertion ?? 0) >= 8
        if !hard.isEmpty {
            details.append("\(hard.prefix(2).joined(separator: "、"))练得比较吃力。")
        } else if let note = session.exercises.compactMap(\.feelingNote).first(where: { !$0.isEmpty }) {
            details.append("你提到「\(note.prefix(40))」。")
        } else if sets == planned, planned > 0 {
            details.append("全部按计划完成。")
        } else if sets > 0 {
            details.append("没做完的部分不会补算，今天可以接着来。")
        }

        let headline: String
        if feedback?.painReported == true {
            headline = "昨天训练后你说了疼，今天先别硬上。"
        } else if feltHard {
            headline = "昨天练得挺重，今天我看情况安排。"
        } else if sets == 0 {
            headline = "昨天开始了但没完成组，今天重新来。"
        } else if planned > 0, sets >= planned {
            headline = "昨天那场你完整做完了。"
        } else {
            headline = "昨天练了 \(sets) 组，记下了。"
        }

        // A concrete, honest reason to train today. Never a guilt trip, never a fake number.
        var encouragement: String?
        if feedback?.painReported != true {
            if feltHard {
                encouragement = "今天可以轻一些，但别完全停——保持节奏比一次练狠更重要。"
            } else if let plan, let first = plan.items.first {
                encouragement = "今天安排是\(first.exercise.name)开场，先做 \(first.setCount) 组，做完再决定要不要加。"
            } else if plan != nil {
                encouragement = "今天按计划走一遍，二十分钟也算数。"
            }
        }
        return YesterdayReview(headline: headline, details: details, trainedYesterday: true,
                               feltHard: feltHard, encouragement: encouragement)
    }
}
