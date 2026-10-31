import Foundation

/// Quantities are computed here. Model text is never a statistics source.
public struct CoachStatistics: Codable, Equatable, Sendable {
    public var completedSessions: Int
    public var completedSets: Int
    public var totalTrainingSeconds: Double
    public var lookbackDays: Int = 28

    public init(completedSessions: Int, completedSets: Int, totalTrainingSeconds: Double) {
        self.completedSessions = completedSessions; self.completedSets = completedSets
        self.totalTrainingSeconds = totalTrainingSeconds
    }
}

public struct CoachContext: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var profile: PersonalProfile
    public var plan: PlanVersion?
    public var recentSessions: [WorkoutSession]
    public var sessionRevisions: [String: Int]
    public var statistics: CoachStatistics
    public var rulesVersion: String = "coach-reduction-1"
    public var movementKnowledge: [CoachMovementKnowledge]? = nil
    public var weeklyPlan: WeeklyPlanOption? = nil
    public var weeklyProgramID: UUID? = nil
    public var followUp: CoachFollowUpContext? = nil

    public var evidenceIDs: [String] {
        var ids = ["profile", "statistics"]
        if plan != nil { ids.append("plan") }
        ids.append(contentsOf: recentSessions.map { "session:\($0.id.uuidString)" })
        ids.append(contentsOf: (movementKnowledge ?? []).map { "exercise:\($0.exercise.id)" })
        if weeklyProgramID != nil { ids.append("weekly-plan") }
        ids.append(contentsOf: followUp?.evidenceIDs ?? [])
        return Array(Set(ids)).sorted()
    }

    public static func make(snapshot: AppSnapshot, at: Date = Date()) throws -> CoachContext {
        try snapshot.validate()
        try CoreValidation.date(at, name: "教练上下文时间")
        var profile = snapshot.profile
        // Never send injury/pain prose by default. Presence still blocks proposal application.
        if !profile.restrictions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.restrictions = "已填写运动限制；原文未发送，本批次禁止应用 AI 计划调整。"
        }
        let recent = Array(snapshot.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(10))
        var sanitized = recent
        for index in sanitized.indices {
            for movement in sanitized[index].exercises.indices {
                sanitized[index].exercises[movement].note = ""
                sanitized[index].exercises[movement].exercise.instructions = []
            }
        }
        let lowerBound = at.addingTimeInterval(-28 * 86_400)
        let finished = snapshot.sessions.filter { !$0.status.isOngoing && $0.startedAt >= lowerBound && $0.startedAt <= at }
        let stats = CoachStatistics(completedSessions: finished.count,
                                    completedSets: finished.reduce(0) { $0 + $1.completedWorkingSets },
                                    totalTrainingSeconds: finished.reduce(0) { $0 + $1.elapsed(at: at) })
        let active = snapshot.planVersions.first { $0.id == snapshot.activePlanVersionID }
        var result = CoachContext(id: UUID(), createdAt: at, profile: profile, plan: active,
                            recentSessions: sanitized,
                            sessionRevisions: Dictionary(uniqueKeysWithValues: recent.map { ($0.id.uuidString, $0.revision) }),
                            statistics: stats)
        if let program = snapshot.weeklyPrograms?.first(where: { $0.id == snapshot.activeWeeklyProgramID }) {
            result.weeklyProgramID = program.id; result.weeklyPlan = program.selectedOption
        }
        result.followUp = try CoachFollowUpContext.make(snapshot: snapshot, at: at)
        // Freeze the same date representation that saved coach turns use. Daily check-ins and
        // imported samples can carry sub-millisecond precision; comparing their raw dates against
        // a decoded coach turn would otherwise make an unchanged suggestion look stale.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CoachContext.self, from: encoder.encode(result))
    }

    public func matches(snapshot: AppSnapshot) -> Bool {
        guard let current = try? Self.make(snapshot: snapshot, at: createdAt) else { return false }
        let age = Date().timeIntervalSince(createdAt)
        return age >= -300 && age <= 7 * 86_400 && profile == current.profile && plan == current.plan
            && sessionRevisions == current.sessionRevisions && statistics == current.statistics
            && recentSessions == current.recentSessions && rulesVersion == current.rulesVersion
            && weeklyProgramID == current.weeklyProgramID && weeklyPlan == current.weeklyPlan
            && followUp == current.followUp
    }

    public func validate() throws {
        try CoreValidation.date(createdAt, name: "上下文时间")
        try profile.validate()
        if let plan { try plan.validate() }
        try followUp?.validate()
        guard (weeklyPlan == nil) == (weeklyProgramID == nil), weeklyProgramID == nil || plan == nil else {
            throw CoreError.invalidInput("教练上下文的手动计划与周安排关联不一致。")
        }
        guard rulesVersion == "coach-reduction-1", recentSessions.count <= 10,
              statistics.completedSessions >= 0, statistics.completedSets >= 0,
              statistics.lookbackDays == 28 else { throw CoreError.invalidInput("教练上下文格式或规则版本不受支持。") }
        try CoreValidation.finite(statistics.totalTrainingSeconds, name: "训练统计时长")
        try CoreValidation.unique(recentSessions.map(\.id), name: "上下文训练 ID")
        for session in recentSessions { try session.validate() }
        let knowledge = movementKnowledge ?? []
        guard knowledge.count <= 8 else { throw CoreError.invalidInput("发送的动作资料过多。") }
        try CoreValidation.unique(knowledge.map { $0.exercise.id }, name: "教练动作资料 ID")
        for item in knowledge {
            try item.exercise.validate()
            guard ExerciseCatalog.exercise(id: item.exercise.id) != nil else { throw CoreError.missingReference("教练动作目录资料") }
        }
        guard sessionRevisions == Dictionary(uniqueKeysWithValues: recentSessions.map { ($0.id.uuidString, $0.revision) }) else {
            throw CoreError.invalidInput("上下文记录修订号不一致。")
        }
    }

    public func evidenceLabel(_ id: String) -> String {
        if id == "profile" { return "本次发送的档案摘要" }
        if id == "statistics" { return "近 28 天的程序统计" }
        if id == "plan" { return "当前计划 v\(plan?.version ?? 0)" }
        if id == "weekly-plan" { return "已确认的每周训练安排" }
        if id == "coach-profile" { return "访谈中本人已明确回答或确认的结构化档案" }
        if id == "readiness" { return "本次根据真实资料重新计算的六部分状态摘要" }
        if let value = followUp?.todayCheckIn, id == "checkin:\(value.id.uuidString)" { return "今天的训练前状态记录" }
        if let value = followUp?.recentFeedback.first(where: { id == "feedback:\($0.id.uuidString)" }) {
            return "训练后的本人反馈 · \(value.createdAt.formatted(date: .abbreviated, time: .omitted))"
        }
        if let value = followUp?.healthMetrics.first(where: { id == "health:\($0.metric.rawValue)" }) {
            return "Apple健康摘要：\(value.metric.title) · \(value.state.title)"
        }
        if let value = followUp?.savedReviews.first(where: { id == "review:\($0.id.uuidString)" }) {
            return "已保存的\(value.period.title)程序复盘"
        }
        if id == "profile:restrictions", followUp?.confirmedProfile != nil { return "已确认运动限制的状态，原文未发送" }
        if let item = movementKnowledge?.first(where: { "exercise:\($0.exercise.id)" == id }) { return "本地动作资料：\(item.exercise.name)" }
        if let session = recentSessions.first(where: { "session:\($0.id.uuidString)" == id }) {
            return "训练记录：\(session.name) · \(session.startedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return "未知依据"
    }

    public func withMovementKnowledge(for question: String) -> CoachContext {
        var result = self
        let matches = ExerciseCatalog.exercises.filter { exercise in
            let terms = [exercise.name, exercise.englishName] + (ExerciseDetails.details(for: exercise.id)?.aliases ?? [])
            return terms.contains { !$0.isEmpty && question.localizedCaseInsensitiveContains($0) }
        }
        let planExercises = (plan?.items.compactMap { ExerciseCatalog.exercise(id: $0.exercise.id) } ?? [])
            + (weeklyPlan?.days.flatMap(\.items).compactMap { ExerciseCatalog.exercise(id: $0.exerciseID) } ?? [])
        var seen: Set<String> = []
        result.movementKnowledge = (matches + planExercises).filter { seen.insert($0.id).inserted }.prefix(8).map {
            CoachMovementKnowledge(exercise: $0, detail: ExerciseDetails.details(for: $0.id))
        }
        return result
    }
}

