import Foundation

/// How much of a question the user actually answered. `unanswered` is its own outcome and must never
/// be read as "fine" or "no pain".
public enum FeedbackAnswerState: String, Codable, Equatable, Sendable {
    case answered, unanswered, declined

    public var title: String {
        switch self {
        case .answered: return "已回答"
        case .unanswered: return "未回答"
        case .declined: return "选择不答"
        }
    }
}

/// What the user reports before training. All fields are optional on purpose: a missing answer stays
/// missing and the readiness engine has to say so.
public struct PreWorkoutCheckIn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// 1 = exhausted, 5 = fresh. `nil` means not answered.
    public var energy: Int?
    public var sorenessAreas: [String]
    public var sorenessLevel: Int?
    public var painReported: Bool?
    public var painAreas: [String]
    public var availableMinutes: Int?
    public var note: String

    public init(id: UUID = UUID(), createdAt: Date = Date(), energy: Int? = nil,
                sorenessAreas: [String] = [], sorenessLevel: Int? = nil,
                painReported: Bool? = nil, painAreas: [String] = [],
                availableMinutes: Int? = nil, note: String = "") {
        self.id = id; self.createdAt = createdAt; self.energy = energy
        self.sorenessAreas = sorenessAreas; self.sorenessLevel = sorenessLevel
        self.painReported = painReported; self.painAreas = painAreas
        self.availableMinutes = availableMinutes; self.note = note
    }

    public var energyState: FeedbackAnswerState { energy == nil ? .unanswered : .answered }
    public var painState: FeedbackAnswerState { painReported == nil ? .unanswered : .answered }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "训练前记录时间")
        if let energy, !(1...5).contains(energy) { throw CoreError.invalidInput("精力评分应在 1 至 5 之间。") }
        if let sorenessLevel, !(1...5).contains(sorenessLevel) { throw CoreError.invalidInput("酸痛程度应在 1 至 5 之间。") }
        if let availableMinutes, !(5...300).contains(availableMinutes) {
            throw CoreError.invalidInput("可用时间应在 5 至 300 分钟之间。")
        }
        guard sorenessAreas.count <= 10, painAreas.count <= 10,
              sorenessAreas.allSatisfy({ $0.count <= 100 }), painAreas.allSatisfy({ $0.count <= 100 }),
              note.count <= 2_000 else { throw CoreError.invalidInput("训练前记录内容超出支持范围。") }
        if painReported == false, !painAreas.isEmpty {
            throw CoreError.invalidInput("已说明没有疼痛，却又记录了疼痛部位。")
        }
    }
}

/// What the user reports after training. The objective part is computed by the app; only the
/// subjective part comes from the user.
public struct SessionFeedback: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    /// Computed from the saved session, never typed by the user or the model.
    public var completedWorkingSets: Int
    public var totalSeconds: Double
    public var perceivedExertion: Int?
    public var tooHard: Bool?
    public var painReported: Bool?
    public var painAreas: [String]
    public var barrierNote: String

    public init(id: UUID = UUID(), sessionID: UUID, createdAt: Date = Date(),
                completedWorkingSets: Int = 0, totalSeconds: Double = 0,
                perceivedExertion: Int? = nil, tooHard: Bool? = nil,
                painReported: Bool? = nil, painAreas: [String] = [], barrierNote: String = "") {
        self.id = id; self.sessionID = sessionID; self.createdAt = createdAt
        self.completedWorkingSets = completedWorkingSets; self.totalSeconds = totalSeconds
        self.perceivedExertion = perceivedExertion; self.tooHard = tooHard
        self.painReported = painReported; self.painAreas = painAreas
        self.barrierNote = barrierNote
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "训练后记录时间")
        guard completedWorkingSets >= 0, completedWorkingSets <= 10_000 else {
            throw CoreError.invalidInput("完成组数无效。")
        }
        try CoreValidation.finite(totalSeconds, name: "训练时长")
        if let perceivedExertion, !(1...10).contains(perceivedExertion) {
            throw CoreError.invalidInput("主观用力应在 1 至 10 之间。")
        }
        guard painAreas.count <= 10, painAreas.allSatisfy({ $0.count <= 100 }),
              barrierNote.count <= 2_000 else { throw CoreError.invalidInput("训练后记录内容超出支持范围。") }
        if painReported == false, !painAreas.isEmpty {
            throw CoreError.invalidInput("已说明没有疼痛，却又记录了疼痛部位。")
        }
    }
}
