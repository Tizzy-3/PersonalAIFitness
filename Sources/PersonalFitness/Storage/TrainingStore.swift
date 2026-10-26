import Foundation
import Observation
import SwiftData
import FitnessCore

@MainActor
@Observable
final class TrainingStore {
    private(set) var profile: PersonalProfile
    private(set) var planVersions: [PlanVersion]
    private(set) var sessions: [WorkoutSession]
    private(set) var customExercises: [Exercise]
    private(set) var coachTurns: [CoachTurn]
    private(set) var favoriteExerciseIDs: Set<String>
    private(set) var planningDrafts: [PlanningDraft]
    private(set) var weeklyPrograms: [WeeklyProgram]
    private(set) var activeWeeklyProgramID: UUID?
    private(set) var deletedPlanIDs: Set<UUID>
    private(set) var deletedWeeklyProgramIDs: Set<UUID>
    private(set) var activePlanVersionID: UUID?
    /// Settable from `TrainingStore+Coaching`, which owns the mutation and validation for it.
    var interview: InterviewSession?
    var preWorkoutCheckIns: [PreWorkoutCheckIn]
    var sessionFeedbackRecords: [SessionFeedback]
    var healthSnapshot: HealthSnapshot?
    var adjustments: [AdjustmentProposal]
    var reviewSummaries: [ReviewSummary]
    var latestReadiness: ReadinessAssessment?
    private(set) var recoverySnapshotURL: URL?

    @ObservationIgnored let container: ModelContainer
    @ObservationIgnored let context: ModelContext
    @ObservationIgnored let metadata: FitnessSchemaV4.MetadataRecord
    @ObservationIgnored private let recoveryDirectory: URL?

    var currentPlan: PlanVersion? { planVersions.first { $0.id == activePlanVersionID } }
    var activeSession: WorkoutSession? { sessions.first { $0.status.isOngoing } }
    var allExercises: [Exercise] { ExerciseCatalog.exercises + customExercises }
    var currentWeeklyProgram: WeeklyProgram? { weeklyPrograms.first { $0.id == activeWeeklyProgramID && !deletedWeeklyProgramIDs.contains($0.id) } }
    var visibleWeeklyPrograms: [WeeklyProgram] { weeklyPrograms.filter { !deletedWeeklyProgramIDs.contains($0.id) }.sorted { $0.confirmedAt > $1.confirmedAt } }
    var deletedWeeklyPrograms: [WeeklyProgram] { weeklyPrograms.filter { deletedWeeklyProgramIDs.contains($0.id) }.sorted { $0.confirmedAt > $1.confirmedAt } }
    private var generatedFamilyIDs: Set<UUID> {
        let ids = Set(weeklyPrograms.flatMap { $0.dayPlanVersionIDs.values })
        return Set(planVersions.filter { ids.contains($0.id) }.map(\.planID))
    }
    private var latestPlans: [PlanVersion] {
        Dictionary(grouping: planVersions, by: \.planID).values.compactMap { $0.max { $0.version < $1.version } }.sorted { $0.confirmedAt > $1.confirmedAt }
    }
    var visiblePlans: [PlanVersion] { latestPlans.filter { !deletedPlanIDs.contains($0.planID) && !generatedFamilyIDs.contains($0.planID) } }
    var deletedPlans: [PlanVersion] { latestPlans.filter { deletedPlanIDs.contains($0.planID) && !generatedFamilyIDs.contains($0.planID) } }

    func scheduledPlan(on date: Date = Date()) -> PlanVersion? {
        guard let program = currentWeeklyProgram else { return currentPlan }
        let weekday = ((Calendar.current.component(.weekday, from: date) + 5) % 7) + 1
        guard let id = program.dayPlanVersionIDs[weekday] else { return nil }
        return planVersions.first { $0.id == id && !deletedPlanIDs.contains($0.planID) }
    }

    convenience init(inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        let directory: URL?
        if inMemory { directory = nil }
        else { directory = try Self.defaultRecoveryDirectory() }
        try self.init(configuration: config, recoveryDirectory: directory)
    }

