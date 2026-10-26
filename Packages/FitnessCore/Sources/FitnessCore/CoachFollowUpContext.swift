import Foundation

/// Minimal, explicit evidence for ordinary coaching conversations. Raw interview answers, injury
/// prose, daily notes, HealthKit sample ledgers and query tokens are never members of this DTO.
public struct CoachFollowUpContext: Codable, Equatable, Sendable {
    /// Content hash only; changing even a redacted profile field invalidates an old suggestion.
    public var sourceProfileDigest: String?
    public var confirmedProfile: CoachConfirmedProfileSummary?
    public var todayCheckIn: CoachCheckInSummary?
    public var recentFeedback: [CoachFeedbackSummary]
    public var healthCapturedAt: Date?
    public var healthMetrics: [CoachHealthSummary]
    public var readiness: CoachReadinessSummary
    public var savedReviews: [CoachSavedReviewSummary]

    public var evidenceIDs: [String] {
        var ids = ["readiness"]
        if confirmedProfile != nil { ids.append("coach-profile") }
        if let todayCheckIn { ids.append("checkin:\(todayCheckIn.id.uuidString)") }
        ids.append(contentsOf: recentFeedback.map { "feedback:\($0.id.uuidString)" })
        ids.append(contentsOf: healthMetrics.map { "health:\($0.metric.rawValue)" })
        ids.append(contentsOf: savedReviews.map { "review:\($0.id.uuidString)" })
        ids.append(contentsOf: readiness.evidenceIDs)
        return Array(Set(ids)).sorted()
    }

    public static func make(snapshot: AppSnapshot, at date: Date) throws -> CoachFollowUpContext? {
        let profile = snapshot.interview?.profile
        let checkIn = (snapshot.preWorkoutCheckIns ?? []).filter {
            Calendar.current.isDate($0.createdAt, inSameDayAs: date) && $0.createdAt <= date
        }.max { $0.createdAt < $1.createdAt }
        let sessions = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0) })
        let feedback = (snapshot.sessionFeedback ?? []).filter {
            $0.createdAt <= date && $0.createdAt >= date.addingTimeInterval(-28 * 86_400)
                && sessions[$0.sessionID]?.status.isOngoing == false
        }.sorted { $0.createdAt > $1.createdAt }
        let reviews = ReviewSummary.Period.allCasesForCoach.compactMap { period in
            (snapshot.reviewSummaries ?? []).filter { $0.period == period && $0.createdAt <= date }
                .max { $0.createdAt < $1.createdAt }
        }
        guard profile != nil || checkIn != nil || !feedback.isEmpty
                || snapshot.healthSnapshot != nil || !reviews.isEmpty else { return nil }

        // The state engine is recomputed at request time. Remove private prose before asking it
        // to produce narrative evidence, so that narrative cannot accidentally disclose the prose.
        var safeProfile = profile ?? StructuredProfile()
        let restrictionState = CoachConfirmedProfileSummary.restrictionState(profile?.restrictions)
        safeProfile.restrictions = restrictionState == .unknown ? .unknown : ProfileField(
            value: restrictionState == .noneReported ? "无" : "已报告运动限制，原文未发送",
            provenance: .confirmed, confirmedAt: profile?.restrictions.confirmedAt ?? date)
        safeProfile.capabilityNote = .unknown; safeProfile.equipmentLoads = .unknown
        safeProfile.venue = .unknown; safeProfile.sleepNote = .unknown
        safeProfile.dailyActivityNote = .unknown; safeProfile.adherenceBarriers = .unknown
        var safeCheckIn = checkIn
        safeCheckIn?.note = ""; safeCheckIn?.painAreas = []; safeCheckIn?.sorenessAreas = []
        let safeFeedback = feedback.map { feedback -> SessionFeedback in
            var safe = feedback; safe.barrierNote = ""; safe.painAreas = []; return safe
        }
        let safeSessions = snapshot.sessions.map { session -> WorkoutSession in
            var safe = session; safe.name = "已保存的训练记录"; return safe
        }
        let assessment = try ReadinessEngine.assess(checkIn: safeCheckIn, health: snapshot.healthSnapshot,
                                                   sessions: safeSessions, profile: safeProfile,
                                                   sessionFeedback: safeFeedback, now: date)
        let result = CoachFollowUpContext(
            sourceProfileDigest: profile.map { AdjustmentFingerprint.digest(of: $0) },
            confirmedProfile: profile.map(CoachConfirmedProfileSummary.init),
            todayCheckIn: checkIn.map(CoachCheckInSummary.init),
            recentFeedback: Array(feedback.prefix(10)).compactMap { feedback in
                guard let session = sessions[feedback.sessionID] else { return nil }
                return CoachFeedbackSummary(feedback: feedback, session: session)
            },
            healthCapturedAt: snapshot.healthSnapshot?.capturedAt,
            healthMetrics: (snapshot.healthSnapshot?.metrics ?? []).map { CoachHealthSummary(metric: $0, at: date) }
                .sorted { $0.metric.rawValue < $1.metric.rawValue },
            readiness: CoachReadinessSummary(assessment),
            savedReviews: reviews.map(CoachSavedReviewSummary.init))
        try result.validate()
        return result
    }

    public func validate() throws {
        guard recentFeedback.count <= 10, healthMetrics.count <= HealthMetric.allCases.count,
              savedReviews.count <= 2 else { throw CoreError.invalidInput("发送的跟进证据超出支持范围。") }
        guard (confirmedProfile == nil) == (sourceProfileDigest == nil),
              sourceProfileDigest.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true else {
            throw CoreError.invalidInput("教练访谈档案指纹无效。")
        }
        try confirmedProfile?.validate()
        try todayCheckIn?.validate()
        for feedback in recentFeedback { try feedback.validate() }
        for metric in healthMetrics { try metric.validate() }
        for review in savedReviews { try review.validate() }
        try readiness.validate()
        if let healthCapturedAt { try CoreValidation.date(healthCapturedAt, name: "健康摘要时间") }
        try CoreValidation.unique(recentFeedback.map(\.id), name: "跟进反馈 ID")
        try CoreValidation.unique(healthMetrics.map(\.metric), name: "跟进健康指标")
        try CoreValidation.unique(savedReviews.map(\.period), name: "跟进复盘周期")
        try CoreValidation.unique(evidenceIDs, name: "跟进依据 ID")
    }
}

