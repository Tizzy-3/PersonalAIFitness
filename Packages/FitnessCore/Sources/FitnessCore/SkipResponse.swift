import Foundation

/// What the coach says when the person wants to skip.
///
/// The requirement was explicit: do not let "I don't feel like it" quietly become a skipped day, but
/// also do not nag. So the response is one honest push with something concrete to do, plus an
/// accepted exit that is recorded rather than argued with.
///
/// The distinction that matters: *reluctance* gets encouragement, *pain* gets a rest day. Those are
/// different inputs and must not share an answer.
public enum SkipResponse {

    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// "tired", "no time", "can't be bothered" — no safety signal.
        case reluctance
        /// Explicit pain or illness.
        case pain
        /// A confirmed restriction or a professional instruction.
        case restriction
        /// The person already trained today.
        case alreadyTrained

        public var title: String {
            switch self {
            case .reluctance: return "不想练、没精神"
            case .pain: return "身体疼或不舒服"
            case .restriction: return "医生有限制"
            case .alreadyTrained: return "今天已经练过"
            }
        }
    }

    public struct Reply: Equatable, Sendable {
        public var message: String
        /// A smaller, still-useful version of today's plan, offered instead of "all or nothing".
        /// Nil when even this would be wrong (pain, restriction).
        public var smallerOption: String?
        /// True when the coach should stop pushing and accept the rest day.
        public var acceptsRest: Bool
    }

    /// Builds the answer. `plan` supplies the concrete numbers for the smaller option.
    public static func reply(to reason: Reason, plan: PlanVersion?,
                             yesterdayTrained: Bool = false) -> Reply {
        switch reason {
        case .pain:
            return Reply(
                message: "那就先别练。疼的时候休息是对的，不是偷懒。好一点再跟我说，我按你的状态重新安排。",
                smallerOption: nil,
                acceptsRest: true)

        case .restriction:
            return Reply(
                message: "有医生的话就按医生的来，我不会替你绕过去。等限制解除了，我们再排。",
                smallerOption: nil,
                acceptsRest: true)

        case .alreadyTrained:
            return Reply(
                message: "今天已经练过了，那就够了。休息本身就是训练的一部分。",
                smallerOption: nil,
                acceptsRest: true)

        case .reluctance:
            // One concrete push. The point is to make starting feel smaller, not to argue.
            if let plan, let first = plan.items.first {
                let sets = max(1, first.setCount - 1)
                let smaller = "只做\(first.exercise.name) \(sets) 组，做完想停就停。"
                return Reply(
                    message: yesterdayTrained
                        ? "昨天刚练过，今天累是正常的。但完全不动会更没劲——先动起来，感觉会不一样。"
                        : "不想练的时候，最难的往往是开始那五分钟。先做一点点，不用按原计划来。",
                    smallerOption: smaller,
                    acceptsRest: false)
            }
            return Reply(
                message: "那先动五分钟，随便做点什么。五分钟之后还不想练，今天就休息，我不勉强。",
                smallerOption: "五分钟后自己决定。",
                acceptsRest: false)
        }
    }

    /// Classifies a free-text reason. Only explicit pain and explicit professional instruction are
    /// treated as safety signals; everything else is reluctance. Deliberately conservative: guessing
    /// "pain" from vague text would hand out rest days the person did not ask for.
    public static func classify(_ text: String) -> Reason {
        let normalized = text.lowercased()
        let painWords = ["疼", "痛", "受伤", "拉伤", "扭到", "发烧", "生病", "不舒服", "头晕", "恶心"]
        if painWords.contains(where: { normalized.contains($0) }) { return .pain }
        let restrictionWords = ["医生", "医嘱", "术后", "康复", "不能动", "禁止"]
        if restrictionWords.contains(where: { normalized.contains($0) }) { return .restriction }
        return .reluctance
    }
}
