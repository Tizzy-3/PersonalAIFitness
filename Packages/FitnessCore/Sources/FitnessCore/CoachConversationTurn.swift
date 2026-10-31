import Foundation

/// One conversational turn with the coach: what it said, and (optionally) what it is asking about.
///
/// Separate from `ConstraintChatCandidate` on purpose. The candidate is a *structured extraction*
/// that must be exact and is allowed to fail; this is just the coach talking, and a person must
/// always get an answer even when extraction later fails.
public struct CoachConversationTurn: Equatable, Sendable {
    /// Natural language addressed to the person. Never a JSON blob, never a field list.
    public var reply: String
    /// Short label for what this turn is asking about, e.g. "休息日". Empty when it asks nothing.
    public var topic: String

    public init(reply: String, topic: String = "") {
        self.reply = reply
        self.topic = topic
    }

    public func validate() throws {
        guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              reply.count <= 2_000 else {
            throw CoreError.invalidInput("教练回复为空或过长。")
        }
        guard topic.count <= 12 else { throw CoreError.invalidInput("话题标签过长。") }
    }
}