/// Only typed, user-backed facts are sent. Free-form capability/venue/load/adherence notes stay local.
public struct CoachConfirmedProfileSummary: Codable, Equatable, Sendable {
    public enum RestrictionState: String, Codable, Sendable { case unknown, noneReported, reported }
    public var adultConfirmed: Bool?
    public var primaryGoal: PlanningGoal?
    public var secondaryGoals: [PlanningGoal]?
    public var experience: PlanningExperience?
    public var weekdays: [Int]?
    public var minutesPerSession: Int?
    public var equipment: [PlanningEquipment]?
    public var preferredExerciseIDs: [String]?
    public var excludedExerciseIDs: [String]?
    public var restrictionStatus: RestrictionState

    init(_ profile: StructuredProfile) {
        adultConfirmed = profile.adultStatus.isUsable ? profile.adultStatus.value : nil
        primaryGoal = profile.primaryGoal.isUsable ? profile.primaryGoal.value : nil
        secondaryGoals = profile.secondaryGoals.isUsable ? profile.secondaryGoals.value : nil
        experience = profile.experience.isUsable ? profile.experience.value : nil
        weekdays = profile.weekdays.isUsable ? profile.weekdays.value : nil
        minutesPerSession = profile.minutesPerSession.isUsable ? profile.minutesPerSession.value : nil
        equipment = profile.equipment.isUsable ? profile.equipment.value : nil
        preferredExerciseIDs = profile.preferredExerciseIDs.isUsable ? profile.preferredExerciseIDs.value : nil
        excludedExerciseIDs = profile.excludedExerciseIDs.isUsable ? profile.excludedExerciseIDs.value : nil
        restrictionStatus = Self.restrictionState(profile.restrictions)
    }

