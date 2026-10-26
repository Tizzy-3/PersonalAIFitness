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
    private(set) var activePlanVersionID: UUID?
    private(set) var recoverySnapshotURL: URL?

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let metadata: FitnessSchemaV2.MetadataRecord
    @ObservationIgnored private let recoveryDirectory: URL?

    var currentPlan: PlanVersion? { planVersions.first { $0.id == activePlanVersionID } }
    var activeSession: WorkoutSession? { sessions.first { $0.status.isOngoing } }
    var allExercises: [Exercise] { ExerciseCatalog.exercises + customExercises }

    convenience init(inMemory: Bool = false) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV2.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        let directory: URL?
        if inMemory { directory = nil }
        else { directory = try Self.defaultRecoveryDirectory() }
        try self.init(configuration: config, recoveryDirectory: directory)
    }

    /// A separately located real store permits reopen tests without touching the user's library.
    convenience init(storageURL: URL) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: storageURL, cloudKitDatabase: .none)
        try self.init(configuration: config, recoveryDirectory: storageURL.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true))
    }

    private init(configuration: ModelConfiguration, recoveryDirectory: URL?) throws {
        let schema = Schema(versionedSchema: FitnessSchemaV2.self)
        let createdContainer = try ModelContainer(for: schema, migrationPlan: FitnessMigrationPlan.self, configurations: [configuration])
        let createdContext = ModelContext(createdContainer)
        createdContext.autosaveEnabled = false
        let roots = try createdContext.fetch(FetchDescriptor<FitnessSchemaV2.MetadataRecord>())
        let planRecords = try createdContext.fetch(FetchDescriptor<FitnessSchemaV2.PlanVersionRecord>())
        let sessionRecords = try createdContext.fetch(FetchDescriptor<FitnessSchemaV2.SessionRecord>())
        guard roots.count <= 1 else { throw StorageError.invalidStore("存在多个档案根记录") }
        let root: FitnessSchemaV2.MetadataRecord
        if let existing = roots.first {
            root = existing
        } else {
            guard planRecords.isEmpty, sessionRecords.isEmpty else {
                throw StorageError.invalidStore("缺少档案根记录")
            }
            root = FitnessSchemaV2.MetadataRecord(
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
                favoriteExerciseIDs: try root.favoriteIDsData.map { try RecordCodec.decode([String].self, from: $0) } ?? []
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
        activePlanVersionID = loaded.activePlanVersionID
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
            guard revising.id == activePlanVersionID,
                  planVersions.first(where: { $0.id == revising.id }) == revising else { throw StorageError.stalePlan }
            version = try revising.revised(name: name, items: items)
        } else {
            version = PlanVersion(name: name, items: items)
            try version.validate()
        }
        let data = try RecordCodec.encode(version)
        let committed = try RecordCodec.decode(PlanVersion.self, from: data)
        let record = FitnessSchemaV2.PlanVersionRecord(id: committed.id, planID: committed.planID, version: committed.version, confirmedAt: committed.confirmedAt, payload: data)
        try write {
            context.insert(record)
            metadata.activePlanVersionID = committed.id
            metadata.revision += 1
        }
        planVersions.insert(committed, at: 0)
        activePlanVersionID = committed.id
        return committed
    }

    @discardableResult
    func startWorkout(plan: PlanVersion? = nil) throws -> WorkoutSession {
        guard activeSession == nil else { throw StorageError.activeSessionExists }
        let session: WorkoutSession
        if let plan {
            guard planVersions.contains(plan) else { throw StorageError.stalePlan }
            session = try WorkoutSession.start(plan: plan)
        } else {
            session = WorkoutSession(name: "自由训练")
        }
        try session.validate()
        let data = try RecordCodec.encode(session)
        let committed = try RecordCodec.decode(WorkoutSession.self, from: data)
        let record = FitnessSchemaV2.SessionRecord(id: committed.id, startedAt: committed.startedAt, status: committed.status.rawValue, revision: committed.revision, payload: data)
        try write { context.insert(record) }
        sessions.insert(committed, at: 0)
        return committed
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
        var descriptor = FetchDescriptor<FitnessSchemaV2.SessionRecord>(predicate: #Predicate { $0.id == lookupID })
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
        let record = FitnessSchemaV2.PlanVersionRecord(id: committed.id, planID: committed.planID,
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
            coachTurns: coachTurns, favoriteExerciseIDs: favoriteExerciseIDs.sorted())
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
        let plans = try snapshot.planVersions.map { ($0, try RecordCodec.encode($0)) }
        let restoredSessions = try snapshot.sessions.map { ($0, try RecordCodec.encode($0)) }
        let prior = try self.snapshot()
        let retainedURL = try retainPreRestoreSnapshot(prior)
        let oldPlans = try context.fetch(FetchDescriptor<FitnessSchemaV2.PlanVersionRecord>())
        let oldSessions = try context.fetch(FetchDescriptor<FitnessSchemaV2.SessionRecord>())
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
                    context.insert(FitnessSchemaV2.PlanVersionRecord(id: value.id, planID: value.planID, version: value.version, confirmedAt: value.confirmedAt, payload: payload))
                }
            }
            for (value, payload) in restoredSessions {
                if let record = sessionByID[value.id] {
                    record.startedAt = value.startedAt
                    record.status = value.status.rawValue
                    record.revision = value.revision
                    record.payload = payload
                } else {
                    context.insert(FitnessSchemaV2.SessionRecord(id: value.id, startedAt: value.startedAt, status: value.status.rawValue, revision: value.revision, payload: payload))
                }
            }
            metadata.profileData = profileData
            metadata.customExercisesData = customData
            metadata.coachData = coachData
            metadata.favoriteIDsData = favoriteData
            metadata.activePlanVersionID = snapshot.activePlanVersionID
            metadata.revision += 1
        }
        profile = snapshot.profile
        planVersions = snapshot.planVersions.sorted { $0.confirmedAt > $1.confirmedAt }
        sessions = snapshot.sessions.sorted { $0.startedAt > $1.startedAt }
        customExercises = snapshot.customExercises
        coachTurns = (snapshot.coachTurns ?? []).sorted { $0.createdAt > $1.createdAt }
        favoriteExerciseIDs = Set(snapshot.favoriteExerciseIDs ?? [])
        activePlanVersionID = snapshot.activePlanVersionID
        recoverySnapshotURL = retainedURL
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

    private func write(_ changes: () throws -> Void) throws {
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
