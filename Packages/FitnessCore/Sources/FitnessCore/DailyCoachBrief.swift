import Foundation

/// What the coach says on the home screen today. This is deliberately a *presentation* of facts the
/// local rules already decided — it never invents a training instruction, a medical permission or a
/// readiness score that the engines did not produce.
///
/// Three sources feed it, in strict priority order:
/// 1. Safety. A reported pain or a recorded restriction outranks any plan or encouragement.
/// 2. The confirmed plan for today (or the documented reason there isn't one).
/// 3. What actually happened last time, to give the day a reference point.
public struct DailyCoachBrief: Equatable, Sendable {
    /// Tones are `let` on purpose: tests compare them as strings, and a change of meaning should
    /// require a code change rather than a stored string.
    public enum Tone: String, Equatable, Sendable {
        case welcome, plan, rest, caution, safety, done

        /// Only these tones may use encouraging language; a caution or safety brief never does.
        public var allowsEncouragement: Bool {
            switch self {
            case .plan, .done: return true
            case .welcome, .rest, .caution, .safety: return false
            }
        }

        /// SF Symbol shown next to the sentence; purely presentational.
        public var symbol: String {
            switch self {
            case .welcome: return "person.text.rectangle"
            case .plan: return "figure.strengthtraining.traditional"
            case .rest: return "moon.zzz"
            case .caution: return "exclamationmark.triangle"
            case .safety: return "cross.case"
            case .done: return "checkmark.seal"
            }
        }
    }

    /// One short sentence in the coach's own voice. Never a diagnosis and never a plan change.
    public var headline: String
    /// At most two supporting lines: what it is based on, and what the person could do next.
    public var details: [String]
    public var tone: Tone
    /// Facts this sentence is built from, so the person can check it instead of trusting it.
    public var evidence: [String]
    /// True when the brief was built without a reported pain answer — the caller must ask, not assume.
    public var needsPainAnswer: Bool

    public init(headline: String, details: [String] = [], tone: Tone,
                evidence: [String] = [], needsPainAnswer: Bool = false) {
        self.headline = headline
        self.details = Array(details.prefix(2))
        self.tone = tone
        self.evidence = evidence
        self.needsPainAnswer = needsPainAnswer
    }