    static func restrictionState(_ field: ProfileField<String>?) -> RestrictionState {
        guard let field, field.isUsable, let text = field.value else { return .unknown }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return .unknown }
        return ["无", "无已知限制", "无运动限制", "没有已知限制", "none"].contains(normalized) ? .noneReported : .reported
    }

    func validate() throws {
        if let weekdays { try CoreValidation.unique(weekdays, name: "教练档案星期"); guard weekdays.allSatisfy({ (1...7).contains($0) }) else { throw CoreError.invalidInput("教练档案星期无效。") } }
        if let minutesPerSession, !(15...120).contains(minutesPerSession) { throw CoreError.invalidInput("教练档案时间无效。") }
        for ids in [preferredExerciseIDs ?? [], excludedExerciseIDs ?? []] {
            try CoreValidation.unique(ids, name: "教练档案动作 ID")
            guard ids.allSatisfy({ ExerciseCatalog.exercise(id: $0) != nil }) else { throw CoreError.missingReference("教练档案动作") }
        }
    }
}

public struct CoachCheckInSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var energy: Int?
    public var sorenessLevel: Int?
    public var painReported: Bool?
    public var availableMinutes: Int?
    init(_ checkIn: PreWorkoutCheckIn) {
        id = checkIn.id; createdAt = checkIn.createdAt; energy = checkIn.energy
        sorenessLevel = checkIn.sorenessLevel; painReported = checkIn.painReported; availableMinutes = checkIn.availableMinutes
    }
    func validate() throws {
        try PreWorkoutCheckIn(id: id, createdAt: createdAt, energy: energy, sorenessLevel: sorenessLevel,
                              painReported: painReported, availableMinutes: availableMinutes).validate()
    }
}

public struct CoachFeedbackSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var sessionID: UUID
    public var createdAt: Date
    public var completedWorkingSets: Int
    public var totalSeconds: Double
    public var perceivedExertion: Int?
    public var tooHard: Bool?
    public var painReported: Bool?
    init(feedback: SessionFeedback, session: WorkoutSession) {
        id = feedback.id; sessionID = feedback.sessionID; createdAt = feedback.createdAt
        completedWorkingSets = session.completedWorkingSets; totalSeconds = session.elapsed(at: feedback.createdAt)
        perceivedExertion = feedback.perceivedExertion; tooHard = feedback.tooHard; painReported = feedback.painReported
    }
    func validate() throws {
        try SessionFeedback(id: id, sessionID: sessionID, createdAt: createdAt, completedWorkingSets: completedWorkingSets,
                            totalSeconds: totalSeconds, perceivedExertion: perceivedExertion, tooHard: tooHard,
                            painReported: painReported).validate()
    }
}

public struct CoachHealthSummary: Codable, Equatable, Sendable {
    public var metric: HealthMetric
    public var state: HealthMetricState
    public var sampleCountInWindow: Int
    public var latestValue: Double?
    public var latestSampleAt: Date?
    public var syncedAt: Date?
    public var sourceName: String?
    public var unit: String
    init(metric value: HealthMetricSnapshot, at date: Date) {
        metric = value.metric; state = value.effectiveState(at: date); sampleCountInWindow = value.sampleCountInWindow
        latestValue = value.latestValue; latestSampleAt = value.latestSampleAt; syncedAt = value.syncedAt; sourceName = value.sourceName
        switch metric {
        case .stepCount: unit = "count"
        case .restingHeartRate: unit = "beats/min"
        case .heartRateVariabilitySDNN: unit = "SDNN ms"
        case .sleepAnalysis: unit = "hours"
        case .activeEnergy: unit = "kcal"
        case .bodyMass: unit = "kg"
        case .workoutDuration: unit = "minutes"
        case .cardioFitness: unit = "mL/kg/min"
        }
    }
    func validate() throws {
        try HealthMetricSnapshot(metric: metric, state: state, sampleCountInWindow: sampleCountInWindow,
                                 latestValue: latestValue, latestSampleAt: latestSampleAt, syncedAt: syncedAt,
                                 sourceName: sourceName, failureReason: state == .unreadable ? "本次无法读取" : nil).validate()
        guard unit.count <= 30 else { throw CoreError.invalidInput("教练健康单位无效。") }
    }
}

