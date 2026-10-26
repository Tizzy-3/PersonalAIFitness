import Foundation

public struct AppSnapshot: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var profile: PersonalProfile
    public var activePlanVersionID: UUID?
    public var planVersions: [PlanVersion]
    public var sessions: [WorkoutSession]
    public var customExercises: [Exercise]
    public var coachTurns: [CoachTurn]?
    public var favoriteExerciseIDs: [String]?
    public var planningDrafts: [PlanningDraft]?
    public var weeklyPrograms: [WeeklyProgram]?
    public var activeWeeklyProgramID: UUID?
    public var deletedPlanIDs: [UUID]?
    public var deletedWeeklyProgramIDs: [UUID]?
    // Format 4 additions. All optional so backups 1–3 still decode without inventing data.
    public var interview: InterviewSession?
    public var preWorkoutCheckIns: [PreWorkoutCheckIn]?
    public var sessionFeedback: [SessionFeedback]?
    public var healthSnapshot: HealthSnapshot?
    public var adjustments: [AdjustmentProposal]?
    public var reviewSummaries: [ReviewSummary]?
    public var latestReadiness: ReadinessAssessment?

    public init(formatVersion: Int = 4, exportedAt: Date = Date(), profile: PersonalProfile = PersonalProfile(),
                activePlanVersionID: UUID? = nil, planVersions: [PlanVersion] = [],
                sessions: [WorkoutSession] = [], customExercises: [Exercise] = [],
                coachTurns: [CoachTurn]? = nil, favoriteExerciseIDs: [String]? = nil,
                planningDrafts: [PlanningDraft]? = nil, weeklyPrograms: [WeeklyProgram]? = nil,
                activeWeeklyProgramID: UUID? = nil, deletedPlanIDs: [UUID]? = nil,
                deletedWeeklyProgramIDs: [UUID]? = nil, interview: InterviewSession? = nil,
                preWorkoutCheckIns: [PreWorkoutCheckIn]? = nil,
                sessionFeedback: [SessionFeedback]? = nil, healthSnapshot: HealthSnapshot? = nil,
                adjustments: [AdjustmentProposal]? = nil,
                reviewSummaries: [ReviewSummary]? = nil,
                latestReadiness: ReadinessAssessment? = nil) {
        self.formatVersion = formatVersion; self.exportedAt = exportedAt; self.profile = profile
        self.activePlanVersionID = activePlanVersionID; self.planVersions = planVersions
        self.sessions = sessions; self.customExercises = customExercises
        self.coachTurns = coachTurns; self.favoriteExerciseIDs = favoriteExerciseIDs
        self.planningDrafts = planningDrafts; self.weeklyPrograms = weeklyPrograms
        self.activeWeeklyProgramID = activeWeeklyProgramID; self.deletedPlanIDs = deletedPlanIDs
        self.deletedWeeklyProgramIDs = deletedWeeklyProgramIDs
        self.interview = interview; self.preWorkoutCheckIns = preWorkoutCheckIns
        self.sessionFeedback = sessionFeedback; self.healthSnapshot = healthSnapshot
        self.adjustments = adjustments; self.reviewSummaries = reviewSummaries
        self.latestReadiness = latestReadiness
    }

    public func validate() throws {
        guard (1...4).contains(formatVersion) else { throw CoreError.unsupportedFormat(formatVersion) }
        try CoreValidation.date(exportedAt, name: "导出时间")
        try profile.validate()
        guard planVersions.count <= 100_000, sessions.count <= 100_000, customExercises.count <= 10_000 else {
            throw CoreError.invalidInput("备份记录数量超出当前版本支持范围。")
        }
        try CoreValidation.unique(planVersions.map(\.id), name: "计划版本 ID")
        try CoreValidation.unique(sessions.map(\.id), name: "训练 ID")
        try CoreValidation.unique(customExercises.map(\.id), name: "自定义动作 ID")
        try CoreValidation.unique(sessions.flatMap(\.exercises).map(\.id), name: "训练动作 ID")
        try CoreValidation.unique(sessions.flatMap(\.exercises).flatMap(\.sets).map(\.id), name: "组 ID")
        guard sessions.filter({ $0.status.isOngoing }).count <= 1 else {
            throw CoreError.invalidState("备份中存在多次未结束训练，不能自动选择或合并。")
        }
        let builtInIDs = Set(ExerciseCatalog.exercises.map(\.id))
        let customByID = Dictionary(uniqueKeysWithValues: customExercises.map { ($0.id, $0) })
        for exercise in customExercises {
            try exercise.validate()
            guard exercise.isCustom, !builtInIDs.contains(exercise.id) else {
                throw CoreError.invalidInput("自定义动作不能覆盖内置动作 ID。")
            }
        }
        let versions = Dictionary(uniqueKeysWithValues: planVersions.map { ($0.id, $0) })
        let favorites = favoriteExerciseIDs ?? []
        let turns = coachTurns ?? []
        guard favorites.count <= 10_000, turns.count <= 10_000 else { throw CoreError.invalidInput("收藏或教练记录数量过多。") }
        try CoreValidation.unique(favorites, name: "收藏动作 ID")
        try CoreValidation.unique(turns.map(\.id), name: "教练记录 ID")
        guard Set(favorites).isSubset(of: builtInIDs.union(customByID.keys)) else {
            throw CoreError.missingReference("收藏动作")
        }
        for turn in turns {
            try turn.validate()
            if let base = turn.context.plan, versions[base.id] != base {
                throw CoreError.missingReference("教练依据计划版本")
            }
            if let id = turn.context.weeklyProgramID,
               weeklyPrograms?.first(where: { $0.id == id })?.selectedOption != turn.context.weeklyPlan {
                throw CoreError.missingReference("教练依据的周计划")
            }
            if let appliedID = turn.appliedPlanVersionID {
                guard let applied = versions[appliedID], let proposal = turn.reply.proposal,
                      applied.parentVersionID == proposal.targetPlanVersionID,
                      applied.items == (try proposal.validatedItems(context: turn.context)) else {
                    throw CoreError.missingReference("教练确认生成的计划版本")
                }
            }
        }
        if let activePlanVersionID, versions[activePlanVersionID] == nil { throw CoreError.missingReference("生效计划版本") }
        var versionNumbers: [UUID: Set<Int>] = [:]
        for version in planVersions {
            try version.validate()
            guard versionNumbers[version.planID, default: []].insert(version.version).inserted else {
                throw CoreError.duplicateIdentifier("同一计划的版本号")
            }
            if let parentID = version.parentVersionID {
                guard let parent = versions[parentID], parent.planID == version.planID,
                      parent.version == version.version - 1, parent.confirmedAt <= version.confirmedAt else {
                    throw CoreError.missingReference("连续的计划父版本")
                }
            }
            for item in version.items { try validateReference(item.exercise, builtInIDs: builtInIDs, customByID: customByID) }
        }
        for session in sessions {
            try session.validate()
            if let sourceID = session.sourcePlanVersionID {
                guard let version = versions[sourceID], version.confirmedAt <= session.startedAt else {
                    throw CoreError.missingReference("训练开始时的计划版本")
                }
            }
            for entry in session.exercises { try validateReference(entry.exercise, builtInIDs: builtInIDs, customByID: customByID) }
        }
        try validatePlanning(versions: versions)
        try validateCoachLoop(versions: versions)
    }

    /// Format 4 data: interview, daily feedback, health snapshot, adjustments and reviews.
    ///
    /// Backups of format 1–3 legitimately have none of it, so absence is valid. What must never pass
    /// is a reference dangling out of the file: an accepted adjustment without its version, feedback
    /// for a session that is not here, or a plan the interview claims to have applied but does not
    /// exist.
    private func validateCoachLoop(versions: [UUID: PlanVersion]) throws {
        let checkIns = preWorkoutCheckIns ?? []
        let feedback = sessionFeedback ?? []
        let adjustments = self.adjustments ?? []
        let reviews = reviewSummaries ?? []
        guard checkIns.count <= 100_000, feedback.count <= 100_000,
              adjustments.count <= 10_000, reviews.count <= 1_000 else {
            throw CoreError.invalidInput("访谈、反馈或调整记录数量超出支持范围。")
        }
        try CoreValidation.unique(checkIns.map(\.id), name: "训练前记录 ID")
        for checkIn in checkIns { try checkIn.validate() }
        try CoreValidation.unique(feedback.map(\.id), name: "训练后反馈 ID")
        try CoreValidation.unique(feedback.map(\.sessionID), name: "训练后反馈关联的训练")
        let sessionIDs = Set(sessions.map(\.id))
        for item in feedback {
            try item.validate()
            guard sessionIDs.contains(item.sessionID) else {
                throw CoreError.missingReference("训练后反馈对应的训练记录")
            }
        }
        if let healthSnapshot { try healthSnapshot.validate() }
        try CoreValidation.unique(adjustments.map(\.id), name: "调整建议 ID")
        for adjustment in adjustments {
            try adjustment.validate()
            if let baseID = adjustment.basePlanVersionID, versions[baseID] == nil {
                throw CoreError.missingReference("调整建议依据的计划版本")
            }
            if let appliedID = adjustment.appliedPlanVersionID, versions[appliedID] == nil {
                throw CoreError.missingReference("调整建议生成的计划版本")
            }
            for id in adjustment.evidenceIDs {
                // Evidence ids may reference health metrics, check-ins or sessions; an id with a
                // known prefix must resolve, so a fabricated citation is rejected.
                if id.hasPrefix("checkin:") {
                    let raw = String(id.dropFirst("checkin:".count))
                    guard let uuid = UUID(uuidString: raw), checkIns.contains(where: { $0.id == uuid }) else {
                        throw CoreError.missingReference("调整建议引用的训练前记录")
                    }
                } else if id.hasPrefix("session:") {
                    let raw = String(id.dropFirst("session:".count))
                    guard let uuid = UUID(uuidString: raw), sessionIDs.contains(uuid) else {
                        throw CoreError.missingReference("调整建议引用的训练记录")
                    }
                } else if id.hasPrefix("health:") {
                    let raw = String(id.dropFirst("health:".count))
                    guard let metric = HealthMetric(rawValue: raw),
                          healthSnapshot?.snapshot(for: metric) != nil else {
                        throw CoreError.missingReference("调整建议引用的健康数据")
                    }
                }
            }
        }
        try CoreValidation.unique(reviews.map(\.id), name: "复盘 ID")
        for review in reviews { try review.validate() }
        if let latestReadiness { try latestReadiness.validate() }
        if let interview {
            try interview.validate()
            if let appliedID = interview.appliedPlanVersionID, versions[appliedID] == nil {
                throw CoreError.missingReference("访谈应用的训练计划")
            }
        }
    }

    private func validatePlanning(versions: [UUID: PlanVersion]) throws {
        let drafts = planningDrafts ?? []
        let programs = weeklyPrograms ?? []
        let deletedPlans = deletedPlanIDs ?? []
        let deletedPrograms = deletedWeeklyProgramIDs ?? []
        guard drafts.count <= 10_000, programs.count <= 10_000 else { throw CoreError.invalidInput("周计划或草案数量超出支持范围。") }
        try CoreValidation.unique(drafts.map(\.id), name: "计划草案 ID")
        try CoreValidation.unique(programs.map(\.id), name: "周计划 ID")
        try CoreValidation.unique(deletedPlans, name: "已删除计划 ID")
        try CoreValidation.unique(deletedPrograms, name: "已删除周计划 ID")
        let byDraft = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
        let byProgram = Dictionary(uniqueKeysWithValues: programs.map { ($0.id, $0) })
        guard Set(deletedPlans).isSubset(of: Set(planVersions.map(\.planID))),
              Set(deletedPrograms).isSubset(of: Set(programs.map(\.id))) else {
            throw CoreError.missingReference("已删除的计划")
        }
        if let activePlanVersionID, let plan = versions[activePlanVersionID], deletedPlans.contains(plan.planID) {
            throw CoreError.invalidState("已删除计划不能仍处于生效状态。")
        }
        if let activeWeeklyProgramID {
            guard byProgram[activeWeeklyProgramID] != nil, !deletedPrograms.contains(activeWeeklyProgramID),
                  activePlanVersionID == nil else { throw CoreError.invalidState("生效周计划关联无效或与手动计划冲突。") }
        }
        for draft in drafts {
            try draft.validate()
            if let source = draft.sourceActivePlanVersionID, versions[source] == nil { throw CoreError.missingReference("制定计划时的手动版本") }
            if let source = draft.sourceActiveWeeklyProgramID, byProgram[source] == nil { throw CoreError.missingReference("制定计划时的周计划") }
            if let applied = draft.appliedProgramID {
                guard byProgram[applied]?.draft.id == draft.id else { throw CoreError.missingReference("确认生成的周计划") }
            }
        }
        for program in programs {
            try program.validate()
            guard var accepted = byDraft[program.draft.id], accepted.decision == .accepted,
                  accepted.appliedProgramID == program.id else { throw CoreError.missingReference("周计划的用户确认记录") }
            accepted.decision = .pending; accepted.appliedProgramID = nil
            guard accepted == program.draft, let option = program.selectedOption else {
                throw CoreError.invalidInput("周计划与冻结的草案输入不一致。")
            }
            for day in option.days where !day.isRestDay {
                guard let id = program.dayPlanVersionIDs[day.weekday], let version = versions[id],
                      version.items.count == day.items.count else { throw CoreError.missingReference("周计划训练日版本") }
                for (item, planned) in zip(day.items, version.items) {
                    guard item.exerciseID == planned.exercise.id, item.setCount == planned.setCount,
                          item.targetReps == planned.targetReps, item.targetSeconds == planned.targetSeconds,
                          item.restSeconds == planned.restSeconds else { throw CoreError.invalidInput("周计划训练内容与已确认版本不一致。") }
                }
                if activeWeeklyProgramID == program.id, deletedPlans.contains(version.planID) {
                    throw CoreError.invalidState("生效周计划包含已删除的训练日。")
                }
            }
        }
    }

    private func validateReference(_ exercise: Exercise, builtInIDs: Set<String>, customByID: [String: Exercise]) throws {
        if exercise.isCustom {
            guard let original = customByID[exercise.id] else { throw CoreError.missingReference("自定义动作 \(exercise.name)") }
            guard original.kind == exercise.kind, original.metric == exercise.metric,
                  original.loadConvention == exercise.loadConvention else {
                throw CoreError.invalidInput("自定义动作的训练类型或记录口径与动作目录不一致，不能导入。")
            }
        } else {
            guard builtInIDs.contains(exercise.id) else { throw CoreError.missingReference("内置动作 \(exercise.name)") }
            guard let original = ExerciseCatalog.exercise(id: exercise.id),
                  original.kind == exercise.kind, original.metric == exercise.metric,
                  original.loadConvention == exercise.loadConvention else {
                throw CoreError.invalidInput("内置动作的训练类型或记录口径被改变，不能导入。")
            }
        }
    }
}

public enum SnapshotCodec {
    public static let maximumDataBytes = 64 * 1_024 * 1_024

    public static func encode(_ snapshot: AppSnapshot) throws -> Data {
        try snapshot.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumDataBytes else { throw CoreError.invalidInput("备份超过 64 MB，请缩小导出范围。") }
        return data
    }

    public static func decode(_ data: Data) throws -> AppSnapshot {
        guard !data.isEmpty, data.count <= maximumDataBytes else { throw CoreError.invalidInput("备份为空或超过 64 MB。") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot: AppSnapshot
        do { snapshot = try decoder.decode(AppSnapshot.self, from: data) }
        catch { throw CoreError.invalidInput("备份内容无法读取或格式不完整。") }
        try snapshot.validate()
        return snapshot
    }
}
