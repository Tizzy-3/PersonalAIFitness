import Foundation

/// The user's own words, preserved without silently converting them into confirmed enum fields.
public struct InterviewNarrative: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var recordedAt: Date
    public init(id: UUID = UUID(), text: String, recordedAt: Date = Date()) {
        self.id = id; self.text = text; self.recordedAt = recordedAt
    }
    public func validate() throws {
        try CoreValidation.nonempty(text, name: "本人叙述", maxLength: 6_000)
        try CoreValidation.date(recordedAt, name: "叙述时间")
    }
}

/// Explicitly user-backed dialogue evidence. These words are not medical findings or confirmed
/// structured facts; a model may use them for explanation, but cannot overwrite safety inputs.
public struct InterviewDialogueEvidence: Codable, Equatable, Sendable {
    public var topic: InterviewTopic
    public var detailKey: String?
    public var prompt: String
    public var answer: InterviewAnswer
    public init(topic: InterviewTopic, detailKey: String?, prompt: String, answer: InterviewAnswer) {
        self.topic = topic; self.detailKey = detailKey; self.prompt = prompt; self.answer = answer
    }
}