/// No random assessment UUID: recomputing the same data at a fixed time compares identically.
public struct CoachReadinessSummary: Codable, Equatable, Sendable {
    public var assessedAt: Date
    public var safety: String
    public var safetyVerdict: ReadinessAssessment.Verdict
    public var recoveryEvidence: [String]
    public var performanceTrend: String
    public var confidence: String
    public var todaySuggestion: String
    public var verdict: ReadinessAssessment.Verdict
    public var evidenceIDs: [String]
    public var limitations: [String]
    public var rulesVersion: String
    init(_ value: ReadinessAssessment) {
        assessedAt = value.createdAt; safety = value.safety; safetyVerdict = value.safetyVerdict
        recoveryEvidence = value.recoveryEvidence; performanceTrend = value.performanceTrend; confidence = value.confidence
        todaySuggestion = value.todaySuggestion; verdict = value.verdict; evidenceIDs = value.evidence.map(\.id).sorted()
        limitations = value.limitations; rulesVersion = value.rulesVersion
    }
    func validate() throws {
        try CoreValidation.date(assessedAt, name: "教练状态评估时间")
        try CoreValidation.nonempty(safety, name: "教练安全说明", maxLength: 1_000)
        try CoreValidation.nonempty(todaySuggestion, name: "教练今日建议", maxLength: 2_000)
        try CoreValidation.nonempty(confidence, name: "教练可信度", maxLength: 1_000)
        guard safety.count <= 1_000, recoveryEvidence.count <= 20,
              recoveryEvidence.allSatisfy({ $0.count <= 1_000 }), performanceTrend.count <= 2_000,
              confidence.count <= 1_000, todaySuggestion.count <= 2_000, evidenceIDs.count <= 30,
              evidenceIDs.allSatisfy({ !$0.isEmpty && $0.count <= 200 }), limitations.count <= 20,
              limitations.allSatisfy({ $0.count <= 1_000 }),
              ["readiness-1", ReadinessEngine.rulesVersion].contains(rulesVersion),
              safetyVerdict != .stop || verdict == .stop else { throw CoreError.invalidInput("教练状态摘要无效。") }
        try CoreValidation.unique(evidenceIDs, name: "教练状态依据 ID")
    }
}

/// Saved program statistics, with their original date window so old reviews are never called current.
public struct CoachSavedReviewSummary: Codable, Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var period: ReviewSummary.Period
    public var windowStart: Date
    public var windowEnd: Date
    public var finishedSessionCount: Int
    public var plannedSessionCount: Int
    public var completedPlannedSessionCount: Int?
    public var completedWorkingSets: Int
    public var totalTrainingSeconds: Double
    public var exerciseProgress: [ExerciseProgress]
    public var checkInCount: Int
    public var answeredPainCount: Int
    public var reportedPainCount: Int
    public var recordedDataGapCount: Int
    init(_ value: ReviewSummary) {
        id = value.id; createdAt = value.createdAt; period = value.period
        windowStart = value.windowStart; windowEnd = value.windowEnd; finishedSessionCount = value.finishedSessionCount
        plannedSessionCount = value.plannedSessionCount; completedPlannedSessionCount = value.completedPlannedSessionCount
        completedWorkingSets = value.completedWorkingSets; totalTrainingSeconds = value.totalTrainingSeconds
        exerciseProgress = value.exerciseProgress; checkInCount = value.checkInCount
        answeredPainCount = value.answeredPainCount; reportedPainCount = value.reportedPainCount
        recordedDataGapCount = value.dataGaps.count
    }
    func validate() throws {
        try ReviewSummary(id: id, createdAt: createdAt, period: period, windowStart: windowStart, windowEnd: windowEnd,
                          finishedSessionCount: finishedSessionCount, plannedSessionCount: plannedSessionCount,
                          completedWorkingSets: completedWorkingSets, totalTrainingSeconds: totalTrainingSeconds,
                          exerciseProgress: exerciseProgress, checkInCount: checkInCount, answeredPainCount: answeredPainCount,
                          reportedPainCount: reportedPainCount, completedPlannedSessionCount: completedPlannedSessionCount).validate()
        guard (0...20).contains(recordedDataGapCount) else { throw CoreError.invalidInput("复盘数据缺口数量无效。") }
    }
}

private extension ReviewSummary.Period {
    static var allCasesForCoach: [Self] { [.week, .month] }
}
