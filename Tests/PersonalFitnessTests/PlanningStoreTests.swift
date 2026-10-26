import XCTest
import FitnessCore
@testable import PersonalFitness

final class PlanningStoreTests: XCTestCase {
    @MainActor
    func testManualPlansShowLatestPerFamilyAndOnlyConfirmedEditActivates() throws {
        let store = try TrainingStore(inMemory: true)
        let first = try store.confirmPlan(name: "计划甲", items: [try item()])
        let second = try store.confirmPlan(name: "计划乙", items: [try item()])
        XCTAssertEqual(Set(store.visiblePlans.map(\.id)), Set([first.id, second.id]))
        var draftItems = first.items
        draftItems[0].setCount = 1
        XCTAssertEqual(store.currentPlan, second)
        XCTAssertEqual(store.planVersions.count, 2)
        let revised = try store.confirmPlan(name: "计划甲修订", items: draftItems, revising: first)
        XCTAssertEqual(store.currentPlan, revised)
        XCTAssertEqual(revised.parentVersionID, first.id)
        XCTAssertEqual(revised.version, 2)
        XCTAssertEqual(Set(store.visiblePlans.map(\.id)), Set([revised.id, second.id]))
        XCTAssertEqual(store.planVersions.first { $0.id == first.id }, first)
        XCTAssertThrowsError(try store.activatePlan(versionID: first.id))
        XCTAssertThrowsError(try store.confirmPlan(name: "过期编辑", items: first.items, revising: first))
        XCTAssertEqual(store.currentPlan, revised)
    }

    @MainActor
    func testDeletingCurrentManualPlanRetainsExecutionAndDoesNotRestoreActivation() throws {
        let store = try TrainingStore(inMemory: true)
        let plan = try store.confirmPlan(name: "保留执行快照", items: [try item()])
        let started = try store.startWorkout(plan: plan)
        try store.deletePlan(planID: plan.planID)
        XCTAssertNil(store.currentPlan)
        XCTAssertTrue(store.visiblePlans.isEmpty)
        XCTAssertEqual(store.deletedPlans.map(\.id), [plan.id])
        XCTAssertEqual(store.planVersions, [plan])
        let movementID = try XCTUnwrap(started.exercises.first?.id)
        let setID = try XCTUnwrap(started.exercises.first?.sets.first?.id)
        try store.updateSession(id: started.id) { session in
            try session.completeSet(exerciseID: movementID, setID: setID)
            try session.finish(early: true)
        }
        XCTAssertEqual(store.session(id: started.id)?.sourcePlanVersionID, plan.id)
        XCTAssertEqual(store.session(id: started.id)?.completedWorkingSets, 1)
        XCTAssertThrowsError(try store.startWorkout(plan: plan))
        XCTAssertThrowsError(try store.confirmPlan(name: "不能复活已删除计划", items: plan.items, revising: plan))
        XCTAssertTrue(store.deletedPlanIDs.contains(plan.planID))
        try store.restorePlan(planID: plan.planID)
        XCTAssertNil(store.activePlanVersionID)
        XCTAssertEqual(store.visiblePlans, [plan])
        try store.activatePlan(versionID: plan.id)
        XCTAssertEqual(store.currentPlan, plan)
    }

