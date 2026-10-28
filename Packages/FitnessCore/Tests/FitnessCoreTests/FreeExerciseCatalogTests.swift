import Foundation
import XCTest
@testable import FitnessCore

final class FreeExerciseCatalogTests: XCTestCase {
    func testEverySourceIDAndBothAvailableDemonstratorsResolveWithoutInventedVariants() throws {
        XCTAssertEqual(FreeExerciseCatalog.records.count, 317)
        XCTAssertEqual(FreeExerciseCatalog.sourceToExerciseID.count, 317)
        var ids = Set<String>()
        var variants = Set<String>()
        var male = 0, female = 0
        for record in FreeExerciseCatalog.records {
            XCTAssertTrue(ids.insert(record.sourceID).inserted)
            let exercise = try XCTUnwrap(ExerciseCatalog.exercise(id: record.exerciseID))
            XCTAssertEqual(FreeExerciseCatalog.sourceToExerciseID[record.sourceID], exercise.id)
            XCTAssertTrue(record.name.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } })
            XCTAssertEqual(record.metadataLicense, "MIT")
            XCTAssertEqual(record.videoAuthorizationBasis, "userConfirmed")
            let demos = FreeExerciseCatalog.mediaVariants(for: exercise.id)
            XCTAssertEqual(demos.count, record.videos.count)
            XCTAssertEqual(FreeExerciseCatalog.sourceRecords(for: exercise.id), [record])
            for demo in demos {
                XCTAssertTrue(variants.insert(demo.id).inserted)
                XCTAssertTrue(demo.media.fileName.hasPrefix("fed-" + record.sourceID + "-"))
                XCTAssertTrue(record.videos.values.contains(demo.media.sourceURL))
                XCTAssertEqual(demo.media.licenseName, "视频使用由本人确认")
                XCTAssertEqual(demo.media.kind, .video)
                if demo.id.hasSuffix(".male") { male += 1 }
                if demo.id.hasSuffix(".female") { female += 1 }
            }
        }
        XCTAssertEqual(variants.count, 593)
        XCTAssertEqual(male, 290)
        XCTAssertEqual(female, 303)
        XCTAssertTrue(FreeExerciseCatalog.mediaVariants(for: "invented-by-ai").isEmpty)
    }

    func testExisting222DefinitionsSurviveAndOnlyExplicitMappingReusesTheirIDs() throws {
        let legacy = ExerciseCatalog.exercises.filter { $0.id.hasPrefix("builtin.") }
        XCTAssertEqual(legacy.count, 222)
        XCTAssertEqual(FreeExerciseCatalog.records.filter { !$0.isNew }.count, 72)
        XCTAssertEqual(FreeExerciseCatalog.exercises.count, 245)
        XCTAssertEqual(ExerciseCatalog.exercises.count, 467)
        XCTAssertEqual(Set(ExerciseCatalog.exercises.map(\.id)).count, 467)
        XCTAssertEqual(Set(ExerciseCatalog.exercises.map(\.name)).count, 467)
        let mapped = try XCTUnwrap(FreeExerciseCatalog.records.first { $0.sourceID == "0025" })
        XCTAssertEqual(mapped.exerciseID, "builtin.barbell-bench-press")
        let bench = try XCTUnwrap(ExerciseCatalog.exercise(id: mapped.exerciseID))
        XCTAssertEqual(bench.name, "杠铃卧推")
        XCTAssertEqual(bench.loadConvention, .total)
        XCTAssertFalse(bench.instructions.first?.contains("上游英文") ?? true)
        XCTAssertNotNil(ExerciseDetails.legacyMedia(for: bench.id))
        XCTAssertTrue(ExerciseDetails.details(for: bench.id)?.media?.fileName.hasPrefix("fed-0025-") ?? false)
    }

    func testSameSourceNamesAndDifferentGripsRemainSeparateStableIdentities() throws {
        for pair in [["drv-45-degree-bycicle-twisting-crunch", "drv-45-degree-bycicle-twisting-crunch-1"],
                     ["drv-stretching-bridge-pose-setu-bandhasana", "drv-stretching-bridge-pose-setu-bandhasana-1"],
                     ["drv-sit-ups", "drv-sit-up"], ["0208", "0218"], ["0318", "0322"]] {
            let first = try XCTUnwrap(FreeExerciseCatalog.sourceToExerciseID[pair[0]])
            let second = try XCTUnwrap(FreeExerciseCatalog.sourceToExerciseID[pair[1]])
            XCTAssertNotEqual(first, second)
            XCTAssertNotEqual(ExerciseCatalog.exercise(id: first)?.name, ExerciseCatalog.exercise(id: second)?.name)
        }
    }

    func testImportedGuidanceRetainsItsActualEnglishOriginAndNeverClaimsPersonalClearance() throws {
        for record in FreeExerciseCatalog.records where record.isNew {
            let movement = try XCTUnwrap(ExerciseCatalog.exercise(id: record.exerciseID))
            try movement.validate()
            XCTAssertEqual(Array(movement.instructions.dropFirst()), record.steps)
            XCTAssertTrue(movement.instructions[0].contains("上游英文"))
            XCTAssertTrue(movement.instructions[0].contains("未完成"))
            XCTAssertFalse(record.steps.isEmpty)
            let source = try XCTUnwrap(ExerciseDetails.contentSource(for: movement.id))
            XCTAssertEqual(source.originalDescription, record.originalInstructions)
            XCTAssertEqual(source.licenseName, "MIT")
            XCTAssertTrue(ExerciseDetails.matches(movement, query: record.englishName))
            XCTAssertFalse(PlannerEngine.movements.contains { $0.id == movement.id }, "Metadata imports must not invent safe prescription constraints")
        }
        let pull = try XCTUnwrap(FreeExerciseCatalog.records.first { $0.sourceID == "0970" })
        XCTAssertEqual(pull.muscle, "背阔肌", "Upstream muscleGroup incorrectly says biceps; use reviewed movement target")
    }

    func testImportedManualPlanAndDemonstrationMetadataSurviveCodableRoundTrip() throws {
        let exercise = try XCTUnwrap(FreeExerciseCatalog.exercises.first)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let plan = PlanVersion(name: "隔离手动计划", items: [PlannedExercise(exercise: exercise)], confirmedAt: date)
        try plan.validate()
        let decoded = try JSONDecoder().decode(PlanVersion.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertEqual(decoded.items.first?.exercise, exercise)
        let detail = try XCTUnwrap(ExerciseDetails.details(for: exercise.id))
        XCTAssertEqual(try JSONDecoder().decode(ExerciseDetail.self, from: JSONEncoder().encode(detail)), detail)
    }
}
