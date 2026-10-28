import XCTest
import Foundation
import AVFoundation
import FitnessCore
@testable import PersonalFitness

final class ExerciseMediaTests: XCTestCase {
    @MainActor
    func testCatalogMediaExactlyMatchesReviewedActiveManifestAndNeverUsesDisabledSources() throws {
        let url = try XCTUnwrap(ExerciseMediaAsset.url(for: "media-manifest.json"))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let activeIDs = try Set(entries.filter { $0["disabledReason"] == nil }.map { try XCTUnwrap($0["exerciseID"] as? String) })
        let actualIDs = Set(ExerciseCatalog.exercises.filter { ExerciseDetails.details(for: $0.id)?.media != nil }.map(\.id))
        XCTAssertEqual(actualIDs, activeIDs, "Unused or unreviewed media must not silently enter the catalogue")
        XCTAssertGreaterThanOrEqual(entries.filter { $0["type"] as? String == "video" }.count, 40)
        for entry in entries where entry["disabledReason"] == nil {
            let id = try XCTUnwrap(entry["exerciseID"] as? String)
            let media = try XCTUnwrap(ExerciseDetails.details(for: id)?.media)
            XCTAssertEqual(media.fileName, entry["fileName"] as? String, id)
            XCTAssertEqual(media.posterFileName, entry["posterFileName"] as? String, id)
            XCTAssertEqual(media.sourceURL, entry["sourceURL"] as? String, id)
            XCTAssertEqual(media.author, entry["author"] as? String, id)
            XCTAssertEqual(media.licenseURL, entry["licenseURL"] as? String, id)
            if media.kind == .video {
                XCTAssertEqual(media.previewGIFFileName, entry["previewGIFFileName"] as? String, id)
            }
        }
        for entry in entries where entry["disabledReason"] != nil {
            let id = try XCTUnwrap(entry["exerciseID"] as? String)
            XCTAssertNil(ExerciseDetails.details(for: id)?.media, "A mismatched movement image must remain unavailable: \(id)")
        }
    }

    @MainActor
    func testBundledLicensedMediaAndPostersResolve() throws {
        for exercise in ExerciseCatalog.exercises {
            guard let media = ExerciseDetails.details(for: exercise.id)?.media else { continue }
            let url = try XCTUnwrap(ExerciseMediaAsset.url(for: media.fileName), exercise.id)
            let size = try XCTUnwrap((try url.resourceValues(forKeys: [.fileSizeKey])).fileSize)
            XCTAssertGreaterThan(size, 0)
            XCTAssertNotNil(ExerciseMediaAsset.poster(for: exercise.id), "Poster unavailable: \(exercise.id)")
            if let gif = media.previewGIFFileName {
                let animation = try XCTUnwrap(ExerciseAnimatedThumbnail.decode(gif), "GIF unavailable: \(exercise.id)")
                XCTAssertGreaterThan(animation.images?.count ?? 0, 1)
                XCTAssertLessThanOrEqual(animation.images?.count ?? 0, 80)
                XCTAssertGreaterThan(animation.duration, 0)
                XCTAssertLessThanOrEqual(animation.duration, 6.2)
            }
        }
        XCTAssertNil(ExerciseMediaAsset.url(for: "../outside.mp4"))
        XCTAssertNil(ExerciseMediaAsset.url(for: "dir\\outside.mp4"))
    }

    @MainActor
    func testBundledDemonstrationClipsHavePlayableVideoTracks() async throws {
        for detail in ExerciseDetails.entries.values {
            guard let media = detail.media, media.kind == .video else { continue }
            let asset = AVURLAsset(url: try XCTUnwrap(ExerciseMediaAsset.url(for: media.fileName)))
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertFalse(tracks.isEmpty)
            let duration = try await asset.load(.duration)
            XCTAssertTrue(duration.seconds.isFinite)
            XCTAssertGreaterThan(duration.seconds, 0)
            let playable = try await asset.load(.isPlayable)
            XCTAssertTrue(playable)
        }
    }
}
