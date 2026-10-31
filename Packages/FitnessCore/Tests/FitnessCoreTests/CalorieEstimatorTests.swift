import XCTest
import Foundation
@testable import FitnessCore

/// Calorie figures are easy to fake and easy to over-trust. These tests pin the two rules that keep
/// the number honest: no invented body weight, and no precision the method cannot support.
final class CalorieEstimatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func exercise(_ id: String = "builtin.barbell-bench-press") throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.exercise(id: id))
    }

    private func profile(weight: Double?) -> StructuredProfile {
        var value = StructuredProfile()
        if let weight {
            value.weightKG = .init(value: weight, provenance: .stated, confirmedAt: now)
        }
        return value
    }

    // MARK: - The one rule that matters most

    func testUnknownBodyWeightProducesNoNumberAtAll() throws {
        let item = PlannedExercise(exercise: try exercise(), setCount: 3, targetReps: 10, restSeconds: 90)
        let plan = PlanVersion(name: "上肢", items: [item], confirmedAt: now)
        XCTAssertNil(CalorieEstimator.bodyWeightKG(profile(weight: nil)))
        XCTAssertNil(CalorieEstimator.estimate(plan: plan, weightKG: nil),
                     "体重未知时不能编造一个数字")
        XCTAssertNil(CalorieEstimator.estimate(exercise: item.exercise, sets: 3, targetReps: 10,
                                               targetSeconds: nil, restSeconds: 90, weightKG: nil))
    }

    func testUnusableProvenanceIsTreatedAsUnknown() {
        var value = StructuredProfile()
        // An AI guess is not a fact; it must not become a calorie baseline.
        value.weightKG = .init(value: 70, provenance: .inferred)
        XCTAssertNil(CalorieEstimator.bodyWeightKG(value))
    }

    // MARK: - Reasonable magnitudes

    func testAThreeSetStrengthMovementLandsInAPlausibleRange() throws {
        let kcal = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: try exercise(), sets: 3, targetReps: 10, targetSeconds: nil,
            restSeconds: 90, weightKG: 70))
        // 3 sets x 10 reps x 4s = 2 min work + 3 min rest at 35% -> ~5.7 MET-min at 70 kg.
        XCTAssertGreaterThanOrEqual(kcal, 5)
        XCTAssertLessThanOrEqual(kcal, 60, "单个动作不该出现夸张数字")
        XCTAssertEqual(kcal % 5, 0, "只精确到 5 千卡，不假装更准")
    }

    func testHeavierPersonBurnsMoreForTheSameWork() throws {
        let light = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: try exercise(), sets: 3, targetReps: 10, targetSeconds: nil,
            restSeconds: 90, weightKG: 60))
        let heavy = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: try exercise(), sets: 3, targetReps: 10, targetSeconds: nil,
            restSeconds: 90, weightKG: 90))
        XCTAssertGreaterThan(heavy, light)
    }

    func testCardioBurnsMoreThanAnEquivalentStrengthBlock() throws {
        let bench = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: try exercise("builtin.barbell-bench-press"), sets: 3, targetReps: 10,
            targetSeconds: nil, restSeconds: 90, weightKG: 70))
        let walk = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: try exercise("builtin.walking"), sets: 1, targetReps: nil,
            targetSeconds: 1_800, restSeconds: 0, weightKG: 70))
        XCTAssertGreaterThan(walk, bench)
    }

    // MARK: - Nothing is invented from a missing target

    func testMissingTargetYieldsNoNumber() throws {
        XCTAssertNil(CalorieEstimator.estimate(exercise: try exercise(), sets: 3, targetReps: nil,
                                               targetSeconds: nil, restSeconds: 90, weightKG: 70))
        XCTAssertNil(CalorieEstimator.estimate(exercise: try exercise(), sets: 0, targetReps: 10,
                                               targetSeconds: nil, restSeconds: 90, weightKG: 70))
    }

    // MARK: - Whole-plan total

    func testPlanTotalSumsOnlyMovementsItCanEstimate() throws {
        let known = PlannedExercise(exercise: try exercise(), setCount: 3, targetReps: 10, restSeconds: 90)
        let unknown = PlannedExercise(exercise: try exercise("builtin.dead-bug"), setCount: 3,
                                      targetReps: nil, targetSeconds: nil, restSeconds: 60)
        let plan = PlanVersion(name: "混合", items: [known, unknown], confirmedAt: now)
        let total = try XCTUnwrap(CalorieEstimator.estimate(plan: plan, weightKG: 70))
        let onlyKnown = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: known.exercise, sets: 3, targetReps: 10, targetSeconds: nil,
            restSeconds: 90, weightKG: 70))
        XCTAssertEqual(total, onlyKnown, "无法估算的动作不计入，而不是按零或猜测计入")
    }

    func testSessionTotalUsesCompletedSetsOnly() throws {
        let move = try exercise()
        let done = (0..<3).map { index in
            LoggedSet(reps: 10, loadKG: 20,
                      completedAt: index < 2 ? now.addingTimeInterval(Double(index) * 120) : nil)
        }
        var session = WorkoutSession(name: "上肢", startedAt: now.addingTimeInterval(-1_800),
                                     exercises: [WorkoutExercise(exercise: move, sets: done, restSeconds: 90)])
        try session.finish(early: false, at: now)

        let twoSets = try XCTUnwrap(CalorieEstimator.estimate(session: session, weightKG: 70))
        let threeSets = try XCTUnwrap(CalorieEstimator.estimate(
            exercise: move, sets: 3, targetReps: 10, targetSeconds: nil, restSeconds: 90, weightKG: 70))
        XCTAssertLessThan(twoSets, threeSets, "未完成的组不能计入消耗")
    }

    func testEmptySessionHasNoEstimate() throws {
        var session = WorkoutSession(name: "空", startedAt: now.addingTimeInterval(-600),
                                     exercises: [WorkoutExercise(exercise: try exercise(),
                                                                 sets: [LoggedSet(reps: 10)])])
        try session.finish(early: false, at: now)
        XCTAssertNil(CalorieEstimator.estimate(session: session, weightKG: 70))
    }

    // MARK: - Honesty in the UI copy

    func testDisclaimerStatesItIsAnEstimate() {
        XCTAssertTrue(CalorieEstimator.disclaimer.contains("估算"))
        XCTAssertTrue(CalorieEstimator.disclaimer.contains("不是实测"))
    }
}
