import Foundation
import FitnessCore

/// One line in the coach conversation. Built from `CoachTurn`, which already stores a question and
/// its answer together, so the conversation can be shown without any new persisted type.
struct CoachConversationLine: Identifiable, Equatable {
    let id: String
    let text: String
    let isCoach: Bool
    let createdAt: Date
}

extension TrainingStore {
    /// The conversation, oldest first: each saved turn expands into the person's message and the
    /// coach's reply. A `CoachTurn` is written only once both halves exist, so the two can never
    /// disagree about what was said.
    var conversationLines: [CoachConversationLine] {
        coachTurns
            .sorted { $0.createdAt < $1.createdAt }
            .flatMap { turn -> [CoachConversationLine] in
                [
                    CoachConversationLine(id: "\(turn.id)-q", text: turn.question,
                                          isCoach: false, createdAt: turn.createdAt),
                    CoachConversationLine(id: "\(turn.id)-a", text: turn.reply.answer,
                                          isCoach: true, createdAt: turn.createdAt)
                ]
            }
    }
}
