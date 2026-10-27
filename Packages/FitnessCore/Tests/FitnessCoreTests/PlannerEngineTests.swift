import Foundation
import XCTest
@testable import FitnessCore

/// All profiles and sessions here are isolated test fixtures, never seeded app history.
final class PlannerEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let day: TimeInterval = 86_400

    private func input(weekdays: [Int] = [1, 3, 5], minutes: Int = 30,
                       equipment: Set<PlanningEquipment> = [.bodyweight, .walkingSpace],
                       goal: PlanningGoal = .generalFitness,
                       experience: PlanningExperience = .beginner) -> PlanningInput {
        PlanningInput(goal: goal, experience: experience, weekdays: weekdays,
                      minutesPerSession: minutes, equipment: equipment,
                      adultConfirmed: true, safety: .noKnownRestrictions, painToday: false)
    }

    private func baseSnapshot() -> AppSnapshot {
        AppSnapshot(exportedAt: now)
    }

    private func resistanceDays(_ option: WeeklyPlanOption) -> [Int] {
        option.days.filter { trainingDay in
            trainingDay.items.contains { ExerciseCatalog.exercise(id: $0.exerciseID)?.kind != .cardio }
        }.map(\.weekday)
    }

    private func trainingSession(start: Date, completedResult: Bool = true,
                                 early: Bool = false) throws -> WorkoutSession {
        let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat"))
        var session = WorkoutSession(name: "测试夹具训练", startedAt: start,
                                     exercises: [WorkoutExercise(exercise: exercise, sets: [LoggedSet(reps: 8)])])
        if completedResult {
            try session.completeSet(exerciseID: session.exercises[0].id,
                                    setID: session.exercises[0].sets[0].id,
                                    at: start.addingTimeInterval(60))
        }
        try session.finish(early: early, at: start.addingTimeInterval(120))
        return session
    }

    private func selectionData(optionID: String, evidence: [String] = ["request", "history", "rules"],
                               extra: [String: Any] = [:]) throws -> Data {
        var object: [String: Any] = ["optionID": optionID, "explanation": "依据已发送条件选择本地候选。",
                                     "evidence": evidence, "limitations": ["首次校准，未知重量不推算。"]]
        for (key, value) in extra { object[key] = value }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func confirmedProgramSnapshot() throws -> (AppSnapshot, WeeklyProgram) {
        var snapshot = baseSnapshot()
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        let option = try XCTUnwrap(draft.options.first)
        var mapping: [Int: UUID] = [:]
        for trainingDay in option.days where !trainingDay.isRestDay {
            let items = try trainingDay.items.map { item in
                PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: item.exerciseID)),
                                setCount: item.setCount, targetReps: item.targetReps,
                                targetSeconds: item.targetSeconds, restSeconds: item.restSeconds)
            }
            let plan = PlanVersion(name: trainingDay.title, items: items, confirmedAt: now)
            mapping[trainingDay.weekday] = plan.id
            snapshot.planVersions.append(plan)
        }
        let program = WeeklyProgram(confirmedAt: now, draft: draft, selectedOptionID: option.id,
                                    dayPlanVersionIDs: mapping)
        var accepted = draft
        accepted.decision = .accepted
        accepted.appliedProgramID = program.id
        snapshot.planningDrafts = [accepted]
        snapshot.weeklyPrograms = [program]
        snapshot.activeWeeklyProgramID = program.id
        try snapshot.validate()
        return (snapshot, program)
    }

    func testSameNormalizedInputProducesExactlyEqualOptions() throws {
        let request = input(weekdays: [5, 1, 3], equipment: [.bench, .dumbbells, .walkingSpace])
        let first = try PlannerEngine.options(for: request)
        XCTAssertEqual(first, try PlannerEngine.options(for: request))
        let decoded = try JSONDecoder().decode(PlanningInput.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(first, try PlannerEngine.options(for: decoded))
        XCTAssertEqual(request.weekdays, [1, 3, 5])
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    func testOneTwoThreeAndFiveDaysRespectTimeBudgetIncludingEveryRest() throws {
        let schedules = [[1], [1, 4], [1, 3, 5], [1, 2, 3, 4, 5]]
        for weekdays in schedules {
            for minutes in [15, 30, 60] {
                for goal in PlanningGoal.allCases {
                    for experience in PlanningExperience.allCases {
                        let request = input(weekdays: weekdays, minutes: minutes,
                                            goal: goal, experience: experience)
                        for option in try PlannerEngine.options(for: request) {
                            try option.validate(input: request)
                            XCTAssertEqual(option.days.map(\.weekday), Array(1...7))
                            XCTAssertEqual(option.days.filter { !$0.isRestDay }.map(\.weekday), weekdays)
                            for trainingDay in option.days {
                                if trainingDay.isRestDay {
                                    XCTAssertEqual(trainingDay.estimatedMinutesLower, 0)
                                    XCTAssertEqual(trainingDay.estimatedMinutesUpper, 0)
                                    continue
                                }
                                // Independent budget oracle: preparation/finish, every prescribed
                                // set's effort + rest, movement transitions, then upper buffer.
                                var seconds = 300.0
                                for item in trainingDay.items {
                                    let effort = item.targetSeconds ?? Double(item.targetReps ?? 0) * 4
                                    seconds += Double(item.setCount) * (effort + item.restSeconds) + 45
                                }
                                XCTAssertEqual(trainingDay.estimatedMinutesLower, Int(floor(seconds / 60)))
                                XCTAssertEqual(trainingDay.estimatedMinutesUpper, Int(ceil(seconds * 1.2 / 60)))
                                XCTAssertGreaterThan(trainingDay.estimatedMinutesLower, 0)
                                XCTAssertLessThanOrEqual(trainingDay.estimatedMinutesUpper, minutes)
                            }
                        }
                    }
                }
            }
        }
    }

    func testBodyweightOptionsNeverRequireUnselectedEquipment() throws {
        let request = input()
        for option in try PlannerEngine.options(for: request) {
            for item in option.days.flatMap(\.items) {
                let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: item.exerciseID))
                XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: item.exerciseID, equipment: request.equipment))
                XCTAssertTrue(exercise.kind == .bodyweight || exercise.kind == .cardio)
            }
            XCTAssertFalse(option.limitations.isEmpty)
        }
    }

    func testDumbbellsNeedBenchOrStableSupportForBenchPressAndSupportedRow() throws {
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.dumbbell-bench-press", equipment: [.dumbbells]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.dumbbell-row", equipment: [.dumbbells]))
        XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: "builtin.dumbbell-row", equipment: [.dumbbells, .stableSupport]))
        XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: "builtin.dumbbell-bench-press", equipment: [.dumbbells, .adjustableBench]))
        let request = input(equipment: [.bodyweight, .dumbbells, .bench, .walkingSpace])
        let options = try PlannerEngine.options(for: request)
        let equipmentFirst = try XCTUnwrap(options.first { $0.id == "equipment-first" })
        let ids = Set(equipmentFirst.days.flatMap(\.items).map(\.exerciseID))
        XCTAssertTrue(ids.contains("builtin.dumbbell-bench-press"))
        XCTAssertTrue(ids.contains("builtin.dumbbell-row"))
        for item in options.flatMap(\.days).flatMap(\.items) {
            XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: item.exerciseID, equipment: request.equipment))
        }
    }

    func testMachineWhitelistRequiresEachActualMachine() throws {
        let request = input(weekdays: [1, 2, 3, 4, 5], equipment: [.bodyweight, .legPress, .latPulldown, .stationaryBike])
        let options = try PlannerEngine.options(for: request)
        let option = try XCTUnwrap(options.first { $0.id == "equipment-first" })
        let ids = Set(option.days.flatMap(\.items).map(\.exerciseID))
        XCTAssertTrue(ids.contains("builtin.leg-press"))
        XCTAssertTrue(ids.contains("builtin.lat-pulldown"))
        XCTAssertTrue(ids.contains("builtin.stationary-cycling"))
        XCTAssertFalse(ids.contains("builtin.seated-cable-row"))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.leg-press", equipment: [.legCurl]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.stationary-cycling", equipment: [.bodyweight]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "invented.machine", equipment: Set(PlanningEquipment.allCases)))
        for item in options.flatMap(\.days).flatMap(\.items) {
            XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: item.exerciseID, equipment: request.equipment))
        }
    }

    func testResistanceDaysAreNeverAdjacentIncludingSundayAndMonday() throws {
        for weekdays in [[1, 7], [1, 2, 3, 4, 5, 6, 7], [2, 3, 6, 7]] {
            for option in try PlannerEngine.options(for: input(weekdays: weekdays)) {
                let days = resistanceDays(option)
                XCTAssertLessThanOrEqual(days.count, 3)
                for (index, first) in days.enumerated() {
                    for second in days.dropFirst(index + 1) {
                        let distance = abs(first - second)
                        XCTAssertGreaterThanOrEqual(min(distance, 7 - distance), 2)
                    }
                }
            }
        }
    }

    func testMoreThanThreeSelectedDaysIncludeLightCardioAndNoMixedDays() throws {
        for count in 4...7 {
            let request = input(weekdays: Array(1...count))
            for option in try PlannerEngine.options(for: request) {
                let cardioDays = option.days.filter { trainingDay in
                    !trainingDay.items.isEmpty && trainingDay.items.allSatisfy {
                        ExerciseCatalog.exercise(id: $0.exerciseID)?.kind == .cardio
                    }
                }
                XCTAssertFalse(cardioDays.isEmpty)
                XCTAssertEqual(cardioDays.count + resistanceDays(option).count, count)
                for trainingDay in cardioDays {
                    XCTAssertEqual(trainingDay.items.count, 1)
                    XCTAssertEqual(trainingDay.items[0].setCount, 1)
                    XCTAssertEqual(trainingDay.items[0].restSeconds, 0)
                }
            }
        }
    }

    func testMissingCardioSpaceOrMachineFailsRatherThanInventingFeasibility() throws {
        XCTAssertThrowsError(try PlannerEngine.options(for: input(weekdays: [1, 2, 3, 4, 5], equipment: [.bodyweight])))
        XCTAssertThrowsError(try PlannerEngine.options(for: input(weekdays: [1, 7], equipment: [.dumbbells, .bench])))
        XCTAssertNoThrow(try PlannerEngine.options(for: input(weekdays: [1], equipment: [.bodyweight])))
        XCTAssertNoThrow(try PlannerEngine.options(for: input(weekdays: [1, 2, 3, 4, 5], equipment: [.bodyweight, .stationaryBike])))
    }

    func testBikeOnlyIsFeasibleForEnduranceButDoesNotInventFloorSpaceForResistance() throws {
        let cardio = input(weekdays: [2, 5], equipment: [.stationaryBike], goal: .endurance)
        for option in try PlannerEngine.options(for: cardio) {
            XCTAssertEqual(option.days.filter { !$0.isRestDay }.count, 2)
            XCTAssertTrue(option.days.flatMap(\.items).allSatisfy { $0.exerciseID == "builtin.stationary-cycling" })
        }
        XCTAssertThrowsError(try PlannerEngine.options(for: input(weekdays: [1], equipment: [.stationaryBike])))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.bodyweight-squat", equipment: [.stationaryBike]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.glute-bridge", equipment: [.bench]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.dead-bug", equipment: [.walkingSpace]))
    }

    func testOnlyOneRemainingResistancePatternFailsInsteadOfPresentingCompleteWorkout() throws {
        var request = input(weekdays: [1], equipment: [.bodyweight])
        // The fixture is about remaining movement patterns, not a frozen list of catalogue IDs.
        // A newly reviewed core variant must not accidentally make this a two-pattern request.
        request.excludedExerciseIDs = PlannerEngine.movements.filter { $0.pattern != .push }.map(\.id)
        XCTAssertEqual(try PlannerEngine.candidatePool(input: request).keys.sorted(), ["push"])
        XCTAssertThrowsError(try PlannerEngine.options(for: request))
    }

    func testNewCoreVariantRemainsAvailableWhenOtherCoreVariantsAreExcluded() throws {
        var request = input(weekdays: [1], equipment: [.bodyweight])
        request.excludedExerciseIDs = ["builtin.bodyweight-squat", "builtin.glute-bridge", "builtin.dead-bug",
                                       "builtin.bird-dog", "builtin.plank"]
        let pool = try PlannerEngine.candidatePool(input: request)
        XCTAssertEqual(pool["core"], ["builtin.high-plank"])
        for option in try PlannerEngine.options(for: request) {
            XCTAssertTrue(option.days.flatMap(\.items).contains { $0.exerciseID == "builtin.high-plank" })
        }
    }

    func testUncalibratedRowingOnlyCannotBecomeAutomaticCardio() throws {
        let request = input(weekdays: [1], equipment: [.rowingErgometer], goal: .endurance)
        XCTAssertThrowsError(try PlannerEngine.options(for: request))
        XCTAssertNoThrow(try PlannerEngine.options(for: input(weekdays: [1], equipment: [.rowingErgometer],
                                                            goal: .endurance, experience: .regular)))
    }

    func testUnknownSafetyPainAndUnconfirmedAdultAreRejected() throws {
        for safety in [PlanningSafety.unknown, .hasRestrictions, .acuteSymptoms] {
            var request = input(); request.safety = safety
            XCTAssertThrowsError(try PlannerEngine.options(for: request))
        }
        let painStates: [Bool?] = [nil, true]
        for pain in painStates {
            var request = input(); request.painToday = pain
            XCTAssertThrowsError(try PlannerEngine.options(for: request))
        }
        var minor = input(); minor.adultConfirmed = false
        XCTAssertThrowsError(try PlannerEngine.options(for: minor))
    }

    func testInvalidWeekdaysTimesEquipmentAndHistoryAreRejected() throws {
        for weekdays in [[], [0], [8], [1, 1]] {
            XCTAssertThrowsError(try PlannerEngine.options(for: input(weekdays: weekdays)))
        }
        for minutes in [0, 14, 121] {
            XCTAssertThrowsError(try PlannerEngine.options(for: input(minutes: minutes)))
        }
        XCTAssertThrowsError(try PlannerEngine.options(for: input(equipment: [])))
        var request = input(); request.completedSessionsLast28Days = -1
        XCTAssertThrowsError(try request.validate())
        request = input(); request.daysSinceLastTraining = -1
        XCTAssertThrowsError(try request.validate())
    }

    func testExcludedIDsMustExistBeUniqueAndNeverAppearInOptions() throws {
        var request = input()
        request.excludedExerciseIDs = ["invented.exercise"]
        XCTAssertThrowsError(try PlannerEngine.options(for: request))
        request.excludedExerciseIDs = ["builtin.bodyweight-squat", "builtin.bodyweight-squat"]
        XCTAssertThrowsError(try PlannerEngine.options(for: request))
        request.excludedExerciseIDs = ["builtin.bodyweight-squat", "builtin.dead-bug"]
        for option in try PlannerEngine.options(for: request) {
            XCTAssertTrue(Set(option.days.flatMap(\.items).map(\.exerciseID)).isDisjoint(with: request.excludedExerciseIDs))
        }
    }

    func testExcludingAllFeasibleCardioIsExplicitFailure() throws {
        var request = input(weekdays: [1, 2, 3, 4, 5])
        request.excludedExerciseIDs = ["builtin.walking"]
        XCTAssertThrowsError(try PlannerEngine.options(for: request))
    }

    func testUnknownWeightStaysUnknownWhenGeneratedDoseBecomesWorkout() throws {
        var snapshot = baseSnapshot()
        snapshot.profile.weightKG = nil
        let draft = try PlanningDraft.make(input: input(equipment: [.dumbbells, .bench, .walkingSpace]), snapshot: snapshot, at: now)
        let option = try XCTUnwrap(draft.options.first)
        let trainingDay = try XCTUnwrap(option.days.first { !$0.isRestDay })
        let items = try trainingDay.items.map { item in
            PlannedExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: item.exerciseID)),
                            setCount: item.setCount, targetReps: item.targetReps,
                            targetSeconds: item.targetSeconds, restSeconds: item.restSeconds)
        }
        let plan = PlanVersion(name: trainingDay.title, items: items, confirmedAt: now)
        let session = try WorkoutSession.start(plan: plan, at: now)
        XCTAssertNil(draft.sourceProfile.weightKG)
        for set in session.exercises.flatMap(\.sets) {
            XCTAssertNil(set.loadKG)
            XCTAssertNil(set.rpe)
            XCTAssertNil(set.rir)
            XCTAssertNil(set.completedAt)
        }
    }

    func testAISelectionAcceptsOnlyExistingOptionAndRealEvidenceIDs() throws {
        let options = try PlannerEngine.options(for: input())
        let option = try XCTUnwrap(options.first)
        let data = try selectionData(optionID: option.id, evidence: ["request", "history", "rules", "option:\(option.id)"])
        XCTAssertEqual(try AISelection.decode(data: data, options: options).optionID, option.id)
        XCTAssertThrowsError(try AISelection.decode(data: selectionData(optionID: "invented.option"), options: options))
        for evidence in [["sleep:invented"], ["option:invented"], ["exercise:invented"]] {
            XCTAssertThrowsError(try AISelection.decode(data: selectionData(optionID: option.id, evidence: evidence), options: options))
        }
    }

    func testAIUnknownFieldsAndDoseInjectionAreRejected() throws {
        let options = try PlannerEngine.options(for: input())
        let option = try XCTUnwrap(options.first)
        let injectedFields: [[String: Any]] = [["items": [["exerciseID": "builtin.push-up", "setCount": 99]]],
                                               ["targetReps": 100], ["loadKG": 120], ["days": []], ["unexpected": true]]
        for extra in injectedFields {
            XCTAssertThrowsError(try AISelection.decode(data: selectionData(optionID: option.id, extra: extra), options: options))
        }
        let encoded = try selectionData(optionID: option.id)
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        missing.removeValue(forKey: "limitations")
        XCTAssertThrowsError(try AISelection.decode(data: JSONSerialization.data(withJSONObject: missing), options: options))
        XCTAssertThrowsError(try AISelection.decode(data: Data(), options: options))
        XCTAssertThrowsError(try AISelection.decode(data: Data(repeating: 32, count: 128 * 1_024 + 1), options: options))
    }

    func testOptionValidatorRejectsDoseEquipmentScheduleAndTimeTampering() throws {
        let request = input(weekdays: [1], minutes: 30)
        let original = try XCTUnwrap(PlannerEngine.options(for: request).first)
        let index = try XCTUnwrap(original.days.firstIndex { !$0.isRestDay })
        var changed = original; changed.days[index].items[0].setCount = 99
        XCTAssertThrowsError(try changed.validate(input: request))
        changed = original; changed.days[index].items[0].restSeconds = .nan
        XCTAssertThrowsError(try changed.validate(input: request))
        changed = original; changed.days[index].items[0].exerciseID = "builtin.leg-press"
        XCTAssertThrowsError(try changed.validate(input: request))
        changed = original; changed.days[index].estimatedMinutesUpper = 1
        XCTAssertThrowsError(try changed.validate(input: request))
        changed = original; changed.days.swapAt(0, 1)
        XCTAssertThrowsError(try changed.validate(input: request))
    }

    func testDraftRejectsExistingProfileRestrictionsAndMinorDespiteFreshDeclaration() throws {
        var snapshot = baseSnapshot()
        snapshot.profile.restrictions = "膝痛，避免负重深蹲"
        XCTAssertThrowsError(try PlanningDraft.make(input: input(), snapshot: snapshot, at: now))
        snapshot.profile.restrictions = "无，但膝痛"
        XCTAssertThrowsError(try PlanningDraft.make(input: input(), snapshot: snapshot, at: now))
        snapshot.profile.restrictions = ""
        snapshot.profile.birthYear = 2015
        XCTAssertThrowsError(try PlanningDraft.make(input: input(), snapshot: snapshot, at: now))
        snapshot.profile.birthYear = 1990
        XCTAssertNoThrow(try PlanningDraft.make(input: input(), snapshot: snapshot, at: now))
    }

    func testExplicitNoRestrictionDeclarationsDoNotConflictWithDraft() throws {
        for declaration in ["", "无", "无已知限制", "无运动限制", "没有已知限制", " none "] {
            var snapshot = baseSnapshot(); snapshot.profile.restrictions = declaration
            let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
            XCTAssertNoThrow(try draft.validate())
            XCTAssertEqual(draft.sourceProfile, snapshot.profile)
            XCTAssertTrue(draft.matches(snapshot: snapshot, at: now))
        }
    }

    func testEmptyEndedOrSkippedSessionsDoNotFabricateTrainingHistory() throws {
        var snapshot = baseSnapshot()
        let emptyCompleted = try trainingSession(start: now.addingTimeInterval(-600), completedResult: false)
        let emptyEarly = try trainingSession(start: now.addingTimeInterval(-900), completedResult: false, early: true)
        var skippedMovement = try trainingSession(start: now.addingTimeInterval(-1_200))
        skippedMovement.exercises[0].skipped = true
        var active = WorkoutSession(name: "未结束测试夹具", startedAt: now.addingTimeInterval(-300),
                                    exercises: [WorkoutExercise(exercise: try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bodyweight-squat")),
                                                                  sets: [LoggedSet(reps: 8)])])
        try active.completeSet(exerciseID: active.exercises[0].id, setID: active.exercises[0].sets[0].id,
                               at: now.addingTimeInterval(-240))
        snapshot.sessions = [emptyCompleted, emptyEarly, skippedMovement, active]
        var request = input(); request.completedSessionsLast28Days = 999; request.daysSinceLastTraining = 1
        let draft = try PlanningDraft.make(input: request, snapshot: snapshot, at: now)
        XCTAssertEqual(draft.input.completedSessionsLast28Days, 0)
        XCTAssertNil(draft.input.daysSinceLastTraining)
    }

    func testActualHistoryCountsResultsRatherThanUserSuppliedSummary() throws {
        var snapshot = baseSnapshot()
        snapshot.sessions = [try trainingSession(start: now.addingTimeInterval(-2 * day - 120), early: true),
                             try trainingSession(start: now.addingTimeInterval(-7 * day)),
                             try trainingSession(start: now.addingTimeInterval(-30 * day)),
                             try trainingSession(start: now.addingTimeInterval(-300), completedResult: false)]
        var request = input(); request.completedSessionsLast28Days = 999; request.daysSinceLastTraining = 999
        let draft = try PlanningDraft.make(input: request, snapshot: snapshot, at: now)
        XCTAssertEqual(draft.input.completedSessionsLast28Days, 2)
        XCTAssertEqual(draft.input.daysSinceLastTraining, 2)
        XCTAssertEqual(draft.sourceSessionRevisions.count, 4)
    }

    func testHistoryWindowBoundaryAndFutureSessionsAreHandledExplicitly() throws {
        var snapshot = baseSnapshot()
        snapshot.sessions = [try trainingSession(start: now.addingTimeInterval(-28 * day)),
                             try trainingSession(start: now.addingTimeInterval(-28 * day - 1)),
                             try trainingSession(start: now.addingTimeInterval(3_600))]
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        XCTAssertEqual(draft.input.completedSessionsLast28Days, 1)
        XCTAssertEqual(draft.input.daysSinceLastTraining, 27)
    }

    func testDraftExpiresAfterSevenDaysAndRejectsExcessiveBackwardClock() throws {
        let snapshot = baseSnapshot()
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        XCTAssertTrue(draft.matches(snapshot: snapshot, at: now.addingTimeInterval(7 * day)))
        XCTAssertFalse(draft.matches(snapshot: snapshot, at: now.addingTimeInterval(7 * day + 1)))
        XCTAssertFalse(draft.matches(snapshot: snapshot, at: now.addingTimeInterval(-301)))
    }

    func testProfileOrActivePointerChangeMakesDraftStale() throws {
        let snapshot = baseSnapshot()
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        var changed = snapshot; changed.profile.minutesPerSession = 15
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
        changed = snapshot; changed.activePlanVersionID = UUID()
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
        changed = snapshot; changed.activeWeeklyProgramID = UUID()
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
        XCTAssertTrue(draft.matches(snapshot: snapshot, at: now))
    }

    func testSessionRevisionAdditionOrRemovalMakesDraftStale() throws {
        var snapshot = baseSnapshot()
        snapshot.sessions = [try trainingSession(start: now.addingTimeInterval(-day))]
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        var changed = snapshot; changed.sessions[0].revision += 1
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
        changed = snapshot; changed.sessions.removeAll()
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
        changed = snapshot; changed.sessions.append(try trainingSession(start: now.addingTimeInterval(-600)))
        XCTAssertFalse(draft.matches(snapshot: changed, at: now))
    }

    func testChangedRealHistoryOutsideRecentTenStillMakesDraftStale() throws {
        var snapshot = baseSnapshot()
        snapshot.sessions = try (1...11).map { try trainingSession(start: now.addingTimeInterval(-Double($0) * day)) }
        let draft = try PlanningDraft.make(input: input(), snapshot: snapshot, at: now)
        XCTAssertEqual(draft.sourceSessionRevisions.count, 10)
        XCTAssertEqual(draft.input.completedSessionsLast28Days, 11)
        snapshot.sessions[10].exercises[0].sets[0].completedAt = nil
        XCTAssertFalse(draft.matches(snapshot: snapshot, at: now))
    }

    func testDraftRejectsTamperedCandidateAndConflictingFrozenProfile() throws {
        let draft = try PlanningDraft.make(input: input(), snapshot: baseSnapshot(), at: now)
        var changed = draft; changed.options[0].days[0].items[0].setCount = 99
        XCTAssertThrowsError(try changed.validate())
        changed = draft; changed.options[0].title = "篡改标题也不能冒充原候选"
        XCTAssertThrowsError(try changed.validate())
        changed = draft; changed.sourceProfile.restrictions = "不能负重"
        XCTAssertThrowsError(try changed.validate())
        changed = draft; changed.sourceProfile.birthYear = 2015
        XCTAssertThrowsError(try changed.validate())
        changed = draft; changed.sourceSessionRevisions = ["not-a-uuid": 0]
        XCTAssertThrowsError(try changed.validate())
    }

    func testDraftAISelectionRequiresActualProviderAndModelPair() throws {
        var draft = try PlanningDraft.make(input: input(), snapshot: baseSnapshot(), at: now)
        draft.selection = AISelection(optionID: try XCTUnwrap(draft.options.first).id,
                                      explanation: "依据候选选择", evidence: ["rules"], limitations: [])
        XCTAssertThrowsError(try draft.validate())
        draft.providerHost = "api.example.test"
        XCTAssertThrowsError(try draft.validate())
        draft.model = "test-model"
        XCTAssertNoThrow(try draft.validate())
    }

    func testWeeklyProgramRequiresCompleteUniqueDayVersionMapping() throws {
        let (_, program) = try confirmedProgramSnapshot()
        XCTAssertNoThrow(try program.validate())
        let weekday = try XCTUnwrap(program.dayPlanVersionIDs.keys.sorted().first)
        var changed = program; changed.dayPlanVersionIDs.removeValue(forKey: weekday)
        XCTAssertThrowsError(try changed.validate())
        changed = program; changed.dayPlanVersionIDs[2] = UUID()
        XCTAssertThrowsError(try changed.validate())
        changed = program
        let otherDay = try XCTUnwrap(program.dayPlanVersionIDs.keys.sorted().last)
        changed.dayPlanVersionIDs[otherDay] = program.dayPlanVersionIDs[weekday]
        XCTAssertThrowsError(try changed.validate())
        changed = program; changed.selectedOptionID = "invented.option"
        XCTAssertThrowsError(try changed.validate())
    }

    func testSnapshotRejectsMissingDayVersionAndDoseChangedAfterConfirmation() throws {
        let (snapshot, _) = try confirmedProgramSnapshot()
        var changed = snapshot; changed.planVersions.removeLast()
        XCTAssertThrowsError(try changed.validate())
        changed = snapshot; changed.planVersions[0].items[0].setCount += 1
        XCTAssertThrowsError(try changed.validate())
        changed = snapshot; changed.planningDrafts?[0].decision = .rejected
        XCTAssertThrowsError(try changed.validate())
    }

    func testPlanningSnapshotRoundTripPreservesFrozenProgramAndInputs() throws {
        let (snapshot, program) = try confirmedProgramSnapshot()
        let restored = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored.weeklyPrograms?.first, program)
        XCTAssertEqual(restored.weeklyPrograms?.first?.draft.input, program.draft.input)
        XCTAssertTrue(restored.sessions.isEmpty)
    }
}