public struct CoachMovementKnowledge: Codable, Equatable, Sendable {
    public var exercise: Exercise
    public var aliases: [String]
    public var commonMistakes: [String]
    public var alternativeIDs: [String]
    public var movementPattern: String
    public var catalogVersion: String = "local-curated-0.2"
    public var reviewStatus: String = "通用动作提示，不是个体动作评估；未经过专业教练逐项验收。"

    public init(exercise: Exercise, detail: ExerciseDetail?) {
        self.exercise = exercise; aliases = detail?.aliases ?? []
        commonMistakes = detail?.commonMistakes ?? []; alternativeIDs = detail?.alternativeIDs ?? []
        movementPattern = detail?.movementPattern ?? "未知"
    }
}

public struct CoachProposedItem: Codable, Equatable, Sendable {
    public var exerciseID: String
    public var setCount: Int
    public var targetReps: Int?
    public var targetSeconds: Double?
    public var restSeconds: Double

    public init(exerciseID: String, setCount: Int, targetReps: Int?, targetSeconds: Double?, restSeconds: Double) {
        self.exerciseID = exerciseID; self.setCount = setCount; self.targetReps = targetReps
        self.targetSeconds = targetSeconds; self.restSeconds = restSeconds
    }
}

/// This first adapter permits only a bounded reduction of an already confirmed plan.
/// This is a product safety boundary, not a claim to implement an optimal training prescription.
public struct CoachProposal: Codable, Equatable, Sendable {
    public var reason: String
    public var targetPlanVersionID: UUID
    public var items: [CoachProposedItem]