    @MainActor
    func testManualDeletionSurvivesDiskReopenAndBackupRestore() throws {
        let directory = try temporaryDirectory("DeletedManualPlans")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manual.store")
        let expected: AppSnapshot
        do {
            let store = try TrainingStore(storageURL: url)
            let plan = try store.confirmPlan(name: "删除但保留历史", items: [try item()])
            let session = try store.startWorkout(plan: plan)
            try store.updateSession(id: session.id) { try $0.finish(early: true) }
            try store.deletePlan(planID: plan.planID)
            expected = try store.snapshot()
        }
        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.deletedPlanIDs, Set(expected.deletedPlanIDs ?? []))
        XCTAssertEqual(reopened.planVersions, expected.planVersions)
        XCTAssertEqual(reopened.sessions, expected.sessions)
        XCTAssertNil(reopened.activePlanVersionID)
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(SnapshotCodec.decode(SnapshotCodec.encode(reopened.snapshot())))
        XCTAssertEqual(restored.deletedPlanIDs, reopened.deletedPlanIDs)
        XCTAssertEqual(restored.deletedPlans, reopened.deletedPlans)
        XCTAssertEqual(restored.sessions, reopened.sessions)
        XCTAssertNil(restored.currentPlan)
    }

    @MainActor
    func testWeeklyDraftStaysPendingUntilExplicitConfirmationCreatesAllReferences() throws {
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "原手动安排", items: [try item()])
        let draft = try saveDraft(in: store)
        XCTAssertEqual(store.currentPlan, manual)
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        XCTAssertEqual(store.planVersions.count, 1)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: "invented-option"))
        XCTAssertEqual(store.currentPlan, manual)
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        let option = try XCTUnwrap(draft.options.first)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: option.id)
        let accepted = try XCTUnwrap(store.planningDrafts.first { $0.id == draft.id })
        XCTAssertEqual(accepted.decision, .accepted)
        XCTAssertEqual(accepted.appliedProgramID, program.id)
        XCTAssertEqual(program.draft.decision, .pending)
        XCTAssertNil(program.draft.appliedProgramID)
        XCTAssertEqual(program.draft, draft)
        XCTAssertEqual(Set(program.dayPlanVersionIDs.keys), Set(option.days.filter { !$0.isRestDay }.map(\.weekday)))
        XCTAssertEqual(store.planVersions.count, 1 + program.dayPlanVersionIDs.count)
        for (weekday, versionID) in program.dayPlanVersionIDs {
            let plan = try XCTUnwrap(store.planVersions.first { $0.id == versionID })
            let expectedDay = try XCTUnwrap(option.days.first { $0.weekday == weekday })
            XCTAssertFalse(plan.items.isEmpty)
            XCTAssertEqual(plan.version, 1)
            XCTAssertEqual(plan.items.map { $0.exercise.id }, expectedDay.items.map(\.exerciseID))
        }
        XCTAssertEqual(store.currentWeeklyProgram, program)
        XCTAssertNil(store.activePlanVersionID)
        XCTAssertEqual(store.visiblePlans, [manual])
        try store.snapshot().validate()
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: option.id))
        XCTAssertEqual(store.weeklyPrograms.count, 1)
    }

    @MainActor
    func testRejectingWeeklyDraftLeavesExistingArrangementUnchanged() throws {
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "拒绝后保留", items: [try item()])
        let draft = try saveDraft(in: store)
        let optionID = try XCTUnwrap(draft.options.first?.id)
        try store.rejectPlanningDraft(id: draft.id)
        XCTAssertEqual(store.currentPlan, manual)
        XCTAssertEqual(store.planVersions, [manual])
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        XCTAssertEqual(store.planningDrafts.first?.decision, .rejected)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: optionID))
    }

    @MainActor
    func testChangedProfilePlanOrHistoryInvalidatesPendingWeeklyDraft() throws {
        for change in 0..<3 {
            let store = try TrainingStore(inMemory: true)
            _ = try store.confirmPlan(name: "制定前", items: [try item()])
            let draft = try saveDraft(in: store)
            let optionID = try XCTUnwrap(draft.options.first?.id)
            switch change {
            case 0:
                var profile = store.profile
                profile.goal = "已修改目标"
                try store.saveProfile(profile)
            case 1:
                _ = try store.confirmPlan(name: "已改为其他手动计划", items: [try item()])
            default:
                let session = try store.startWorkout()
                try store.updateSession(id: session.id) { try $0.finish(early: true) }
            }
            let before = try store.snapshot()
            XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: optionID))
            XCTAssertEqual(store.planVersions, before.planVersions)
            XCTAssertEqual(store.activePlanVersionID, before.activePlanVersionID)
            XCTAssertEqual(store.planningDrafts.first?.decision, .pending)
            XCTAssertTrue(store.weeklyPrograms.isEmpty)
        }
    }

    @MainActor
    func testExpiredWeeklyDraftCannotBecomeActive() throws {
        let store = try TrainingStore(inMemory: true)
        let draft = try PlanningDraft.make(input: input(), snapshot: store.snapshot(), at: Date().addingTimeInterval(-8 * 86_400))
        let optionID = try XCTUnwrap(draft.options.first?.id)
        try store.savePlanningDraft(draft)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: optionID))
        XCTAssertTrue(store.planVersions.isEmpty)
        XCTAssertTrue(store.weeklyPrograms.isEmpty)
        XCTAssertNil(store.activeWeeklyProgramID)
    }

    @MainActor
    func testSavedDraftCanOnlyReceiveAISelectionAndProviderMetadata() throws {
        let store = try TrainingStore(inMemory: true)
        let draft = try saveDraft(in: store)
        let option = try XCTUnwrap(draft.options.first)
        var selected = draft
        selected.selection = AISelection(optionID: option.id, explanation: "按已选择器械优先使用本地校准方案。", evidence: ["request", "rules", "option:\(option.id)"], limitations: ["能力尚未通过实际训练校准。"])
        selected.providerHost = "unit-test.invalid"
        selected.model = "protocol-fixture"
        try store.savePlanningDraft(selected)
        let committed = try XCTUnwrap(store.planningDrafts.first)
        XCTAssertEqual(committed.input, draft.input)
        XCTAssertEqual(committed.options, draft.options)
        XCTAssertEqual(committed.sourceProfile, draft.sourceProfile)
        XCTAssertEqual(committed.selection, selected.selection)
        XCTAssertTrue(store.planVersions.isEmpty)
        var changedInput = committed
        changedInput.input.minutesPerSession = 45
        changedInput.options = try PlannerEngine.options(for: changedInput.input)
        XCTAssertThrowsError(try store.savePlanningDraft(changedInput))
        var changedDose = committed
        let trainingDay = try XCTUnwrap(changedDose.options[0].days.firstIndex { !$0.isRestDay })
        changedDose.options[0].days[trainingDay].items[0].setCount += 1
        XCTAssertThrowsError(try store.savePlanningDraft(changedDose))
        XCTAssertEqual(store.planningDrafts.first, committed)
    }

    @MainActor
    func testWeeklyDeletionPreservesTrainingAndRestoreDoesNotReactivate() throws {
        let store = try TrainingStore(inMemory: true)
        let draft = try saveDraft(in: store)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: try XCTUnwrap(draft.options.first?.id))
        let dayID = try XCTUnwrap(program.dayPlanVersionIDs.values.first)
        let day = try XCTUnwrap(store.planVersions.first { $0.id == dayID })
        let session = try store.startWorkout(plan: day)
        XCTAssertThrowsError(try store.deletePlan(planID: day.planID))
        try store.deleteWeeklyProgram(id: program.id)
        XCTAssertNil(store.activeWeeklyProgramID)
        XCTAssertTrue(store.visibleWeeklyPrograms.isEmpty)
        XCTAssertEqual(store.deletedWeeklyPrograms, [program])
        XCTAssertTrue(store.visiblePlans.isEmpty)
        XCTAssertEqual(store.planVersions.count, program.dayPlanVersionIDs.count)
        try store.updateSession(id: session.id) { try $0.finish(early: true) }
        XCTAssertEqual(store.session(id: session.id)?.sourcePlanVersionID, day.id)
        XCTAssertThrowsError(try store.startWorkout(plan: day))
        XCTAssertThrowsError(try store.restorePlan(planID: day.planID))
        try store.restoreWeeklyProgram(id: program.id)
        XCTAssertEqual(store.visibleWeeklyPrograms, [program])
        XCTAssertNil(store.activeWeeklyProgramID)
        XCTAssertTrue(store.visiblePlans.isEmpty)
        XCTAssertTrue(store.deletedPlanIDs.isEmpty)
        try store.activateWeeklyProgram(id: program.id)
        XCTAssertEqual(store.currentWeeklyProgram, program)
    }

    @MainActor
    func testManualAndWeeklyActivationAreMutuallyExclusive() throws {
        let store = try TrainingStore(inMemory: true)
        let manual = try store.confirmPlan(name: "可切换手动安排", items: [try item()])
        let draft = try saveDraft(in: store)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: try XCTUnwrap(draft.options.first?.id))
        try store.activatePlan(versionID: manual.id)
        XCTAssertEqual(store.currentPlan, manual)
        XCTAssertNil(store.activeWeeklyProgramID)
        try store.activateWeeklyProgram(id: program.id)
        XCTAssertNil(store.activePlanVersionID)
        XCTAssertEqual(store.currentWeeklyProgram, program)
        try store.deletePlan(planID: manual.planID)
        XCTAssertEqual(store.activeWeeklyProgramID, program.id)
        XCTAssertNil(store.activePlanVersionID)
    }

    @MainActor
    func testWeeklyReferencesAndDeletionSurviveDiskAndBackupRoundTrip() throws {
        let directory = try temporaryDirectory("WeeklyProgramStore")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("weekly.store")
        let expected: AppSnapshot
        do {
            let store = try TrainingStore(storageURL: url)
            let draft = try saveDraft(in: store)
            let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: try XCTUnwrap(draft.options.first?.id))
            let dayID = try XCTUnwrap(program.dayPlanVersionIDs.values.first)
            let day = try XCTUnwrap(store.planVersions.first { $0.id == dayID })
            let session = try store.startWorkout(plan: day)
            try store.updateSession(id: session.id) { try $0.finish(early: true) }
            try store.deleteWeeklyProgram(id: program.id)
            expected = try store.snapshot()
        }
        let reopened = try TrainingStore(storageURL: url)
        XCTAssertEqual(reopened.planningDrafts, expected.planningDrafts ?? [])
        XCTAssertEqual(reopened.weeklyPrograms, expected.weeklyPrograms ?? [])
        XCTAssertEqual(reopened.deletedPlanIDs, Set(expected.deletedPlanIDs ?? []))
        XCTAssertEqual(reopened.deletedWeeklyProgramIDs, Set(expected.deletedWeeklyProgramIDs ?? []))
        XCTAssertEqual(reopened.sessions, expected.sessions)
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(SnapshotCodec.decode(SnapshotCodec.encode(reopened.snapshot())))
        XCTAssertEqual(restored.planVersions, reopened.planVersions)
        XCTAssertEqual(restored.planningDrafts, reopened.planningDrafts)
        XCTAssertEqual(restored.weeklyPrograms, reopened.weeklyPrograms)
        XCTAssertEqual(restored.deletedPlanIDs, reopened.deletedPlanIDs)
        XCTAssertEqual(restored.deletedWeeklyProgramIDs, reopened.deletedWeeklyProgramIDs)
        XCTAssertEqual(restored.sessions, reopened.sessions)
        XCTAssertNil(restored.activeWeeklyProgramID)
        let program = try XCTUnwrap(restored.deletedWeeklyPrograms.first)
        try restored.restoreWeeklyProgram(id: program.id)
        try restored.activateWeeklyProgram(id: program.id)
        XCTAssertEqual(restored.currentWeeklyProgram, program)
        try restored.snapshot().validate()
    }

    @MainActor
    private func saveDraft(in store: TrainingStore) throws -> PlanningDraft {
        let draft = try PlanningDraft.make(input: input(), snapshot: store.snapshot())
        try store.savePlanningDraft(draft)
        return try XCTUnwrap(store.planningDrafts.first { $0.id == draft.id })
    }

    private func input() -> PlanningInput {
        PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [1, 3, 5], minutesPerSession: 30,
                      equipment: [.bodyweight, .walkingSpace, .dumbbells, .bench], adultConfirmed: true,
                      safety: .noKnownRestrictions, painToday: false)
    }

    private func item() throws -> PlannedExercise {
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        return PlannedExercise(exercise: exercise, setCount: 2, targetReps: 8)
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
