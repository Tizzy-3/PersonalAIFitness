import XCTest
@testable import FitnessCore

final class ExerciseLibraryTests: XCTestCase {
    func testStableLegacyIdentitiesAndRecordingConventionsRemainAvailable() throws {
        let perHand = ["dumbbell-bench-press", "incline-dumbbell-press", "dumbbell-shoulder-press", "dumbbell-row", "dumbbell-rdl", "dumbbell-curl"]
        for slug in perHand { XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.\(slug)")?.loadConvention, .perHand) }
        XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.assisted-pull-up")?.loadConvention, .assistance)
        XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.plank")?.metric, .duration)
        for slug in ["walking", "running", "cycling"] {
            XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.\(slug)")?.kind, .cardio)
            XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.\(slug)")?.metric, .cardio)
        }
        for slug in ["push-up", "bodyweight-squat"] {
            XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.\(slug)")?.kind, .bodyweight)
            XCTAssertEqual(ExerciseCatalog.exercise(id: "builtin.\(slug)")?.loadConvention, .bodyweight)
        }
        XCTAssertNotNil(ExerciseCatalog.exercise(id: "builtin.lat-pulldown"))
        XCTAssertNotNil(ExerciseCatalog.exercise(id: "builtin.goblet-squat"))
    }

    func testCatalogHasUniqueValidMovementsAndResolvableAlternatives() throws {
        let ids = Set(ExerciseCatalog.exercises.map(\.id))
        XCTAssertEqual(ids.count, ExerciseCatalog.exercises.count)
        XCTAssertGreaterThanOrEqual(ids.count, 50)
        XCTAssertEqual(ids, Set(ExerciseDetails.entries.keys))
        for exercise in ExerciseCatalog.exercises {
            try exercise.validate()
            let detail = try XCTUnwrap(ExerciseDetails.details(for: exercise.id))
            XCTAssertGreaterThanOrEqual(exercise.instructions.count, 3)
            XCTAssertFalse(detail.movementPattern.isEmpty)
            XCTAssertFalse(detail.difficulty.isEmpty)
            XCTAssertFalse(detail.commonMistakes.isEmpty)
            for related in detail.alternativeIDs + detail.progressionIDs {
                XCTAssertTrue(ids.contains(related), "Missing movement \(related)")
                XCTAssertNotEqual(related, exercise.id)
            }
        }
    }

    func testSearchRecognizesAliasesSecondaryMusclesAndMultipleTerms() throws {
        let row = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.dumbbell-row"))
        XCTAssertTrue(ExerciseDetails.matches(row, query: "单臂划船"))
        XCTAssertTrue(ExerciseDetails.matches(row, query: "哑铃 肱二头肌"))
        XCTAssertTrue(ExerciseDetails.matches(row, query: "single-arm dumbbell"))
        XCTAssertFalse(ExerciseDetails.matches(row, query: "哑铃 骑行"))
        XCTAssertTrue(ExerciseDetails.matches(row, query: " \n "))
    }

    func testMediaHasSpecificCreditsAndSafeLocalFilenames() throws {
        var videos = 0
        for detail in ExerciseDetails.entries.values {
            guard let media = detail.media else { continue }
            XCTAssertEqual(URL(string: media.sourceURL)?.host, "wger.de")
            XCTAssertEqual(URL(string: media.sourceURL)?.scheme, "https")
            XCTAssertFalse(media.author.isEmpty)
            XCTAssertFalse(media.changes.isEmpty)
            XCTAssertTrue(media.licenseURL.contains("creativecommons.org"))
            for fileName in [media.fileName, media.posterFileName] {
                XCTAssertFalse(fileName.contains("/"))
                XCTAssertFalse(fileName.contains("\\"))
                XCTAssertFalse(fileName.contains(".."))
            }
            if media.kind == .video {
                videos += 1
                XCTAssertGreaterThan(try XCTUnwrap(media.durationSeconds), 0)
                XCTAssertTrue(media.fileName.hasSuffix(".mp4"))
            }
        }
        XCTAssertGreaterThan(videos, 0)
    }
}
