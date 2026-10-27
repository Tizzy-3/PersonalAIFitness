import Foundation
import XCTest
@testable import FitnessCore

final class ExpandedCatalogQualityTests: XCTestCase {
    private func exercise(_ slug: String) throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.\(slug)"))
    }

    func testNamedVariantsHaveSpecificEquipmentAndTargetMuscles() throws {
        let lateral = try exercise("machine-lateral-raise")
        XCTAssertEqual(lateral.equipment, "侧平举机")
        XCTAssertEqual(lateral.muscle, "肩中束")
        XCTAssertEqual(lateral.loadConvention, .total)
        XCTAssertEqual(try exercise("back-extension").muscle, "竖脊肌")
        XCTAssertEqual(try exercise("incline-reverse-fly").muscle, "肩后束")
        XCTAssertEqual(try exercise("dumbbell-front-raise").equipment, "哑铃")
        XCTAssertEqual(try exercise("barbell-shrug").muscle, "斜方肌")
        XCTAssertEqual(try exercise("wall-sit").muscle, "股四头肌")
        XCTAssertEqual(try exercise("pallof-press").muscle, "腹斜肌")
        XCTAssertEqual(try exercise("medicine-ball-twist").equipment, "药球、平整地面")
        let rearFly = try XCTUnwrap(ExerciseDetails.details(for: "builtin.incline-reverse-fly"))
        XCTAssertEqual(rearFly.secondaryMuscles, ["菱形肌", "斜方肌"])
        XCTAssertEqual(rearFly.movementPattern, "水平外展")
        XCTAssertEqual(ExerciseDetails.details(for: lateral.id)?.movementPattern, "肩外展")
    }

    func testBilateralFreeWeightsAndCableStacksHaveExplicitRecordingConventions() throws {
        for slug in ["arnold-press", "double-kettlebell-front-squat", "incline-reverse-fly",
                     "dumbbell-front-squat", "concentration-curl", "incline-cable-fly", "seated-cable-fly"] {
            XCTAssertEqual(try exercise(slug).loadConvention, .perHand, slug)
        }
        for slug in ["weighted-step-up", "cable-crunch", "machine-crunch"] {
            XCTAssertEqual(try exercise(slug).kind, .strength, slug)
            XCTAssertEqual(try exercise(slug).loadConvention, .total, slug)
        }
        XCTAssertEqual(try exercise("dumbbell-sumo-deadlift").equipment, "单只哑铃")
        XCTAssertEqual(try exercise("dumbbell-sumo-deadlift").loadConvention, .total)
        XCTAssertEqual(try exercise("assisted-dip").loadConvention, .assistance)
        XCTAssertEqual(try exercise("single-leg-calf-raise").loadConvention, .bodyweight)
    }

    func testExtensionHasUniqueIDsAndNoEquipmentPlaceholders() throws {
        let added = ExpandedExerciseCatalog.exercises
        XCTAssertEqual(added.count, 151)
        XCTAssertEqual(Set(added.map(\.id)).count, 151)
        XCTAssertEqual(ExerciseCatalog.exercises.count, 217)
        XCTAssertEqual(Set(ExerciseCatalog.exercises.map(\.id)).count, 217)
        for movement in added {
            XCTAssertFalse(movement.equipment.contains("按实际"), movement.id)
            XCTAssertFalse(movement.equipment.contains("按变式"), movement.id)
            let detail = try XCTUnwrap(ExerciseDetails.details(for: movement.id))
            XCTAssertFalse(detail.secondaryMuscles.contains(movement.muscle), movement.id)
        }
    }

    func testMismatchedTeachingImagesAreNotDisplayedForDifferentVariants() {
        for slug in ["smith-incline-press", "rack-pull", "side-crunch", "decline-barbell-press"] {
            XCTAssertNil(ExerciseDetails.details(for: "builtin.\(slug)")?.media, slug)
            // Removing a display binding must not erase the licensed source.
            XCTAssertNotNil(ExerciseDetails.contentSource(for: "builtin.\(slug)"), slug)
        }
    }

    func testCheckedInJSONMatchesEveryCompiledExtensionField() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Data/exercise-catalog-extension.json"))
        let rows = try JSONDecoder().decode([CatalogRow].self, from: data)
        XCTAssertEqual(rows.count, ExpandedExerciseCatalog.exercises.count)
        for (row, movement) in zip(rows, ExpandedExerciseCatalog.exercises) {
            XCTAssertEqual(row.id, movement.id)
            XCTAssertEqual(row.name, movement.name)
            XCTAssertEqual(row.englishName, movement.englishName)
            XCTAssertEqual(row.kind, movement.kind.rawValue)
            XCTAssertEqual(row.metric, movement.metric.rawValue)
            XCTAssertEqual(row.equipment, movement.equipment)
            XCTAssertEqual(row.muscle, movement.muscle)
            XCTAssertEqual(row.loadConvention, movement.loadConvention.rawValue)
            XCTAssertEqual(row.instructions, movement.instructions)
            let detail = try XCTUnwrap(ExpandedExerciseCatalog.details[row.id])
            XCTAssertEqual(row.aliases, detail.aliases)
            XCTAssertEqual(row.secondaryMuscles, detail.secondaryMuscles)
            XCTAssertEqual(row.movementPattern, detail.movementPattern)
            XCTAssertEqual(row.difficulty, detail.difficulty)
            XCTAssertEqual(row.commonMistakes, detail.commonMistakes)
        }
    }

    private struct CatalogRow: Decodable {
        let id, name, englishName, kind, metric, equipment, muscle, loadConvention: String
        let instructions, aliases, secondaryMuscles: [String]
        let movementPattern, difficulty: String
        let commonMistakes: [String]
    }
}
