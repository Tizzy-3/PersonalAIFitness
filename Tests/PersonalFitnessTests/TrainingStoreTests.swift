import XCTest
import FitnessCore
@testable import PersonalFitness

final class TrainingStoreTests: XCTestCase {
    @MainActor
    func testNewStoreContainsNoInventedUserHistory() throws {
        let store = try TrainingStore(inMemory: true)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertTrue(store.planVersions.isEmpty)
        XCTAssertNil(store.currentPlan)
        XCTAssertNil(store.activeSession)
        XCTAssertNil(store.profile.weightKG)
        XCTAssertNil(store.profile.heightCM)
    }

    @MainActor
    func testPlanRevisionAppendsAndRejectsStaleBase() throws {
        let store = try TrainingStore(inMemory: true)
        let item = try makeItem()
        let first = try store.confirmPlan(name: "个人计划", items: [item])
        let second = try store.confirmPlan(name: "调整后的计划", items: [item], revising: first)
        XCTAssertEqual(store.planVersions.count, 2)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.parentVersionID, first.id)
        XCTAssertEqual(store.currentPlan?.id, second.id)
        XCTAssertEqual(store.planVersions.first { $0.id == first.id }?.name, "个人计划")
        XCTAssertThrowsError(try store.confirmPlan(name: "过期修改", items: [item], revising: first))
        XCTAssertEqual(store.planVersions.count, 2)
        XCTAssertEqual(store.currentPlan?.id, second.id)
    }

    @MainActor
    func testSessionExecutionSnapshotDoesNotChangeWithPlan() throws {
        let store = try TrainingStore(inMemory: true)
        let item = try makeItem()
        let first = try store.confirmPlan(name: "最初安排", items: [item])
        let session = try store.startWorkout(plan: first)
        _ = try store.confirmPlan(name: "未来安排", items: [item], revising: first)
        XCTAssertEqual(store.session(id: session.id)?.sourcePlanVersionID, first.id)
        XCTAssertEqual(store.session(id: session.id)?.name, session.name)
        XCTAssertThrowsError(try store.startWorkout())
        XCTAssertEqual(store.sessions.count, 1)
    }

    @MainActor
    func testUnknownExerciseCannotEnterConfirmedPlan() throws {
        let store = try TrainingStore(inMemory: true)
        var invented = try XCTUnwrap(ExerciseCatalog.exercises.first)
        invented.id = "unregistered.exercise"
        XCTAssertThrowsError(try store.confirmPlan(name: "未知动作", items: [PlannedExercise(exercise: invented)]))
        XCTAssertNil(store.currentPlan)
        XCTAssertTrue(store.planVersions.isEmpty)
    }

    @MainActor
    func testFailedMutationDoesNotPublishOrSavePartialChanges() throws {
        let store = try TrainingStore(inMemory: true)
        let session = try store.startWorkout()
        enum DeliberateFailure: Error { case stop }
        XCTAssertThrowsError(try store.updateSession(id: session.id) { value in
            value.name = "不应保留"
            throw DeliberateFailure.stop
        })
        XCTAssertEqual(store.session(id: session.id), session)
        XCTAssertThrowsError(try store.updateSession(id: session.id) { $0.id = UUID() })
        XCTAssertEqual(store.session(id: session.id), session)
    }

    @MainActor
    func testFinishedSessionIsReadOnlyAndPermitsNewTraining() throws {
        let store = try TrainingStore(inMemory: true)
        let first = try store.startWorkout()
        try store.updateSession(id: first.id) { try $0.finish(early: true) }
        XCTAssertNil(store.activeSession)
        XCTAssertThrowsError(try store.updateSession(id: first.id) { $0.name = "修改历史" })
        _ = try store.startWorkout()
        XCTAssertEqual(store.sessions.count, 2)
    }

    @MainActor
    func testPreviousSetUsesFinishedWorkingResultNotCurrentOrWarmup() throws {
        let store = try TrainingStore(inMemory: true)
        let exercise = try XCTUnwrap(ExerciseCatalog.exercises.first { $0.kind == .strength && $0.metric == .repetitions })
        let version = try store.confirmPlan(name: "历史口径测试", items: [PlannedExercise(exercise: exercise)])
        let first = try store.startWorkout(plan: version)
        let movementID = try XCTUnwrap(first.exercises.first?.id)
        let setID = try XCTUnwrap(first.exercises.first?.sets.first?.id)
        try store.updateSession(id: first.id) { value in
            value.exercises[0].sets[0].loadKG = 10
            try value.completeSet(exerciseID: movementID, setID: setID)
            value.exercises[0].sets.append(LoggedSet(kind: .warmup, loadKG: 99, reps: 5, completedAt: Date()))
        }
        XCTAssertNil(store.previousSet(for: exercise.id))
        try store.updateSession(id: first.id) { try $0.finish(early: true) }
        XCTAssertEqual(store.previousSet(for: exercise.id)?.loadKG, 10)
        let current = try store.startWorkout(plan: version)
        let currentMovement = try XCTUnwrap(current.exercises.first?.id)
        let currentSet = try XCTUnwrap(current.exercises.first?.sets.first?.id)
        try store.updateSession(id: current.id) { value in
            value.exercises[0].sets[0].loadKG = 20
            try value.completeSet(exerciseID: currentMovement, setID: currentSet)
        }
        XCTAssertEqual(store.previousSet(for: exercise.id)?.loadKG, 10)
    }

    @MainActor
    func testRestoreRejectsActiveSessionAndInvalidArchiveWithoutDataLoss() throws {
        let store = try TrainingStore(inMemory: true)
        let first = try store.startWorkout()
        let candidate = AppSnapshot()
        XCTAssertThrowsError(try store.restore(candidate))
        XCTAssertEqual(store.session(id: first.id), first)
        try store.updateSession(id: first.id) { try $0.finish(early: true) }
        let original = try store.snapshot()
        let invalid = AppSnapshot(formatVersion: 9)
        XCTAssertThrowsError(try store.restore(invalid))
        XCTAssertEqual(store.sessions, original.sessions)
        XCTAssertEqual(store.planVersions, original.planVersions)
    }

    @MainActor
    func testRestoreReconcilesOverlappingIDsWithoutDuplicates() throws {
        let store = try TrainingStore(inMemory: true)
        let item = try makeItem()
        let version = try store.confirmPlan(name: "保留计划", items: [item])
        let old = try store.startWorkout(plan: version)
        try store.updateSession(id: old.id) { try $0.finish(early: true) }
        let backup = try store.snapshot()
        _ = try store.confirmPlan(name: "恢复前新建", items: [item])
        try store.restore(backup)
        XCTAssertEqual(store.planVersions, backup.planVersions)
        XCTAssertEqual(store.sessions, backup.sessions)
        XCTAssertEqual(store.activePlanVersionID, backup.activePlanVersionID)
        try store.restore(backup)
        XCTAssertEqual(store.planVersions.count, 1)
        XCTAssertEqual(store.sessions.count, 1)
    }

    @MainActor
    func testDiskStoreReopensWithSavedDataAndRetainsRecoveryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FitnessStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.store")
        let expected: AppSnapshot
        do {
            let store = try TrainingStore(storageURL: url)
            var profile = PersonalProfile()
            profile.heightCM = 175
            try store.saveProfile(profile)
            _ = try store.confirmPlan(name: "真实落盘测试", items: [try makeItem()])
            let session = try store.startWorkout(plan: store.currentPlan)
            try store.updateSession(id: session.id) { try $0.finish(early: true) }
            expected = try store.snapshot()
        }
        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.profile, expected.profile)
        XCTAssertEqual(reopened.planVersions, expected.planVersions)
        XCTAssertEqual(reopened.sessions, expected.sessions)
        try reopened.restore(AppSnapshot())
        let retained = try XCTUnwrap(reopened.recoverySnapshotURL)
        let prior = try SnapshotCodec.decode(Data(contentsOf: retained))
        XCTAssertEqual(prior.sessions, expected.sessions)
        XCTAssertTrue(reopened.sessions.isEmpty)
    }

    private func makeItem() throws -> PlannedExercise {
        let exercise = try XCTUnwrap(ExerciseCatalog.exercises.first)
        return PlannedExercise(exercise: exercise)
    }
}