    /// A separately located real store permits reopen tests without touching the user's library.
    convenience init(storageURL: URL) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let config = ModelConfiguration(schema: schema, url: storageURL, cloudKitDatabase: .none)
        try self.init(configuration: config, recoveryDirectory: storageURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true))
    }

    private init(configuration: ModelConfiguration, recoveryDirectory: URL?) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV4.self)
        let createdContainer = try ModelContainer(for: schema, migrationPlan: FitnessMigrationPlan.self, configurations: [configuration])
        let createdContext = ModelContext(createdContainer)
        createdContext.autosaveEnabled = false
        let roots = try createdContext.fetch(FetchDescriptor<FitnessSchemaV4.MetadataRecord>())
        let planRecords = try createdContext.fetch(FetchDescriptor<FitnessSchemaV4.PlanVersionRecord>())
        let sessionRecords = try createdContext.fetch(FetchDescriptor<FitnessSchemaV4.SessionRecord>())
        guard roots.count <= 1 else { throw StorageError.invalidStore("存在多个档案根记录") }
        let root: FitnessSchemaV4.MetadataRecord
        if let existing = roots.first {
            root = existing
        } else {
            guard planRecords.isEmpty, sessionRecords.isEmpty else {
                throw StorageError.invalidStore("缺少档案根记录")
            }
            root = FitnessSchemaV4.MetadataRecord(
                profileData: try RecordCodec.encode(PersonalProfile()),
                customExercisesData: try RecordCodec.encode([Exercise]())
            )
            createdContext.insert(root)
            try createdContext.save()
        }
        let loaded: AppSnapshot
        do {
            loaded = AppSnapshot(
                profile: try RecordCodec.decode(PersonalProfile.self, from: root.profileData),
                activePlanVersionID: root.activePlanVersionID,
                planVersions: try planRecords.map { try RecordCodec.decode(PlanVersion.self, from: $0.payload) },
                sessions: try sessionRecords.map { try RecordCodec.decode(WorkoutSession.self, from: $0.payload) },
                customExercises: try RecordCodec.decode([Exercise].self, from: root.customExercisesData),
                coachTurns: try root.coachData.map { try RecordCodec.decode([CoachTurn].self, from: $0) } ?? [],
                favoriteExerciseIDs: try root.favoriteIDsData.map { try RecordCodec.decode([String].self, from: $0) } ?? [],
                planningDrafts: try root.planningDraftsData.map { try RecordCodec.decode([PlanningDraft].self, from: $0) } ?? [],
                weeklyPrograms: try root.weeklyProgramsData.map { try RecordCodec.decode([WeeklyProgram].self, from: $0) } ?? [],
                activeWeeklyProgramID: root.activeWeeklyProgramID,
                deletedPlanIDs: try root.deletedPlanIDsData.map { try RecordCodec.decode([UUID].self, from: $0) } ?? [],
                deletedWeeklyProgramIDs: try root.deletedProgramIDsData.map { try RecordCodec.decode([UUID].self, from: $0) } ?? [],
                interview: try root.interviewData.map { try RecordCodec.decode(InterviewSession.self, from: $0) },
                preWorkoutCheckIns: try root.checkInsData.map { try RecordCodec.decode([PreWorkoutCheckIn].self, from: $0) } ?? [],
                sessionFeedback: try root.feedbackData.map { try RecordCodec.decode([SessionFeedback].self, from: $0) } ?? [],
                healthSnapshot: try root.healthSnapshotData.map { try RecordCodec.decode(HealthSnapshot.self, from: $0) },
                adjustments: try root.adjustmentsData.map { try RecordCodec.decode([AdjustmentProposal].self, from: $0) } ?? [],
                reviewSummaries: try root.reviewSummariesData.map { try RecordCodec.decode([ReviewSummary].self, from: $0) } ?? [],
                latestReadiness: try root.readinessData.map { try RecordCodec.decode(ReadinessAssessment.self, from: $0) }
            )
            try loaded.validate()
            guard Set(planRecords.map(\.id)) == Set(loaded.planVersions.map(\.id)),
                  Set(sessionRecords.map(\.id)) == Set(loaded.sessions.map(\.id)) else {
                throw StorageError.invalidStore("记录索引与内容不一致")
            }
        } catch {
            throw StorageError.invalidStore(error.localizedDescription)
        }
        container = createdContainer
        context = createdContext
        metadata = root
        self.recoveryDirectory = recoveryDirectory
        profile = loaded.profile
        planVersions = loaded.planVersions.sorted { $0.confirmedAt > $1.confirmedAt }
        sessions = loaded.sessions.sorted { $0.startedAt > $1.startedAt }
        customExercises = loaded.customExercises
        coachTurns = (loaded.coachTurns ?? []).sorted { $0.createdAt > $1.createdAt }
        favoriteExerciseIDs = Set(loaded.favoriteExerciseIDs ?? [])
        planningDrafts = (loaded.planningDrafts ?? []).sorted { $0.createdAt > $1.createdAt }
        weeklyPrograms = (loaded.weeklyPrograms ?? []).sorted { $0.confirmedAt > $1.confirmedAt }
        activeWeeklyProgramID = loaded.activeWeeklyProgramID
        deletedPlanIDs = Set(loaded.deletedPlanIDs ?? [])
        deletedWeeklyProgramIDs = Set(loaded.deletedWeeklyProgramIDs ?? [])
        activePlanVersionID = loaded.activePlanVersionID
        interview = loaded.interview
        preWorkoutCheckIns = (loaded.preWorkoutCheckIns ?? []).sorted { $0.createdAt > $1.createdAt }
        sessionFeedbackRecords = (loaded.sessionFeedback ?? []).sorted { $0.createdAt > $1.createdAt }
        healthSnapshot = loaded.healthSnapshot
        adjustments = (loaded.adjustments ?? []).sorted { $0.createdAt > $1.createdAt }
        reviewSummaries = (loaded.reviewSummaries ?? []).sorted { $0.createdAt > $1.createdAt }
        latestReadiness = loaded.latestReadiness
        recoverySnapshotURL = nil
    }

    func session(id: UUID) -> WorkoutSession? { sessions.first { $0.id == id } }

    func previousSet(for exerciseID: String) -> LoggedSet? {
        sessions.filter { !$0.status.isOngoing }
            .flatMap(\.exercises)
            .filter { $0.exercise.id == exerciseID && !$0.skipped }
            .flatMap(\.sets)
            .filter { $0.kind == .working && $0.isCompleted && !$0.skipped }
            .max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    func saveProfile(_ profile: PersonalProfile) throws {
        try profile.validate()
        let data = try RecordCodec.encode(profile)
        try write {
            metadata.profileData = data
            metadata.revision += 1
        }
        self.profile = profile
    }

    @discardableResult
    func confirmPlan(name: String, items: [PlannedExercise], revising: PlanVersion? = nil) throws -> PlanVersion {
        try validateExercises(items.map(\.exercise))
        let version: PlanVersion
        if let revising {
            guard !deletedPlanIDs.contains(revising.planID), !generatedFamilyIDs.contains(revising.planID),
                  latestPlans.first(where: { $0.planID == revising.planID })?.id == revising.id,
                  planVersions.first(where: { $0.id == revising.id }) == revising else { throw StorageError.stalePlan }
            version = try revising.revised(name: name, items: items)
        } else {
            version = PlanVersion(name: name, items: items)
            try version.validate()
        }
        let data = try RecordCodec.encode(version)
        let committed = try RecordCodec.decode(PlanVersion.self, from: data)
        let record = FitnessSchemaV4.PlanVersionRecord(id: committed.id, planID: committed.planID, version: committed.version, confirmedAt: committed.confirmedAt, payload: data)
        try write {
            context.insert(record)
            metadata.activePlanVersionID = committed.id
            metadata.activeWeeklyProgramID = nil
            metadata.revision += 1
        }
        planVersions.insert(committed, at: 0)
        activePlanVersionID = committed.id
        activeWeeklyProgramID = nil
        return committed
    }

    @discardableResult
    func startWorkout(plan: PlanVersion? = nil, at date: Date = Date()) throws -> WorkoutSession {
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        var session: WorkoutSession
        var consuming: Int?
        if let plan {
            guard planVersions.contains(plan), !deletedPlanIDs.contains(plan.planID) else { throw StorageError.stalePlan }
            var executionPlan = plan
            if scheduledPlan(on: date)?.id == plan.id {
                let current = try adjustmentFingerprint(now: date)
                consuming = adjustments.indices.first { index in
                    let proposal = adjustments[index]
                    return proposal.kind == .todayOnly && proposal.decision == .accepted
                        && proposal.appliedSessionID == nil && proposal.basePlanVersionID == plan.id
                        && !AdjustmentEngine.isStale(proposal, currently: current, now: date)
                }
                if let consuming, let items = adjustments[consuming].todayItems { executionPlan.items = items }
            }
            session = try WorkoutSession.start(plan: executionPlan, at: date)
        } else {
            session = WorkoutSession(name: "自由训练", startedAt: date)
        }
        if let id = session.sourcePlanVersionID,
           let program = weeklyPrograms.first(where: { $0.dayPlanVersionIDs.values.contains(id) }),
           let weekday = program.dayPlanVersionIDs.first(where: { $0.value == id })?.key,
           let day = program.selectedOption?.days.first(where: { $0.weekday == weekday }) {
            for index in session.exercises.indices where day.items.indices.contains(index) {
                session.exercises[index].note = day.items[index].notes.joined(separator: "\n")
            }
        }
        try validateExercises(session.exercises.map(\.exercise))
        try session.validate()
        let data = try RecordCodec.encode(session)
        let committed = try RecordCodec.decode(WorkoutSession.self, from: data)
        let record = FitnessSchemaV4.SessionRecord(id: committed.id, startedAt: committed.startedAt, status: committed.status.rawValue, revision: committed.revision, payload: data)
        var updated = adjustments
        if let consuming { updated[consuming].appliedSessionID = committed.id }
        var candidate = try snapshot()
        candidate.sessions.insert(committed, at: 0)
        candidate.adjustments = updated
        try candidate.validate()
        let adjustmentData = try RecordCodec.encode(updated)
        try write {
            context.insert(record)
            if consuming != nil { metadata.adjustmentsData = adjustmentData }
            metadata.revision += 1
        }
        sessions.insert(committed, at: 0)
        if consuming != nil { adjustments = updated }
        return committed
    }

    /// A changed plan and its accepted decision either both commit, or neither is published.
    func commitAdjustmentDecision(_ updated: [AdjustmentProposal], newPlan: PlanVersion?) throws {
        var candidate = try snapshot()
        candidate.adjustments = updated
        if let newPlan {
            candidate.planVersions.insert(newPlan, at: 0)
            candidate.activePlanVersionID = newPlan.id
            candidate.activeWeeklyProgramID = nil
        }
        try candidate.validate()
        let decisionData = try RecordCodec.encode(updated)
        let record: FitnessSchemaV4.PlanVersionRecord?
        if let newPlan {
            record = FitnessSchemaV4.PlanVersionRecord(id: newPlan.id, planID: newPlan.planID,
                version: newPlan.version, confirmedAt: newPlan.confirmedAt, payload: try RecordCodec.encode(newPlan))
        } else { record = nil }
        try write {
            if let record { context.insert(record) }
            metadata.adjustmentsData = decisionData
            if let newPlan { metadata.activePlanVersionID = newPlan.id; metadata.activeWeeklyProgramID = nil }
            metadata.revision += 1
        }
        if let newPlan {
            planVersions.insert(newPlan, at: 0)
            activePlanVersionID = newPlan.id; activeWeeklyProgramID = nil
        }
        adjustments = updated.sorted { $0.createdAt > $1.createdAt }
    }

    func updateSession(id: UUID, _ mutation: (inout WorkoutSession) throws -> Void) throws {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { throw StorageError.missingSession }
        let original = sessions[index]
        guard original.status.isOngoing else { throw StorageError.closedSession }
        var updated = original
        try mutation(&updated)
        guard updated.id == original.id, updated.startedAt == original.startedAt,
              updated.sourcePlanVersionID == original.sourcePlanVersionID else { throw StorageError.immutableSessionIdentity }
        let oldMovements = Set(original.exercises.map(\.id))
        let newMovements = Set(updated.exercises.map(\.id))
        let oldSets = Set(original.exercises.flatMap { $0.sets.map(\.id) })
        let newSets = Set(updated.exercises.flatMap { $0.sets.map(\.id) })
        guard oldMovements.isSubset(of: newMovements), oldSets.isSubset(of: newSets) else {
            throw StorageError.immutableSessionIdentity
        }
        try validateExercises(updated.exercises.map(\.exercise))
        updated.revision = original.revision + 1
        updated.updatedAt = Date()
        try updated.validate()
        let data = try RecordCodec.encode(updated)
        let committed = try RecordCodec.decode(WorkoutSession.self, from: data)
        let lookupID = id
        var descriptor = FetchDescriptor<FitnessSchemaV4.SessionRecord>(predicate: #Predicate { $0.id == lookupID })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { throw StorageError.missingSession }
        try write {
            record.payload = data
            record.status = updated.status.rawValue
            record.revision = updated.revision
        }
        sessions[index] = committed
    }

    func addCustomExercise(_ exercise: Exercise) throws {
        guard exercise.isCustom, !exercise.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !allExercises.contains(where: { $0.id == exercise.id }) else { throw StorageError.invalidCustomExercise }
        var updated = customExercises
        updated.append(exercise)
        var candidate = try snapshot()
        candidate.customExercises = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write {
            metadata.customExercisesData = data
            metadata.revision += 1
        }
        customExercises = updated
    }

    func toggleFavorite(exerciseID: String) throws {
        guard allExercises.contains(where: { $0.id == exerciseID }) else {
            throw CoreError.notFound("动作")
        }
        var updated = favoriteExerciseIDs
        if updated.contains(exerciseID) { updated.remove(exerciseID) }
        else { updated.insert(exerciseID) }
        let data = try RecordCodec.encode(updated.sorted())
        try write {
            metadata.favoriteIDsData = data
            metadata.revision += 1
        }
        favoriteExerciseIDs = updated
    }

    func saveCoachTurn(_ turn: CoachTurn) throws {
        try turn.validate()
        guard turn.decision == .pending, turn.appliedPlanVersionID == nil else {
            throw CoreError.invalidState("新建议不能携带已确认或已应用状态。")
        }
        guard !coachTurns.contains(where: { $0.id == turn.id }) else {
            throw CoreError.duplicateIdentifier("教练记录 ID")
        }
        // A late response remains useful history. Applying it separately requires fresh evidence.
        let committed = try RecordCodec.decode(CoachTurn.self, from: RecordCodec.encode(turn))
        var updated = coachTurns
        updated.insert(committed, at: 0)
        var candidate = try snapshot()
        candidate.coachTurns = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write {
            metadata.coachData = data
            metadata.revision += 1
        }
        coachTurns = updated
    }

    @discardableResult
    func decideCoachTurn(id: UUID, accept: Bool) throws -> PlanVersion? {
        guard let index = coachTurns.firstIndex(where: { $0.id == id }) else {
            throw CoreError.notFound("教练建议")
        }
        let original = coachTurns[index]
        try original.validate()
        guard original.decision == .pending else {
            throw CoreError.invalidState("这条建议已经处理，不能重复应用。")
        }
        var updated = coachTurns
        if !accept {
            updated[index].decision = .rejected
            let data = try RecordCodec.encode(updated)
            try write {
                metadata.coachData = data
                metadata.revision += 1
            }
            coachTurns = updated
            return nil
        }
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        guard original.context.matches(snapshot: try snapshot()),
              let proposal = original.reply.proposal,
              let plan = currentPlan, plan.id == proposal.targetPlanVersionID else {
            throw CoreError.invalidState("建议依据已变化，请重新分析当前资料和计划后再确认。")
        }
        let items = try proposal.validatedItems(context: original.context)
        try validateExercises(items.map(\.exercise))
        let proposedVersion = try plan.revised(name: plan.name, items: items)
        let payload = try RecordCodec.encode(proposedVersion)
        let committed = try RecordCodec.decode(PlanVersion.self, from: payload)
        updated[index].decision = .accepted
        updated[index].appliedPlanVersionID = committed.id
        var candidate = try snapshot()
        candidate.planVersions.insert(committed, at: 0)
        candidate.activePlanVersionID = committed.id
        candidate.coachTurns = updated
        try candidate.validate()
        let coachData = try RecordCodec.encode(updated)
        let record = FitnessSchemaV4.PlanVersionRecord(id: committed.id, planID: committed.planID,
            version: committed.version, confirmedAt: committed.confirmedAt, payload: payload)
        // One transaction makes the new version, active pointer and decision indivisible.
        try write {
            context.insert(record)
            metadata.activePlanVersionID = committed.id
            metadata.coachData = coachData
            metadata.revision += 1
        }
        planVersions.insert(committed, at: 0)
        activePlanVersionID = committed.id
        coachTurns = updated
        return committed
    }

    func snapshot() throws -> AppSnapshot {
        let snapshot = AppSnapshot(profile: profile, activePlanVersionID: activePlanVersionID,
            planVersions: planVersions, sessions: sessions, customExercises: customExercises,
            coachTurns: coachTurns, favoriteExerciseIDs: favoriteExerciseIDs.sorted(),
            planningDrafts: planningDrafts, weeklyPrograms: weeklyPrograms,
            activeWeeklyProgramID: activeWeeklyProgramID, deletedPlanIDs: deletedPlanIDs.sorted { $0.uuidString < $1.uuidString },
            deletedWeeklyProgramIDs: deletedWeeklyProgramIDs.sorted { $0.uuidString < $1.uuidString },
            interview: interview, preWorkoutCheckIns: preWorkoutCheckIns,
            sessionFeedback: sessionFeedbackRecords, healthSnapshot: healthSnapshot,
            adjustments: adjustments, reviewSummaries: reviewSummaries,
            latestReadiness: latestReadiness)
        try snapshot.validate()
        return snapshot
    }

    func restore(_ snapshot: AppSnapshot) throws {
        guard activeSession == nil else { throw StorageError.restoreWhileTraining }
        try snapshot.validate()
        let snapshot = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        // Validate and encode everything before changing even an in-memory model.
        let profileData = try RecordCodec.encode(snapshot.profile)
        let customData = try RecordCodec.encode(snapshot.customExercises)
        let coachData = try RecordCodec.encode(snapshot.coachTurns ?? [])
        let favoriteData = try RecordCodec.encode(snapshot.favoriteExerciseIDs ?? [])
        let draftsData = try RecordCodec.encode(snapshot.planningDrafts ?? [])
        let programsData = try RecordCodec.encode(snapshot.weeklyPrograms ?? [])
        let deletedData = try RecordCodec.encode(snapshot.deletedPlanIDs ?? [])
        let deletedProgramsData = try RecordCodec.encode(snapshot.deletedWeeklyProgramIDs ?? [])
        let interviewData = try snapshot.interview.map { try RecordCodec.encode($0) }
        let checkInsData = try RecordCodec.encode(snapshot.preWorkoutCheckIns ?? [])
        let feedbackData = try RecordCodec.encode(snapshot.sessionFeedback ?? [])
        let healthData = try snapshot.healthSnapshot.map { try RecordCodec.encode($0) }
        let adjustmentsData = try RecordCodec.encode(snapshot.adjustments ?? [])
        let reviewsData = try RecordCodec.encode(snapshot.reviewSummaries ?? [])
        let readinessData = try snapshot.latestReadiness.map { try RecordCodec.encode($0) }
        let plans = try snapshot.planVersions.map { ($0, try RecordCodec.encode($0)) }
        let restoredSessions = try snapshot.sessions.map { ($0, try RecordCodec.encode($0)) }
        let prior = try self.snapshot()
        let retainedURL = try retainPreRestoreSnapshot(prior)
        let oldPlans = try context.fetch(FetchDescriptor<FitnessSchemaV4.PlanVersionRecord>())
        let oldSessions = try context.fetch(FetchDescriptor<FitnessSchemaV4.SessionRecord>())
        let planByID = Dictionary(uniqueKeysWithValues: oldPlans.map { ($0.id, $0) })
        let sessionByID = Dictionary(uniqueKeysWithValues: oldSessions.map { ($0.id, $0) })
        let keptPlanIDs = Set(snapshot.planVersions.map(\.id))
        let keptSessionIDs = Set(snapshot.sessions.map(\.id))
        try write {
            for record in oldPlans where !keptPlanIDs.contains(record.id) { context.delete(record) }
            for record in oldSessions where !keptSessionIDs.contains(record.id) { context.delete(record) }
            for (value, payload) in plans {
                if let record = planByID[value.id] {
                    record.planID = value.planID
                    record.version = value.version
                    record.confirmedAt = value.confirmedAt
                    record.payload = payload
                } else {
                    context.insert(FitnessSchemaV4.PlanVersionRecord(id: value.id, planID: value.planID, version: value.version, confirmedAt: value.confirmedAt, payload: payload))
                }
            }
            for (value, payload) in restoredSessions {
                if let record = sessionByID[value.id] {
                    record.startedAt = value.startedAt
                    record.status = value.status.rawValue
                    record.revision = value.revision
                    record.payload = payload
                } else {
                    context.insert(FitnessSchemaV4.SessionRecord(id: value.id, startedAt: value.startedAt, status: value.status.rawValue, revision: value.revision, payload: payload))
                }
            }
            metadata.profileData = profileData
            metadata.customExercisesData = customData
            metadata.coachData = coachData
            metadata.favoriteIDsData = favoriteData
            metadata.planningDraftsData = draftsData
            metadata.weeklyProgramsData = programsData
            metadata.deletedPlanIDsData = deletedData
            metadata.deletedProgramIDsData = deletedProgramsData
            metadata.interviewData = interviewData
            metadata.checkInsData = checkInsData
            metadata.feedbackData = feedbackData
            metadata.healthSnapshotData = healthData
            metadata.adjustmentsData = adjustmentsData
            metadata.reviewSummariesData = reviewsData
            metadata.readinessData = readinessData
            metadata.activeWeeklyProgramID = snapshot.activeWeeklyProgramID
            metadata.activePlanVersionID = snapshot.activePlanVersionID
            metadata.revision += 1
        }
        profile = snapshot.profile
        planVersions = snapshot.planVersions.sorted { $0.confirmedAt > $1.confirmedAt }
        sessions = snapshot.sessions.sorted { $0.startedAt > $1.startedAt }
        customExercises = snapshot.customExercises
        coachTurns = (snapshot.coachTurns ?? []).sorted { $0.createdAt > $1.createdAt }
        favoriteExerciseIDs = Set(snapshot.favoriteExerciseIDs ?? [])
        planningDrafts = (snapshot.planningDrafts ?? []).sorted { $0.createdAt > $1.createdAt }
        weeklyPrograms = (snapshot.weeklyPrograms ?? []).sorted { $0.confirmedAt > $1.confirmedAt }
        deletedPlanIDs = Set(snapshot.deletedPlanIDs ?? [])
        deletedWeeklyProgramIDs = Set(snapshot.deletedWeeklyProgramIDs ?? [])
        activeWeeklyProgramID = snapshot.activeWeeklyProgramID
        activePlanVersionID = snapshot.activePlanVersionID
        interview = snapshot.interview
        preWorkoutCheckIns = (snapshot.preWorkoutCheckIns ?? []).sorted { $0.createdAt > $1.createdAt }
        sessionFeedbackRecords = (snapshot.sessionFeedback ?? []).sorted { $0.createdAt > $1.createdAt }
        healthSnapshot = snapshot.healthSnapshot
        adjustments = (snapshot.adjustments ?? []).sorted { $0.createdAt > $1.createdAt }
        reviewSummaries = (snapshot.reviewSummaries ?? []).sorted { $0.createdAt > $1.createdAt }
        latestReadiness = snapshot.latestReadiness
        recoverySnapshotURL = retainedURL
    }

    func activatePlan(versionID: UUID) throws {
        guard let plan = visiblePlans.first(where: { $0.id == versionID }) else { throw StorageError.stalePlan }
        try write {
            metadata.activePlanVersionID = plan.id
            metadata.activeWeeklyProgramID = nil
            metadata.revision += 1
        }
        activePlanVersionID = plan.id; activeWeeklyProgramID = nil
    }

    func deletePlan(planID: UUID) throws {
        guard planVersions.contains(where: { $0.planID == planID }), !deletedPlanIDs.contains(planID) else { throw CoreError.notFound("可删除计划") }
        guard !generatedFamilyIDs.contains(planID) else { throw CoreError.invalidState("这是周计划的一部分，请删除整个周计划或另存手动副本。") }
        var deleted = deletedPlanIDs; deleted.insert(planID)
        let clearCurrent = currentPlan?.planID == planID
        let data = try RecordCodec.encode(deleted.sorted { $0.uuidString < $1.uuidString })
        try write {
            metadata.deletedPlanIDsData = data
            if clearCurrent { metadata.activePlanVersionID = nil }
            metadata.revision += 1
        }
        deletedPlanIDs = deleted
        if clearCurrent { activePlanVersionID = nil }
    }

    func restorePlan(planID: UUID) throws {
        guard deletedPlanIDs.contains(planID), !generatedFamilyIDs.contains(planID) else { throw CoreError.notFound("已删除手动计划") }
        var deleted = deletedPlanIDs; deleted.remove(planID)
        let data = try RecordCodec.encode(deleted.sorted { $0.uuidString < $1.uuidString })
        try write { metadata.deletedPlanIDsData = data; metadata.revision += 1 }
        deletedPlanIDs = deleted
    }

    func savePlanningDraft(_ draft: PlanningDraft) throws {
        try draft.validate()
        guard draft.decision == .pending, draft.appliedProgramID == nil else {
            throw CoreError.invalidState("新计划草案不能自行携带已确认状态。")
        }
        let committed = try RecordCodec.decode(PlanningDraft.self, from: RecordCodec.encode(draft))
        var updated = planningDrafts
        if let index = updated.firstIndex(where: { $0.id == committed.id }) {
            let existing = updated[index]
            guard existing.decision == .pending else { throw CoreError.invalidState("这份草案已经处理，请重新制定。") }
            var oldInput = existing; var newInput = committed
            oldInput.selection = nil; oldInput.providerHost = nil; oldInput.model = nil
            newInput.selection = nil; newInput.providerHost = nil; newInput.model = nil
            guard oldInput == newInput else { throw CoreError.invalidInput("不能覆盖已冻结的计划输入，请创建新的草案。") }
            updated[index] = committed
        } else { updated.insert(committed, at: 0) }
        var candidate = try snapshot(); candidate.planningDrafts = updated
        try candidate.validate()
        let data = try RecordCodec.encode(updated)
        try write { metadata.planningDraftsData = data; metadata.revision += 1 }
        planningDrafts = updated
    }

    func rejectPlanningDraft(id: UUID) throws {
        guard let index = planningDrafts.firstIndex(where: { $0.id == id }), planningDrafts[index].decision == .pending else {
            throw CoreError.invalidState("没有可拒绝的待确认草案。")
        }
        var updated = planningDrafts; updated[index].decision = .rejected
        let data = try RecordCodec.encode(updated)
        try write { metadata.planningDraftsData = data; metadata.revision += 1 }
        planningDrafts = updated
    }

    @discardableResult
    func confirmWeeklyProgram(draftID: UUID, optionID: String) throws -> WeeklyProgram {
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        guard let index = planningDrafts.firstIndex(where: { $0.id == draftID }), planningDrafts[index].decision == .pending else {
            throw CoreError.invalidState("草案已处理或不存在，不能重复确认。")
        }
        let draft = planningDrafts[index]
        try draft.validate()
        guard draft.matches(snapshot: try snapshot()), let option = draft.options.first(where: { $0.id == optionID }) else {
            throw CoreError.invalidState("制定依据或生效安排已经变化，请按最新资料重新制定。")
        }
        let now = Date()
        var plans: [PlanVersion] = []
        var dayIDs: [Int: UUID] = [:]
        for day in option.days where !day.isRestDay {
            let items = try day.items.map { item -> PlannedExercise in
                guard let exercise = ExerciseCatalog.exercise(id: item.exerciseID) else { throw CoreError.missingReference("规则动作") }
                return PlannedExercise(exercise: exercise, setCount: item.setCount, targetReps: item.targetReps,
                                       targetSeconds: item.targetSeconds, restSeconds: item.restSeconds)
            }
            let plan = PlanVersion(name: "\(option.title) · \(day.title)", items: items, confirmedAt: now)
            try plan.validate()
            let committed = try RecordCodec.decode(PlanVersion.self, from: RecordCodec.encode(plan))
            plans.append(committed); dayIDs[day.weekday] = committed.id
        }
        let program = WeeklyProgram(confirmedAt: now, draft: draft, selectedOptionID: optionID, dayPlanVersionIDs: dayIDs)
        let committed = try RecordCodec.decode(WeeklyProgram.self, from: RecordCodec.encode(program))
        var updatedDrafts = planningDrafts
        updatedDrafts[index].decision = .accepted; updatedDrafts[index].appliedProgramID = committed.id
        var updatedPrograms = weeklyPrograms; updatedPrograms.insert(committed, at: 0)
        var updatedInterview = interview
        if let personalization = draft.personalization {
            guard updatedInterview?.profile == personalization.profile, let firstDayID = plans.first?.id else {
                throw CoreError.invalidState("访谈档案与这份草案已不一致，请重新制定。")
            }
            try updatedInterview?.applyPlan(versionID: firstDayID, at: now)
        }
        var candidate = try snapshot()
        candidate.planVersions.insert(contentsOf: plans, at: 0)
        candidate.planningDrafts = updatedDrafts; candidate.weeklyPrograms = updatedPrograms
        candidate.activePlanVersionID = nil; candidate.activeWeeklyProgramID = committed.id
        candidate.interview = updatedInterview
        try candidate.validate()
        let draftData = try RecordCodec.encode(updatedDrafts)
        let programData = try RecordCodec.encode(updatedPrograms)
        let interviewData = try updatedInterview.map { try RecordCodec.encode($0) }
        let records = try plans.map { plan in
            FitnessSchemaV4.PlanVersionRecord(id: plan.id, planID: plan.planID, version: plan.version,
                                             confirmedAt: plan.confirmedAt, payload: try RecordCodec.encode(plan))
        }
        try write {
            for record in records { context.insert(record) }
            metadata.planningDraftsData = draftData; metadata.weeklyProgramsData = programData
            metadata.activePlanVersionID = nil; metadata.activeWeeklyProgramID = committed.id
            if draft.personalization != nil { metadata.interviewData = interviewData }
            metadata.revision += 1
        }
        planVersions.insert(contentsOf: plans, at: 0)
        planningDrafts = updatedDrafts; weeklyPrograms = updatedPrograms
        activePlanVersionID = nil; activeWeeklyProgramID = committed.id
        if draft.personalization != nil { interview = updatedInterview }
        return committed
    }

    func activateWeeklyProgram(id: UUID) throws {
        guard let program = visibleWeeklyPrograms.first(where: { $0.id == id }) else { throw CoreError.notFound("周计划") }
        let dayFamilies = Set(planVersions.filter { program.dayPlanVersionIDs.values.contains($0.id) }.map(\.planID))
        guard dayFamilies.isDisjoint(with: deletedPlanIDs) else { throw CoreError.invalidState("周计划训练日已删除，请先恢复完整周计划。") }
        try write { metadata.activeWeeklyProgramID = id; metadata.activePlanVersionID = nil; metadata.revision += 1 }
        activeWeeklyProgramID = id; activePlanVersionID = nil
    }

    func deleteWeeklyProgram(id: UUID) throws {
        guard let program = visibleWeeklyPrograms.first(where: { $0.id == id }) else { throw CoreError.notFound("可删除周计划") }
        var deletedPrograms = deletedWeeklyProgramIDs; deletedPrograms.insert(id)
        let families = planVersions.filter { program.dayPlanVersionIDs.values.contains($0.id) }.map(\.planID)
        let deleted = deletedPlanIDs.union(families)
        let data = try RecordCodec.encode(deleted.sorted { $0.uuidString < $1.uuidString })
        let programsData = try RecordCodec.encode(deletedPrograms.sorted { $0.uuidString < $1.uuidString })
        try write {
            metadata.deletedPlanIDsData = data; metadata.deletedProgramIDsData = programsData
            if activeWeeklyProgramID == id { metadata.activeWeeklyProgramID = nil }
            metadata.revision += 1
        }
        deletedPlanIDs = deleted; deletedWeeklyProgramIDs = deletedPrograms
        if activeWeeklyProgramID == id { activeWeeklyProgramID = nil }
    }

    func restoreWeeklyProgram(id: UUID) throws {
        guard let program = weeklyPrograms.first(where: { $0.id == id }), deletedWeeklyProgramIDs.contains(id) else { throw CoreError.notFound("已删除周计划") }
        var programs = deletedWeeklyProgramIDs; programs.remove(id)
        let families = Set(planVersions.filter { program.dayPlanVersionIDs.values.contains($0.id) }.map(\.planID))
        let deleted = deletedPlanIDs.subtracting(families)
        let data = try RecordCodec.encode(deleted.sorted { $0.uuidString < $1.uuidString })
        let programData = try RecordCodec.encode(programs.sorted { $0.uuidString < $1.uuidString })
        try write { metadata.deletedPlanIDsData = data; metadata.deletedProgramIDsData = programData; metadata.revision += 1 }
        deletedPlanIDs = deleted; deletedWeeklyProgramIDs = programs
    }

    private func validateExercises(_ exercises: [Exercise]) throws {
        let known = Dictionary(uniqueKeysWithValues: allExercises.map { ($0.id, $0) })
        for exercise in exercises {
            guard let catalogEntry = known[exercise.id],
                  catalogEntry.kind == exercise.kind,
                  catalogEntry.metric == exercise.metric,
                  catalogEntry.loadConvention == exercise.loadConvention else { throw StorageError.invalidCustomExercise }
        }
    }

    func write(_ changes: () throws -> Void) throws {
        do {
            try context.transaction { try changes() }
        } catch {
            context.rollback()
            throw StorageError.persistence(error.localizedDescription)
        }
    }

    private func retainPreRestoreSnapshot(_ snapshot: AppSnapshot) throws -> URL? {
        guard let recoveryDirectory else { return nil }
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let data = try SnapshotCodec.encode(snapshot)
        let url = recoveryDirectory.appendingPathComponent("before-restore-\(UUID().uuidString).json")
        // This safety copy remains inside the protected app sandbox; it is not an exported encrypted backup.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private static func defaultRecoveryDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("RestoreRecovery", isDirectory: true)
    }
}
