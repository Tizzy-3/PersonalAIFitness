import Foundation

public enum CoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case invalidState(String)
    case notFound(String)
    case unsupportedFormat(Int)
    case duplicateIdentifier(String)
    case missingReference(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .invalidState(let message): return message
        case .notFound(let name): return "找不到\(name)，请重新打开后再试。"
        case .unsupportedFormat(let version): return "不支持备份格式 \(version)，请使用兼容版本的 App。"
        case .duplicateIdentifier(let name): return "数据中有重复的\(name)，未执行导入。"
        case .missingReference(let name): return "数据缺少关联的\(name)，未执行导入。"
        }
    }
}

public enum TrainingKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case strength, cardio, bodyweight
    public var title: String {
        switch self { case .strength: return "力量"; case .cardio: return "有氧"; case .bodyweight: return "徒手" }
    }
}

public enum RecordingMetric: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case repetitions, duration, cardio
    public var title: String {
        switch self { case .repetitions: return "次数"; case .duration: return "持续时间"; case .cardio: return "时间与距离" }
    }
}

public enum LoadConvention: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case total, perHand, bodyweight, assistance
    public var title: String {
        switch self { case .total: return "总重量"; case .perHand: return "每只重量"; case .bodyweight: return "自身体重"; case .assistance: return "辅助重量" }
    }
}

public enum SetKind: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case warmup, working
    public var title: String { self == .warmup ? "热身组" : "正式组" }
}

public enum SessionStatus: String, Codable, Equatable, Hashable, Sendable {
    case active, paused, completed, endedEarly
    public var isOngoing: Bool { self == .active || self == .paused }
    public var title: String {
        switch self { case .active: return "进行中"; case .paused: return "已暂停"; case .completed: return "已完成"; case .endedEarly: return "提前结束" }
    }
}

enum CoreValidation {
    static func nonempty(_ text: String, name: String, maxLength: Int = 200) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalidInput("请填写\(name)。")
        }
        guard text.count <= maxLength else { throw CoreError.invalidInput("\(name)过长，请缩短后再保存。") }
    }

    static func finite(_ value: Double, name: String, minimum: Double = 0, strictlyPositive: Bool = false) throws {
        guard value.isFinite, value >= minimum, !strictlyPositive || value > 0 else {
            throw CoreError.invalidInput("\(name)必须是\(strictlyPositive ? "大于零的" : "非负")有效数字。")
        }
    }

    static func date(_ date: Date, name: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              (Date.distantPast...Date.distantFuture).contains(date) else {
            throw CoreError.invalidInput("\(name)无效或超出支持范围。")
        }
    }

    static func unique<T: Hashable>(_ values: [T], name: String) throws {
        guard Set(values).count == values.count else { throw CoreError.duplicateIdentifier(name) }
    }
}

public struct Exercise: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var englishName: String
    public var kind: TrainingKind
    public var metric: RecordingMetric
    public var equipment: String
    public var muscle: String
    public var loadConvention: LoadConvention
    public var isCustom: Bool
    public var instructions: [String]

    public init(id: String, name: String, englishName: String, kind: TrainingKind,
                metric: RecordingMetric, equipment: String, muscle: String,
                loadConvention: LoadConvention, isCustom: Bool = false, instructions: [String] = []) {
        self.id = id; self.name = name; self.englishName = englishName; self.kind = kind
        self.metric = metric; self.equipment = equipment; self.muscle = muscle
        self.loadConvention = loadConvention; self.isCustom = isCustom; self.instructions = instructions
    }

    public func validate() throws {
        try CoreValidation.nonempty(id, name: "动作 ID", maxLength: 160)
        try CoreValidation.nonempty(name, name: "动作名称", maxLength: 100)
        guard englishName.count <= 160, equipment.count <= 200, muscle.count <= 200,
              instructions.count <= 100, instructions.allSatisfy({ $0.count <= 4_000 }) else {
            throw CoreError.invalidInput("动作说明过长。")
        }
        if kind == .cardio && metric != .cardio && metric != .duration {
            throw CoreError.invalidInput("有氧动作应使用时间或时间与距离记录。")
        }
    }
}

public struct PersonalProfile: Codable, Equatable, Sendable {
    public var birthYear: Int?
    public var heightCM: Double?
    public var weightKG: Double?
    public var goal: String
    public var experience: String
    public var weeklyDays: Int?
    public var minutesPerSession: Int?
    public var equipmentNotes: String
    public var restrictions: String

    public init() {
        birthYear = nil; heightCM = nil; weightKG = nil; weeklyDays = nil; minutesPerSession = nil
        goal = ""; experience = ""; equipmentNotes = ""; restrictions = ""
    }

    public func validate() throws {
        if let birthYear {
            guard birthYear >= 1900 && birthYear <= Calendar(identifier: .gregorian).component(.year, from: Date()) else {
                throw CoreError.invalidInput("出生年份超出可录入范围。")
            }
        }
        if let heightCM { try CoreValidation.finite(heightCM, name: "身高", strictlyPositive: true) }
        if let weightKG { try CoreValidation.finite(weightKG, name: "体重", strictlyPositive: true) }
        if let weeklyDays, !(0...7).contains(weeklyDays) { throw CoreError.invalidInput("每周训练天数应在 0 至 7 之间。") }
        if let minutesPerSession, !(1...1_440).contains(minutesPerSession) { throw CoreError.invalidInput("单次训练分钟数应在 1 至 1440 之间。") }
        guard goal.count <= 1_000, experience.count <= 1_000,
              equipmentNotes.count <= 10_000, restrictions.count <= 10_000 else {
            throw CoreError.invalidInput("档案文字过长，请缩短后保存。")
        }
    }
}
