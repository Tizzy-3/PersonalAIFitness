import Foundation
import FitnessCore

/// The persistence side of the coaching loop: interview progress, daily feedback, health snapshots,
/// readiness assessments, adjustment decisions and reviews.
///
/// Every mutating method validates a candidate snapshot before touching the store, so a rejected
/// change leaves both the in-memory model and the saved record exactly as they were.
@MainActor
extension TrainingStore {
    // MARK: - Interview

    /// Entering the coach always resumes the saved relationship, including a confirmed plan.
    /// An explicit restart uses the separate profile-preserving flow.
    @discardableResult
    func startInterview(at date: Date = Date()) throws -> InterviewSession {
        if let existing = interview { return existing }
        let session = InterviewSession(createdAt: date)
        try validateInterviewCandidate(session)
        let data = try RecordCodec.encode(session)
        try write { metadata.interviewData = data; metadata.revision += 1 }
        interview = session
        return session
    }

    func saveInterview(_ session: InterviewSession) throws {
        try validateInterviewCandidate(session)
        let data = try RecordCodec.encode(session)
        try write { metadata.interviewData = data; metadata.revision += 1 }
        interview = session
    }

    /// Applies a validated session after the caller mutated it, keeping the same guarantees.
    func updateInterview(_ mutation: (inout InterviewSession) throws -> Void,
                         at date: Date = Date()) throws -> InterviewSession {
        var session = try interview ?? startInterview(at: date)
        try mutation(&session)
        try saveInterview(session)
        return session
    }

    func discardInterview() throws {
        guard interview != nil else { return }
        try write { metadata.interviewData = nil; metadata.revision += 1 }
        interview = nil
    }

    private func validateInterviewCandidate(_ session: InterviewSession) throws {
        var candidate = try snapshot()
        candidate.interview = session
        try candidate.validate()
    }

    // MARK: - Daily feedback