    public init(reason: String, targetPlanVersionID: UUID, items: [CoachProposedItem]) {
        self.reason = reason; self.targetPlanVersionID = targetPlanVersionID; self.items = items
    }

    public func validatedItems(context: CoachContext) throws -> [PlannedExercise] {
        try CoreValidation.nonempty(reason, name: "建议原因", maxLength: 4_000)
        if let safety = context.followUp?.readiness.safetyVerdict, safety == .stop || safety == .gatherData {
            throw CoreError.invalidInput("最新跟进资料中的疼痛或运动限制需要先核对，本次只能解释状态，不能提出具体训练量变更。")
        }
        guard let plan = context.plan, plan.id == targetPlanVersionID else {
            throw CoreError.invalidInput("建议不对应当前发送的计划版本。")
        }
        guard context.profile.restrictions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreError.invalidInput("档案中有运动限制。本批次不自动处理限制，请先人工核对并手动编辑计划。")
        }
        guard items.count == plan.items.count else { throw CoreError.invalidInput("本批次 AI 建议不能新增、删除或替换动作。") }
        var changed = false
        let result = try zip(items, plan.items).map { proposed, original -> PlannedExercise in
            guard proposed.exerciseID == original.exercise.id,
                  proposed.setCount >= 1, proposed.setCount <= original.setCount,
                  proposed.restSeconds.isFinite, proposed.restSeconds >= original.restSeconds,
                  proposed.restSeconds <= min(86_400, original.restSeconds + 600) else {
                throw CoreError.invalidInput("建议包含未知动作、增量或超出白名单的休息变更，未应用。")
            }
            switch (original.targetReps, proposed.targetReps) {
            case (nil, nil): break
            case let (.some(old), .some(new)) where new >= 1 && new <= old: break
            default: throw CoreError.invalidInput("AI 不能增加目标次数或替未知目标编造次数。")
            }
            switch (original.targetSeconds, proposed.targetSeconds) {
            case (nil, nil): break
            case let (.some(old), .some(new)) where new.isFinite && new > 0 && new <= old: break
            default: throw CoreError.invalidInput("AI 不能增加目标时长或替未知目标编造时长。")
            }
            var item = original
            item.setCount = proposed.setCount; item.targetReps = proposed.targetReps
            item.targetSeconds = proposed.targetSeconds; item.restSeconds = proposed.restSeconds
            try item.validate()
            changed = changed || item != original
            return item
        }
        guard changed else { throw CoreError.invalidInput("建议与原计划相同，没有需要确认的调整。") }
        return result
    }
}

