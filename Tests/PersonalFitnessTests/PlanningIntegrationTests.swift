import XCTest
import FitnessCore
@testable import PersonalFitness

final class PlanningIntegrationTests: XCTestCase {
    @MainActor
    func testTodayUsesISOWeekdayAndRestDayInsteadOfTheFirstTrainingDay() throws {
        let store = try TrainingStore(inMemory: true)
        let program = try createProgram(store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12)))
        let tuesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: monday))
        let wednesday = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: monday))
        XCTAssertEqual(store.scheduledPlan(on: monday)?.id, program.dayPlanVersionIDs[1])
        XCTAssertNil(store.scheduledPlan(on: tuesday))
        XCTAssertEqual(store.scheduledPlan(on: wednesday)?.id, program.dayPlanVersionIDs[3])
        XCTAssertNil(store.currentPlan)
        let manual = try store.confirmPlan(name: "明确切换回手动", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])])
        XCTAssertNil(store.currentWeeklyProgram)
        XCTAssertEqual(store.scheduledPlan(on: tuesday), manual)
        XCTAssertEqual(store.weeklyPrograms.count, 1)
    }

    @MainActor
    func testCoachExplainsConfirmedWeeklyProgramAndHistorySurvivesDeletion() throws {
        let store = try TrainingStore(inMemory: true)
        let program = try createProgram(store)
        let context = try CoachContext.make(snapshot: store.snapshot()).withMovementKnowledge(for: "解释每周安排")
        XCTAssertNil(context.plan)
        XCTAssertEqual(context.weeklyProgramID, program.id)
        XCTAssertEqual(context.weeklyPlan, program.selectedOption)
        XCTAssertTrue(context.evidenceIDs.contains("weekly-plan"))
        let reply = CoachReply(answer: "仅解释已确认安排", evidence: ["weekly-plan"], limitations: ["无完整健康评估"])
        try store.saveCoachTurn(CoachTurn(question: "解释每周安排", context: context, reply: reply))
        try store.deleteWeeklyProgram(id: program.id)
        XCTAssertFalse(context.matches(snapshot: try store.snapshot()))
        XCTAssertEqual(store.coachTurns.count, 1)
        XCTAssertNoThrow(try store.snapshot().validate())
        let restored = try TrainingStore(inMemory: true)
        try restored.restore(SnapshotCodec.decode(SnapshotCodec.encode(store.snapshot())))
        XCTAssertEqual(restored.coachTurns, store.coachTurns)
        XCTAssertEqual(restored.deletedWeeklyProgramIDs, Set([program.id]))
    }

    @MainActor
    private func createProgram(_ store: TrainingStore) throws -> WeeklyProgram {
        let input = PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [1, 3, 5],
                                  minutesPerSession: 30, equipment: [.bodyweight, .dumbbells, .bench, .walkingSpace],
                                  adultConfirmed: true, safety: .noKnownRestrictions, painToday: false)
        let draft = try PlanningDraft.make(input: input, snapshot: store.snapshot())
        try store.savePlanningDraft(draft)
        return try store.confirmWeeklyProgram(draftID: draft.id, optionID: XCTUnwrap(draft.options.first).id)
    }
}
