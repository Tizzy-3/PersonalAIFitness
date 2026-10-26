import Foundation
import XCTest
@testable import FitnessCore

final class FitnessCoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private var strength: Exercise { ExerciseCatalog.exercise(id: "builtin.dumbbell-bench-press")! }
    private var bodyweight: Exercise { ExerciseCatalog.exercise(id: "builtin.push-up")! }
    private var duration: Exercise { ExerciseCatalog.exercise(id: "builtin.plank")! }
    private var cardio: Exercise { ExerciseCatalog.exercise(id: "builtin.walking")! }

    private func session(set: LoggedSet = LoggedSet(loadKG: 20, reps: 10), rest: Double = 90) -> WorkoutSession {
        WorkoutSession(name: "手动训练", startedAt: start,
                       exercises: [WorkoutExercise(exercise: strength, sets: [set], restSeconds: rest)])
    }

    private func plan() -> PlanVersion {
        PlanVersion(name: "手动计划", items: [PlannedExercise(exercise: strength)], confirmedAt: start)
    }

    func testNewProfileDoesNotInventUnknownMeasurements() throws {
        let profile = PersonalProfile()
        XCTAssertNil(profile.birthYear)
        XCTAssertNil(profile.heightCM)
        XCTAssertNil(profile.weightKG)
        XCTAssertNil(profile.weeklyDays)
        XCTAssertEqual(profile.restrictions, "")
        XCTAssertNoThrow(try profile.validate())
    }

    func testProfileRejectsNonfiniteAndInvalidInputs() {
        var profile = PersonalProfile()
        profile.weightKG = .nan
        XCTAssertThrowsError(try profile.validate())
        profile.weightKG = 70
        profile.weeklyDays = 8
        XCTAssertThrowsError(try profile.validate())
        profile.weeklyDays = nil
        profile.minutesPerSession = 0
        XCTAssertThrowsError(try profile.validate())
    }

    func testCatalogHasStableUniqueIDsAndNoCustomOrUserHistory() throws {
        XCTAssertEqual(Set(ExerciseCatalog.exercises.map(\.id)).count, ExerciseCatalog.exercises.count)
        XCTAssertTrue(ExerciseCatalog.exercises.allSatisfy { !$0.isCustom })
        XCTAssertTrue(Set(ExerciseCatalog.exercises.map(\.kind)).contains(.cardio))
        XCTAssertTrue(Set(ExerciseCatalog.exercises.map(\.kind)).contains(.bodyweight))
        for exercise in ExerciseCatalog.exercises { try exercise.validate() }
        XCTAssertNil(ExerciseCatalog.exercise(id: "invented-by-ai"))
    }

    func testRevisingPlanCreatesNewVersionWithoutMutatingOriginal() throws {
        let original = plan()
        let revised = try original.revised(name: "修改后的计划", items: [PlannedExercise(exercise: bodyweight)], at: start.addingTimeInterval(60))
        XCTAssertNotEqual(original.id, revised.id)
        XCTAssertEqual(original.planID, revised.planID)
        XCTAssertEqual(revised.parentVersionID, original.id)
        XCTAssertEqual(revised.version, 2)
        XCTAssertEqual(original.version, 1)
        XCTAssertEqual(original.items.first?.exercise.id, strength.id)
    }

    func testPlanRejectsBlankNameEmptyItemsAndDuplicateItemIDs() {
        XCTAssertThrowsError(try PlanVersion(name: " ", items: [PlannedExercise(exercise: bodyweight)]).validate())
        XCTAssertThrowsError(try PlanVersion(name: "空计划", items: []).validate())
        let item = PlannedExercise(exercise: bodyweight)
        XCTAssertThrowsError(try PlanVersion(name: "重复 ID", items: [item, item]).validate())
    }

    func testPlanRevisionCannotBeBackdated() {
        XCTAssertThrowsError(try plan().revised(name: "倒退", items: plan().items, at: start.addingTimeInterval(-1)))
    }

    func testStartingWorkoutSnapshotsPlanAndDoesNotInventLoad() throws {
        var source = plan()
        let result = try WorkoutSession.start(plan: source, at: start.addingTimeInterval(1))
        source.items[0].setCount = 8
        XCTAssertEqual(result.sourcePlanVersionID, source.id)
        XCTAssertEqual(result.exercises[0].sets.count, 3)
        XCTAssertEqual(result.exercises[0].sets[0].reps, 10)
        XCTAssertNil(result.exercises[0].sets[0].loadKG)
        XCTAssertTrue(result.exercises[0].sets.allSatisfy { !$0.isCompleted })
        XCTAssertNoThrow(try result.validate())
    }

    func testRequiredResultDependsOnRecordingMetric() throws {
        XCTAssertThrowsError(try LoggedSet(reps: 10).validate(for: strength, requireResult: true))
        XCTAssertNoThrow(try LoggedSet(reps: 10).validate(for: bodyweight, requireResult: true))
        XCTAssertThrowsError(try LoggedSet(reps: 10).validate(for: duration, requireResult: true))
        XCTAssertNoThrow(try LoggedSet(durationSeconds: 30).validate(for: duration, requireResult: true))
        XCTAssertNoThrow(try LoggedSet(durationSeconds: 600).validate(for: cardio, requireResult: true))
        XCTAssertNil(LoggedSet(durationSeconds: 600).distanceMeters)
    }

    func testDraftMayBeUnknownButCompletionCannotBeMissing() throws {
        XCTAssertNoThrow(try LoggedSet().validate(for: strength))
        XCTAssertThrowsError(try LoggedSet().validate(for: strength, requireResult: true))
        XCTAssertNoThrow(try PlannedExercise(exercise: cardio, targetReps: nil, targetSeconds: nil).validate())
    }

    func testNumericValidationRejectsNaNInfinityAndNegativeValues() {
        for value in [Double.nan, Double.infinity, -1] {
            XCTAssertThrowsError(try LoggedSet(loadKG: value, reps: 8).validate(for: strength, requireResult: true))
            XCTAssertThrowsError(try LoggedSet(durationSeconds: value).validate(for: cardio, requireResult: true))
        }
        XCTAssertThrowsError(try LoggedSet(loadKG: 20, reps: 0).validate(for: strength))
        XCTAssertThrowsError(try LoggedSet(durationSeconds: 0).validate(for: cardio))
        XCTAssertThrowsError(try LoggedSet(durationSeconds: 10, distanceMeters: -1).validate(for: cardio))
        XCTAssertNoThrow(try LoggedSet(loadKG: 0, reps: 8).validate(for: strength, requireResult: true))
    }

    func testOptionalRPEAndRIRHaveExplicitRanges() {
        XCTAssertNoThrow(try LoggedSet(loadKG: 20, reps: 8).validate(for: strength, requireResult: true))
        XCTAssertThrowsError(try LoggedSet(loadKG: 20, reps: 8, rpe: .nan).validate(for: strength))
        XCTAssertThrowsError(try LoggedSet(loadKG: 20, reps: 8, rpe: 11).validate(for: strength))
        XCTAssertThrowsError(try LoggedSet(loadKG: 20, reps: 8, rir: -1).validate(for: strength))
        XCTAssertNoThrow(try LoggedSet(loadKG: 20, reps: 8, rpe: 8, rir: 2).validate(for: strength))
    }

    func testCopiedSetHasNewIdentityAndNeedsFreshCompletion() {
        let original = LoggedSet(loadKG: 20, reps: 8, durationSeconds: 30, distanceMeters: 50, rpe: 8, rir: 2, completedAt: start)
        let copied = original.copied()
        XCTAssertNotEqual(original.id, copied.id)
        XCTAssertEqual(copied.kind, original.kind)
        XCTAssertEqual(copied.loadKG, original.loadKG)
        XCTAssertEqual(copied.reps, original.reps)
        XCTAssertEqual(copied.durationSeconds, original.durationSeconds)
        XCTAssertEqual(copied.distanceMeters, original.distanceMeters)
        XCTAssertNil(copied.rpe)
        XCTAssertNil(copied.rir)
        XCTAssertNil(copied.completedAt)
        XCTAssertFalse(copied.skipped)
        XCTAssertFalse(copied.isCompleted)
        var skipped = original
        skipped.completedAt = nil
        skipped.skipped = true
        XCTAssertFalse(skipped.copied().skipped)
        XCTAssertNil(skipped.copied().rpe)
        XCTAssertNil(skipped.copied().rir)
    }

    func testCompletingSetStartsRestAndRepeatedCompletionIsIdempotent() throws {
        var value = session()
        let entryID = value.exercises[0].id
        let setID = value.exercises[0].sets[0].id
        try value.completeSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(10))
        XCTAssertEqual(value.completedWorkingSets, 1)
        XCTAssertEqual(value.remainingRest(at: start.addingTimeInterval(15)), 85)
        let revision = value.revision
        let restEnd = value.restEndsAt
        try value.completeSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(20))
        XCTAssertEqual(value.revision, revision)
        XCTAssertEqual(value.restEndsAt, restEnd)
        XCTAssertNoThrow(try value.validate())
    }

    func testInvalidCompletionDoesNotMutateSession() {
        var value = session(set: LoggedSet(reps: 8))
        let before = value
        XCTAssertThrowsError(try value.completeSet(exerciseID: value.exercises[0].id, setID: value.exercises[0].sets[0].id, at: start.addingTimeInterval(10)))
        XCTAssertEqual(value, before)
    }

    func testPauseFreezesElapsedAndRestUntilResume() throws {
        var value = session()
        try value.completeSet(exerciseID: value.exercises[0].id, setID: value.exercises[0].sets[0].id, at: start.addingTimeInterval(10))
        try value.pause(at: start.addingTimeInterval(30))
        XCTAssertEqual(value.elapsed(at: start.addingTimeInterval(100)), 30)
        XCTAssertEqual(value.remainingRest(at: start.addingTimeInterval(100)), 70)
        XCTAssertNil(value.restEndsAt)
        try value.resume(at: start.addingTimeInterval(100))
        XCTAssertEqual(value.elapsed(at: start.addingTimeInterval(110)), 40)
        XCTAssertEqual(value.remainingRest(at: start.addingTimeInterval(110)), 60)
        XCTAssertEqual(value.accumulatedPauseSeconds, 70)
        XCTAssertNoThrow(try value.validate())
    }

    func testEarlyFinishWhilePausedExcludesFinalPauseAndRetainsResults() throws {
        var value = session()
        try value.completeSet(exerciseID: value.exercises[0].id, setID: value.exercises[0].sets[0].id, at: start.addingTimeInterval(10))
        try value.pause(at: start.addingTimeInterval(30))
        try value.finish(early: true, at: start.addingTimeInterval(100))
        XCTAssertEqual(value.status, .endedEarly)
        XCTAssertEqual(value.elapsed(at: start.addingTimeInterval(500)), 30)
        XCTAssertEqual(value.completedWorkingSets, 1)
        XCTAssertEqual(value.remainingRest(), 0)
        XCTAssertNil(value.pausedAt)
        XCTAssertNoThrow(try value.validate())
    }

    func testEndedAndPausedSessionsRejectGroupMutations() throws {
        var ended = session()
        let entryID = ended.exercises[0].id
        let setID = ended.exercises[0].sets[0].id
        try ended.finish(early: true, at: start.addingTimeInterval(10))
        XCTAssertThrowsError(try ended.completeSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(20)))
        XCTAssertThrowsError(try ended.undoSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(20)))
        XCTAssertThrowsError(try ended.pause(at: start.addingTimeInterval(20)))
        XCTAssertThrowsError(try ended.finish(early: false, at: start.addingTimeInterval(20)))
        var paused = session()
        try paused.pause(at: start.addingTimeInterval(10))
        XCTAssertThrowsError(try paused.completeSet(exerciseID: paused.exercises[0].id, setID: paused.exercises[0].sets[0].id, at: start.addingTimeInterval(20)))
    }

    func testTimeMovingBackwardsRejectsMutationInsteadOfNegativeDuration() throws {
        var value = session()
        try value.pause(at: start.addingTimeInterval(30))
        XCTAssertThrowsError(try value.resume(at: start.addingTimeInterval(20)))
        XCTAssertEqual(value.elapsed(at: start.addingTimeInterval(-50)), 30)
        XCTAssertEqual(WorkoutSession(name: "空训练", startedAt: start).elapsed(at: start.addingTimeInterval(-50)), 0)
    }

    func testWarmupDoesNotIncreaseCompletedWorkingSetCount() throws {
        var value = session(set: LoggedSet(kind: .warmup, loadKG: 12, reps: 15))
        try value.completeSet(exerciseID: value.exercises[0].id, setID: value.exercises[0].sets[0].id, at: start.addingTimeInterval(10))
        XCTAssertEqual(value.completedWorkingSets, 0)
        XCTAssertEqual(value.plannedWorkingSets, 0)
    }

    func testSkippedAndCompletedAreDistinct() throws {
        XCTAssertThrowsError(try LoggedSet(loadKG: 20, reps: 8, completedAt: start, skipped: true).validate(for: strength))
        var value = session(set: LoggedSet(loadKG: 20, reps: 8, skipped: true))
        XCTAssertThrowsError(try value.completeSet(exerciseID: value.exercises[0].id, setID: value.exercises[0].sets[0].id, at: start.addingTimeInterval(10)))
        XCTAssertEqual(value.completedWorkingSets, 0)
    }

    func testUndoReturnsSetToIncompleteWithoutDeletingInput() throws {
        var value = session()
        let entryID = value.exercises[0].id, setID = value.exercises[0].sets[0].id
        try value.completeSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(10))
        try value.undoSet(exerciseID: entryID, setID: setID, at: start.addingTimeInterval(20))
        XCTAssertFalse(value.exercises[0].sets[0].isCompleted)
        XCTAssertEqual(value.exercises[0].sets[0].loadKG, 20)
        XCTAssertEqual(value.completedWorkingSets, 0)
        XCTAssertNil(value.restEndsAt)
    }

    func testMissingGroupIDDoesNotMutateState() {
        var value = session()
        let before = value
        XCTAssertThrowsError(try value.completeSet(exerciseID: UUID(), setID: UUID(), at: start.addingTimeInterval(10)))
        XCTAssertEqual(value, before)
    }

    func testSnapshotCodecRoundTripAndStableBytes() throws {
        let original = plan()
        let workout = try WorkoutSession.start(plan: original, at: start.addingTimeInterval(1))
        let snapshot = AppSnapshot(exportedAt: start.addingTimeInterval(1_000), activePlanVersionID: original.id,
                                   planVersions: [original], sessions: [workout])
        let first = try SnapshotCodec.encode(snapshot)
        XCTAssertEqual(first, try SnapshotCodec.encode(snapshot))
        XCTAssertEqual(try SnapshotCodec.decode(first), snapshot)
    }

    func testSnapshotRejectsDuplicateIDsAndMultipleOngoingSessions() {
        let version = plan()
        XCTAssertThrowsError(try AppSnapshot(planVersions: [version, version]).validate())
        let first = session(), second = session()
        XCTAssertThrowsError(try AppSnapshot(sessions: [first, second]).validate())
        XCTAssertThrowsError(try AppSnapshot(sessions: [first, first]).validate())
    }

    func testSnapshotSubsecondDatesSurviveWithinOneMillisecond() throws {
        let precise = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let value = AppSnapshot(exportedAt: precise)
        let restored = try SnapshotCodec.decode(SnapshotCodec.encode(value))
        XCTAssertEqual(restored.exportedAt.timeIntervalSince1970, precise.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSnapshotRejectsNonfiniteAndOutOfRangeDateValues() {
        XCTAssertThrowsError(try AppSnapshot(exportedAt: Date(timeIntervalSince1970: .infinity)).validate())
        XCTAssertThrowsError(try AppSnapshot(exportedAt: Date(timeIntervalSince1970: .greatestFiniteMagnitude)).validate())
        var value = session()
        value.restEndsAt = Date(timeIntervalSince1970: .nan)
        XCTAssertThrowsError(try value.validate())
    }

    func testSnapshotRejectsMissingPlanAndVersionChain() throws {
        XCTAssertThrowsError(try AppSnapshot(activePlanVersionID: UUID()).validate())
        let first = plan()
        let second = try first.revised(name: "第二版", items: first.items, at: start.addingTimeInterval(1))
        XCTAssertThrowsError(try AppSnapshot(planVersions: [second]).validate())
        let workout = try WorkoutSession.start(plan: first, at: start.addingTimeInterval(1))
        XCTAssertThrowsError(try AppSnapshot(sessions: [workout]).validate())
        XCTAssertNoThrow(try AppSnapshot(planVersions: [first, second], sessions: [workout]).validate())
    }

    func testSnapshotRequiresCustomExerciseReferenceAndRejectsBuiltinOverride() throws {
        let custom = Exercise(id: "custom.test", name: "我的动作", englishName: "", kind: .bodyweight,
                              metric: .repetitions, equipment: "徒手", muscle: "自定义", loadConvention: .bodyweight, isCustom: true)
        let version = PlanVersion(name: "自定义计划", items: [PlannedExercise(exercise: custom)], confirmedAt: start)
        XCTAssertThrowsError(try AppSnapshot(planVersions: [version]).validate())
        XCTAssertNoThrow(try AppSnapshot(planVersions: [version], customExercises: [custom]).validate())
        var duplicate = custom
        duplicate.id = strength.id
        XCTAssertThrowsError(try AppSnapshot(customExercises: [duplicate]).validate())
    }

    func testSnapshotRejectsInventedBuiltinExercise() {
        var invented = strength
        invented.id = "builtin.nonexistent"
        let version = PlanVersion(name: "不存在的动作", items: [PlannedExercise(exercise: invented)], confirmedAt: start)
        XCTAssertThrowsError(try AppSnapshot(planVersions: [version]).validate())
    }

    func testKnownBuiltinIDCannotSpoofDifferentRecordingMetric() {
        var changed = strength
        changed.metric = .duration
        let version = PlanVersion(name: "改变口径", items: [PlannedExercise(exercise: changed)], confirmedAt: start)
        XCTAssertThrowsError(try AppSnapshot(planVersions: [version]).validate())
    }

    func testCustomExerciseReferencesMustPreserveClassificationButMayFreezeText() {
        let custom = Exercise(id: "custom.reference-check", name: "当前名称", englishName: "", kind: .bodyweight,
                              metric: .repetitions, equipment: "徒手", muscle: "自定义", loadConvention: .bodyweight, isCustom: true)
        var historical = custom
        historical.name = "历史名称"
        historical.instructions = ["历史备注"]
        let historicalVersion = PlanVersion(name: "历史计划", items: [PlannedExercise(exercise: historical)], confirmedAt: start)
        XCTAssertNoThrow(try AppSnapshot(planVersions: [historicalVersion], customExercises: [custom]).validate())

        var changedKind = custom
        changedKind.kind = .strength
        var changedMetric = custom
        changedMetric.metric = .duration
        var changedLoad = custom
        changedLoad.loadConvention = .total
        for changed in [changedKind, changedMetric, changedLoad] {
            let version = PlanVersion(name: "被改变的引用", items: [PlannedExercise(exercise: changed)], confirmedAt: start)
            XCTAssertThrowsError(try AppSnapshot(planVersions: [version], customExercises: [custom]).validate())
            let workout = WorkoutSession(name: "被改变的记录", startedAt: start, exercises: [WorkoutExercise(exercise: changed)])
            XCTAssertThrowsError(try AppSnapshot(sessions: [workout], customExercises: [custom]).validate())
        }
    }

    func testSnapshotRejectsUnknownVersionEmptyAndMalformedData() {
        XCTAssertThrowsError(try AppSnapshot(formatVersion: 999).validate())
        XCTAssertThrowsError(try SnapshotCodec.decode(Data()))
        XCTAssertThrowsError(try SnapshotCodec.decode(Data("{\"formatVersion\":1}".utf8)))
        XCTAssertThrowsError(try SnapshotCodec.decode(Data("not-json".utf8)))
    }

    func testSessionValidationRejectsContradictoryLifecycleAndDuplicateSets() {
        var value = session()
        value.status = .completed
        XCTAssertThrowsError(try value.validate())
        value = session()
        value.exercises[0].sets.append(value.exercises[0].sets[0])
        XCTAssertThrowsError(try value.validate())
        value = session()
        value.accumulatedPauseSeconds = 100
        XCTAssertThrowsError(try value.validate())
    }
}