public struct CoachReply: Codable, Equatable, Sendable {
    public var answer: String
    /// Only identifiers of data that was actually sent are accepted, not invented narrative citations.
    public var evidence: [String]
    public var limitations: [String]
    public var proposal: CoachProposal?

    public init(answer: String, evidence: [String], limitations: [String], proposal: CoachProposal? = nil) {
        self.answer = answer; self.evidence = evidence; self.limitations = limitations; self.proposal = proposal
    }

    public func validate(context: CoachContext) throws {
        try CoreValidation.nonempty(answer, name: "教练回答", maxLength: 20_000)
        guard evidence.count <= 30, limitations.count <= 20, limitations.allSatisfy({ $0.count <= 2_000 }),
              Set(evidence).isSubset(of: Set(context.evidenceIDs)) else {
            throw CoreError.invalidInput("AI 回答包含未发送的依据，或说明超长，未作为有效建议保存。")
        }
        if let proposal {
            guard evidence.contains("plan") else { throw CoreError.invalidInput("调整建议缺少计划依据。") }
            _ = try proposal.validatedItems(context: context)
        }
    }

    public static func decode(data: Data, context: CoachContext) throws -> CoachReply {
        guard !data.isEmpty, data.count <= 128 * 1_024 else { throw CoreError.invalidInput("AI 结构化回答为空或过大。") }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoreError.invalidInput("模型没有返回 JSON 对象。")
        }
        // Names the offending key so the caller can tell the model what to remove. A generic
        // "format error" makes a model repeat the same mistake on the retry.
        let allowed: Set<String> = ["answer", "evidence", "limitations", "proposal"]
        let unknown = root.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw CoreError.invalidInput("回答包含不允许的字段：\(unknown.joined(separator: "、"))。")
        }
        let missing = allowed.filter { $0 != "proposal" && root[$0] == nil }.sorted()
        guard missing.isEmpty else {
            throw CoreError.invalidInput("回答缺少字段：\(missing.joined(separator: "、"))。")
        }
        if let proposal = root["proposal"] as? [String: Any] {
            let proposalKeys: Set<String> = ["reason", "targetPlanVersionID", "items"]
            let extra = proposal.keys.filter { !proposalKeys.contains($0) }.sorted()
            guard extra.isEmpty else {
                throw CoreError.invalidInput("建议包含不允许的字段：\(extra.joined(separator: "、"))，未应用。")
            }
            if let items = proposal["items"] as? [[String: Any]] {
                let itemKeys: Set<String> = ["exerciseID", "setCount", "targetReps", "targetSeconds", "restSeconds"]
                for item in items {
                    let itemExtra = item.keys.filter { !itemKeys.contains($0) }.sorted()
                    guard itemExtra.isEmpty else {
                        throw CoreError.invalidInput("建议动作包含不允许的字段：\(itemExtra.joined(separator: "、"))，未应用。")
                    }
                }
            }
        }
        do {
            let reply = try JSONDecoder().decode(CoachReply.self, from: data)
            try reply.validate(context: context)
            return reply
        } catch let error as CoreError { throw error }
        catch { throw CoreError.invalidInput("回答的字段类型与约定不符，请重试。") }
    }
}

public enum CoachDecision: String, Codable, Equatable, Sendable { case pending, accepted, rejected }

public struct CoachTurn: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var question: String
    public var context: CoachContext
    public var reply: CoachReply
    public var decision: CoachDecision
    public var appliedPlanVersionID: UUID?

    public init(question: String, context: CoachContext, reply: CoachReply, at: Date = Date()) {
        id = UUID(); createdAt = at; self.question = question; self.context = context; self.reply = reply
        decision = .pending; appliedPlanVersionID = nil
    }

    public func validate() throws {
        try CoreValidation.nonempty(question, name: "教练问题", maxLength: 4_000)
        try CoreValidation.date(createdAt, name: "教练回答时间")
        try context.validate()
        try reply.validate(context: context)
        guard createdAt >= context.createdAt,
              (decision == .accepted) == (appliedPlanVersionID != nil),
              decision != .accepted || reply.proposal != nil else {
            throw CoreError.invalidInput("教练建议决定和关联计划不一致。")
        }
    }
}