    /// Keep prior revisions because saved recommendations cite them. The latest revision of a day
    /// is current; editing cannot silently erase the evidence behind an older recommendation.
    @discardableResult
    func saveCheckIn(_ checkIn: PreWorkoutCheckIn, calendar: Calendar = .current) throws -> PreWorkoutCheckIn {
        try checkIn.validate()
        var updated = preWorkoutCheckIns
        if updated.contains(checkIn) { return checkIn }
        var revision = checkIn
        if updated.contains(where: { $0.id == revision.id }) { revision.id = UUID() }
        updated.insert(revision, at: 0)
        var candidate = try snapshot()
        candidate.preWorkoutCheckIns = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.checkInsData = data; metadata.revision += 1 }
        preWorkoutCheckIns = updated.sorted { $0.createdAt > $1.createdAt }
        return revision
    }

    func todaysCheckIn(calendar: Calendar = .current, now: Date = Date()) -> PreWorkoutCheckIn? {
        preWorkoutCheckIns.filter { $0.createdAt <= now && calendar.isDate($0.createdAt, inSameDayAs: now) }
            .max { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func saveSessionFeedback(_ feedback: SessionFeedback) throws -> SessionFeedback {
        guard let session = sessions.first(where: { $0.id == feedback.sessionID }) else {
            throw StorageError.missingSession
        }
        guard !session.status.isOngoing else {
            throw CoreError.invalidState("这次训练还没有结束，暂不能记录训练后感受。")
        }
        // The objective part is always recomputed here; the model and the UI cannot supply it.
        var committed = feedback
        committed.completedWorkingSets = session.completedWorkingSets
        committed.totalSeconds = session.elapsed(at: committed.createdAt)
        try committed.validate()
        var updated = sessionFeedbackRecords
        if let index = updated.firstIndex(where: { $0.sessionID == committed.sessionID }) {
            updated[index] = committed
        } else {
            updated.insert(committed, at: 0)
        }
        var candidate = try snapshot()
        candidate.sessionFeedback = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.feedbackData = data; metadata.revision += 1 }
        sessionFeedbackRecords = updated.sorted { $0.createdAt > $1.createdAt }
        return committed
    }

    func feedback(for sessionID: UUID) -> SessionFeedback? {
        sessionFeedbackRecords.first { $0.sessionID == sessionID }
    }

    // MARK: - Health

    func saveHealthSnapshot(_ snapshotValue: HealthSnapshot) throws {
        try snapshotValue.validate()
        var candidate = try snapshot()
        candidate.healthSnapshot = snapshotValue
        try candidate.validate()
        let data = try RecordCodec.encode(snapshotValue)
        try write { metadata.healthSnapshotData = data; metadata.revision += 1 }
        healthSnapshot = snapshotValue
    }

    /// Anchors from the last read, so an incremental query resumes where it stopped.
    func healthAnchors() -> [HealthMetric: Data] {
        var anchors: [HealthMetric: Data] = [:]
        for metric in healthSnapshot?.metrics ?? [] {
            if let anchor = metric.anchor { anchors[metric.metric] = anchor }
        }
        return anchors
    }

    // MARK: - Readiness

    /// Computes and stores a readiness assessment from the data actually saved.
    @discardableResult
    func refreshReadiness(now: Date = Date()) throws -> ReadinessAssessment {
        let assessment = try ReadinessEngine.assess(checkIn: todaysCheckIn(now: now),
                                                    health: healthSnapshot,
                                                    sessions: sessions,
                                                    profile: interview?.profile ?? StructuredProfile(),
                                                    sessionFeedback: sessionFeedbackRecords, now: now)
        let data = try RecordCodec.encode(assessment)
        var candidate = try snapshot()
        candidate.latestReadiness = assessment
        try candidate.validate()
        try write { metadata.readinessData = data; metadata.revision += 1 }
        latestReadiness = assessment
        return assessment
    }

    // MARK: - Adjustments

    func adjustmentFingerprint(readiness: ReadinessAssessment? = nil, now: Date = Date()) throws -> AdjustmentFingerprint {
        let assessment = try readiness ?? currentReadiness(now: now)
        var fingerprint = AdjustmentEngine.fingerprint(planVersionID: scheduledPlan(on: now)?.id, sessions: sessions,
                                     checkIn: todaysCheckIn(now: now), health: healthSnapshot,
                                     profile: interview?.profile ?? StructuredProfile(),
                                     readiness: assessment, sessionFeedback: sessionFeedbackRecords)
        struct ProfileInputs: Encodable {
            let structured: StructuredProfile
            let manual: PersonalProfile
        }
        fingerprint.profileDigest = AdjustmentFingerprint.contentDigest(
            ProfileInputs(structured: interview?.profile ?? StructuredProfile(), manual: profile))
        return fingerprint
    }

    private func currentReadiness(now: Date) throws -> ReadinessAssessment {
        try ReadinessEngine.assess(checkIn: todaysCheckIn(now: now), health: healthSnapshot,
                                  sessions: sessions, profile: interview?.profile ?? StructuredProfile(),
                                  sessionFeedback: sessionFeedbackRecords, now: now)
    }

    /// Proposes the conservative adjustment the rules allow right now and stores it as pending.
    @discardableResult
    func proposeAdjustment(readiness: ReadinessAssessment, at date: Date = Date()) throws -> AdjustmentProposal {
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        guard latestReadiness == readiness, Calendar.current.isDate(readiness.createdAt, inSameDayAs: date),
              readiness.createdAt <= date.addingTimeInterval(300) else {
            throw CoreError.invalidState("请先用今天的最新记录重新评估状态，再生成调整建议。")
        }
        var fresh = try currentReadiness(now: date)
        fresh.id = readiness.id; fresh.createdAt = readiness.createdAt
        guard fresh == readiness else {
            throw CoreError.invalidState("状态评估的依据已变化，请重新评估后再生成建议。")
        }
        let fingerprint = try adjustmentFingerprint(readiness: readiness, now: date)
        let proposal = try AdjustmentEngine.proposeForToday(readiness: readiness, basePlan: scheduledPlan(on: date),
                                                           fingerprint: fingerprint, createdAt: date,
                                                           availableMinutes: todaysCheckIn(now: date)?.availableMinutes)
        var updated = adjustments
        updated.removeAll { $0.decision == .pending }
        updated.insert(proposal, at: 0)
        var candidate = try snapshot()
        candidate.adjustments = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.adjustmentsData = data; metadata.revision += 1 }
        adjustments = updated.sorted { $0.createdAt > $1.createdAt }
        return proposal
    }

    /// Accepts a pending proposal. A `todayOnly` change never alters the long-term plan; a long-term
    /// change creates a new plan version through the normal confirmation path.
    @discardableResult
    func acceptAdjustment(id: UUID, at date: Date = Date()) throws -> PlanVersion? {
        guard let index = adjustments.firstIndex(where: { $0.id == id }),
              adjustments[index].decision == .pending else {
            throw CoreError.notFound("待确认的调整建议")
        }
        let proposal = adjustments[index]
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        let current = try adjustmentFingerprint(now: date)
        guard !AdjustmentEngine.isStale(proposal, currently: current, now: date) else {
            throw CoreError.invalidState("这段时间的记录已经变化，请重新生成建议后再确认。")
        }
        var created: PlanVersion?
        if let items = proposal.proposedItems {
            guard let base = currentPlan, base.id == proposal.basePlanVersionID else {
                throw CoreError.invalidState("当前生效计划已经变化，请重新生成建议。")
            }
            guard visiblePlans.contains(base) else {
                throw CoreError.invalidState("周计划的长期调整需要完整周版本，目前不能只修改其中一天。")
            }
            created = try base.revised(name: base.name, items: items, at: date)
        }
        var updated = adjustments
        updated[index].decision = .accepted
        updated[index].appliedPlanVersionID = created?.id
        try commitAdjustmentDecision(updated, newPlan: created)
        return created
    }

    func rejectAdjustment(id: UUID) throws {
        guard let index = adjustments.firstIndex(where: { $0.id == id }),
              adjustments[index].decision == .pending else {
            throw CoreError.notFound("待确认的调整建议")
        }
        var updated = adjustments
        updated[index].decision = .rejected
        var candidate = try snapshot()
        candidate.adjustments = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.adjustmentsData = data; metadata.revision += 1 }
        adjustments = updated.sorted { $0.createdAt > $1.createdAt }
    }

    var pendingAdjustment: AdjustmentProposal? {
        adjustments.first { $0.decision == .pending }
    }

    // MARK: - Reviews

    @discardableResult
    func refreshReview(_ period: ReviewSummary.Period, now: Date = Date()) throws -> ReviewSummary {
        let summary = try ReviewEngine.summarize(period: period, sessions: sessions,
                                                 checkIns: preWorkoutCheckIns, plan: currentPlan,
                                                 plannedDaysPerWeek: 0,
                                                 now: now, weeklyProgram: currentWeeklyProgram)
        var updated = reviewSummaries
        updated.removeAll { $0.period == period }
        updated.insert(summary, at: 0)
        var candidate = try snapshot()
        candidate.reviewSummaries = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.reviewSummariesData = data; metadata.revision += 1 }
        reviewSummaries = updated.sorted { $0.createdAt > $1.createdAt }
        return summary
    }

    func review(_ period: ReviewSummary.Period) -> ReviewSummary? {
        reviewSummaries.first { $0.period == period }
    }

}