    /// Builds today's brief. `plan` is the plan actually scheduled for today by the confirmed weekly
    /// program; passing `nil` while `hasWeeklyProgram` is true means the schedule itself says rest.
    public static func make(now: Date = Date(),
                            checkIn: PreWorkoutCheckIn?,
                            profileRestrictions: String?,
                            plan: PlanVersion?,
                            hasWeeklyProgram: Bool,
                            isConstraintRestDay: Bool,
                            activeSession: WorkoutSession?,
                            lastFinishedSession: WorkoutSession?,
                            lastFeedback: SessionFeedback?,
                            completedToday: SessionFeedback?,
                            calendar: Calendar = .current) -> DailyCoachBrief {
        // 1) Safety outranks everything, including a completed workout.
        let todayCheckIn = checkIn.flatMap { calendar.isDate($0.createdAt, inSameDayAs: now) ? $0 : nil }
        if let todayCheckIn, todayCheckIn.painReported == true {
            let areas = todayCheckIn.painAreas.isEmpty ? "" : "（\(todayCheckIn.painAreas.joined(separator: "、"))）"
            return DailyCoachBrief(
                headline: "今天先别急着按计划练。",
                details: ["你记录了疼痛\(areas)，这一条比任何训练安排都优先。",
                          "先休息或改做不加重症状的活动，必要时找专业人士看看。"],
                tone: .safety,
                evidence: ["训练前记录：" + summary(todayCheckIn)],
                needsPainAnswer: false)
        }
        if let profileRestrictions, isRealRestriction(profileRestrictions) {
            return DailyCoachBrief(
                headline: "档案里有运动限制，我不替你绕过它。",
                details: ["本版没有医学限制的个体适配能力，不会因为今天状态好就放行。",
                          "按专业建议安排；可以到“教练”里把限制补得更具体。"],
                tone: .safety,
                evidence: ["档案：运动限制已确认"],
                needsPainAnswer: false)
        }

        // 2) A workout already finished today — say so before anything else.
        if let completedToday {
            let sets = completedToday.completedWorkingSets
            var details = ["完成 \(sets) 组，用时 \(duration(completedToday.totalSeconds))。"]
            if completedToday.painReported == true {
                details.append("训练后你报告了疼痛，先观察，下次训练前我会重新问当天状态。")
            } else if completedToday.tooHard == true {
                details.append("这次比预期更吃力，下次会按保守量推进，不急于加量。")
            } else if completedToday.perceivedExertion.map({ $0 <= 6 }) ?? false {
                details.append("这次留有余力，记录真实重量后才有加量的依据。")
            } else {
                details.append("今天的部分已经完成，剩下的交给休息。")
            }
            return DailyCoachBrief(
                headline: "今天的训练已经记下了。",
                details: Array(details.prefix(2)),
                tone: .done,
                evidence: ["训练后反馈 \(completedToday.createdAt.formatted(date: .omitted, time: .shortened))"],
                needsPainAnswer: false)
        }

        // 3) A workout is running right now.
        if let activeSession {
            return DailyCoachBrief(
                headline: activeSession.status == .paused ? "有一次训练还停在这里。" : "正在训练中。",
                details: ["已完成 \(activeSession.completedWorkingSets) / \(activeSession.plannedWorkingSets) 正式组。",
                          "回到训练页继续，记录会原样保留。"],
                tone: .plan,
                evidence: ["进行中的训练：\(activeSession.name)"],
                needsPainAnswer: false)
        }

        let painUnknown = todayCheckIn?.painReported == nil
        var evidence: [String] = []
        if let todayCheckIn { evidence.append("训练前记录：" + summary(todayCheckIn)) }

        // 4) No plan at all yet — the honest first-run message.
        guard hasWeeklyProgram || plan != nil else {
            return DailyCoachBrief(
                headline: "先让我知道你的情况，再一起定计划。",
                details: ["告诉我目标、能练的时间和器械，我问几个问题就够了。",
                          "没有计划也可以先自由训练，我会记录你实际做了什么。"],
                tone: .welcome,
                evidence: ["还没有生效的训练计划"],
                needsPainAnswer: painUnknown)
        }

        // 5) The schedule says rest.
        if plan == nil {
            let reason = isConstraintRestDay ? "这一天是你在注意事项里明确排除的休息日。" : "按周计划，今天是休息日。"
            return DailyCoachBrief(
                headline: "今天休息。",
                details: [reason, "休息也是安排的一部分；想动一动可以自由训练，但不计入原计划。"],
                tone: .rest,
                evidence: evidence + ["周计划：今天无训练安排"],
                needsPainAnswer: painUnknown)
        }

        guard let plan else {
            return DailyCoachBrief(headline: "今天休息。", details: [], tone: .rest, needsPainAnswer: painUnknown)
        }
        let minutes = estimatedMinutes(plan)
        evidence.append("今日计划：\(plan.name) v\(plan.version)，\(plan.items.count) 个动作")
        let summaryLine = "\(plan.items.count) 个动作 · \(plan.items.reduce(0) { $0 + $1.setCount }) 组 · 约 \(minutes) 分钟"

        // 6) Plan exists, but today's pain answer is missing: do not present it as cleared.
        if painUnknown {
            return DailyCoachBrief(
                headline: "开始之前，先说一下今天的状态。",
                details: ["今天的疼痛情况还没回答，我不会替你当成“没问题”。",
                          "记一下要 30 秒，然后就能按计划开始。"],
                tone: .caution,
                evidence: evidence,
                needsPainAnswer: true)
        }

        // 7) Reference point from last time.
        let reference = lastTimeLine(plan: plan, lastFinished: lastFinishedSession, feedback: lastFeedback)
        var details = [summaryLine]
        if let reference { details.append(reference) }
        let lowEnergy = todayCheckIn?.energy.map { $0 <= 2 } ?? false
        let limited = todayCheckIn?.availableMinutes.map { $0 < minutes } ?? false
        if lowEnergy || limited {
            return DailyCoachBrief(
                headline: "今天的安排放轻一点更合适。",
                details: [summaryLine, limited
                          ? "你说今天只有 \(todayCheckIn?.availableMinutes ?? 0) 分钟，比计划短；可以点下面的“今天少一点”看缩短方案。"
                          : "你说今天精力偏低；可以点“今天少一点”看减量方案，确认后才生效。"],
                tone: .caution,
                evidence: evidence,
                needsPainAnswer: false)
        }
        return DailyCoachBrief(
            headline: "今天练\(plan.name)。",
            details: details,
            tone: .plan,
            evidence: evidence,
            needsPainAnswer: false)
    }

    // MARK: - Helpers

    /// The five strings the rest of the app already treats as "no restriction". Anything else is a
    /// real, person-confirmed limit and must not be planned around automatically.
    static func isRealRestriction(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty { return false }
        return !Set(["无", "无已知限制", "无运动限制", "没有已知限制", "none"]).contains(normalized)
    }

    static func estimatedMinutes(_ plan: PlanVersion) -> Int {
        let items = plan.items.map {
            PlanningItem(exerciseID: $0.exercise.id, setCount: $0.setCount, targetReps: $0.targetReps,
                         targetSeconds: $0.targetSeconds, restSeconds: $0.restSeconds, notes: [])
        }
        return PlannerEngine.timeRange(items: items).upper
    }

    /// Only states what was recorded. Never claims a weight was good or bad without a real load.
    private static func lastTimeLine(plan: PlanVersion, lastFinished: WorkoutSession?,
                                     feedback: SessionFeedback?) -> String? {
        guard let lastFinished else { return nil }
        let samePlan = lastFinished.sourcePlanVersionID.flatMap { $0 == plan.id } ?? false
        if feedback?.painReported == true {
            return "上次训练后你报告过疼痛，今天从能控制的量开始。"
        }
        if feedback?.tooHard == true {
            return "上次你说比预期更吃力，那次完成 \(lastFinished.completedWorkingSets) 组。"
        }
        let sets = lastFinished.completedWorkingSets
        if sets == 0 { return "上一次训练没有完成的正式组，这次从轻量开始找感觉。" }
        let minutes = Int((lastFinished.elapsed(at: lastFinished.endedAt ?? lastFinished.startedAt) / 60).rounded())
        return (samePlan ? "上次同一个安排" : "上次训练") + "完成 \(sets) 组，用时约 \(max(1, minutes)) 分钟。"
    }

    static func summary(_ checkIn: PreWorkoutCheckIn) -> String {
        var parts: [String] = []
        if let energy = checkIn.energy { parts.append("精力 \(energy)/5") } else { parts.append("精力未答") }
        if let pain = checkIn.painReported { parts.append(pain ? "有疼痛" : "无疼痛") } else { parts.append("疼痛未答") }
        if let level = checkIn.sorenessLevel { parts.append("酸痛 \(level)/5") }
        if let minutes = checkIn.availableMinutes { parts.append("可用 \(minutes) 分钟") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 10_000_000 else { return "时长未知" }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = total / 60 % 60
        return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(max(1, minutes)) 分钟"
    }
}

/// The coach's one spoken reaction right after a workout is saved. It reports what was recorded and
/// what that means for the next session — it never praises a weight, never claims progression and
/// never softens a reported pain into a success message.
public struct SessionCoachReply: Equatable, Sendable {
    public var headline: String
    public var details: [String]
    /// True when the reply is about pain and the caller should not style it as an achievement.
    public var isSafetyConcern: Bool

    public init(headline: String, details: [String] = [], isSafetyConcern: Bool = false) {
        self.headline = headline
        self.details = Array(details.prefix(2))
        self.isSafetyConcern = isSafetyConcern
    }

    public static func make(feedback: SessionFeedback, session: WorkoutSession) -> SessionCoachReply {
        let sets = session.completedWorkingSets
        let planned = session.plannedWorkingSets
        if feedback.painReported == true {
            let areas = feedback.painAreas.isEmpty ? "" : "（\(feedback.painAreas.joined(separator: "、"))）"
            return SessionCoachReply(
                headline: "你报告了疼痛\(areas)，我记下了。",
                details: ["先观察这个部位，下一次训练前我会重新问当天状态。",
                          "是否继续同强度训练，以你自己和专业意见为准，我不会替你判断。"],
                isSafetyConcern: true)
        }
        if feedback.tooHard == true || (feedback.perceivedExertion ?? 0) >= 9 {
            return SessionCoachReply(
                headline: "这次偏吃力，我记下了。",
                details: ["下次先按同样的量走，连续稳定后再谈加量。",
                          "如果同样的量反复这么难，我会建议减一组，由你确认。"])
        }
        if sets == 0 {
            return SessionCoachReply(
                headline: "这次没有完成的正式组。",
                details: ["没有完成也是真实记录，不会被当成做了。",
                          "下次可以先做少量、能控制的动作找回感觉。"])
        }
        let progressLine = planned > 0
            ? "完成 \(sets) / \(planned) 个正式组。"
            : "完成 \(sets) 个正式组。"
        var details = [progressLine]
        if feedback.perceivedExertion.map({ $0 <= 6 }) ?? false {
            details.append("你说这次还有余力；等连续几次都稳定，再讨论往上加，现在先按原量。")
        } else if feedback.perceivedExertion == nil {
            details.append("这次没有填主观感受，下次填一下，我才能判断该不该变。")
        } else {
            details.append("强度合适就先保持原量，连续稳定的记录才有加量的依据。")
        }
        return SessionCoachReply(headline: "今天的训练结束了，休息好。", details: details)
    }
}
