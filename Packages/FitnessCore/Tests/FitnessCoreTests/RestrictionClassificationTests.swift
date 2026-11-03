import XCTest
import Foundation
@testable import FitnessCore

/// The line this file guards: a *preference* must not require a clinical confirmation, and a
/// *treatment restriction* must never be planned around by guesswork.
final class RestrictionClassificationTests: XCTestCase {

    // MARK: - Preferences: planning may proceed without a review

    func testAStatedPosturePreferenceIsNotAMedicalLimit() {
        XCTAssertFalse(TrainingConstraintReview.readsAsMedicalLimit("不能有跪姿动作"))
        XCTAssertFalse(TrainingConstraintReview.readsAsMedicalLimit("不喜欢地面动作"))
        XCTAssertFalse(TrainingConstraintReview.readsAsMedicalLimit("不想做深蹲"))
    }

    func testPosturePreferenceBecomesAnExclusion() {
        let inferred = TrainingConstraintReview.inferredPreferences("运动的话不能有跪姿动作")
        XCTAssertEqual(inferred.positions, [.kneeling])
        // The catalogue's kneeling movements become excluded without anyone confirming a form.
        XCTAssertTrue(inferred.positions.flatMap(\.exerciseIDs).contains("builtin.knee-push-up"))
    }

    func testFloorPreferenceIsRecognisedSeparately() {
        let inferred = TrainingConstraintReview.inferredPreferences("尽量不要躺地上的动作")
        XCTAssertEqual(inferred.positions, [.floorWork])
    }

    func testUnrecognisedPreferenceIsLeftAlone() {
        XCTAssertTrue(TrainingConstraintReview.inferredPreferences("不想太吵").positions.isEmpty,
                      "猜不出具体约束时不能凭空编一个")
    }

    // MARK: - Medical limits: still gated

    func testTreatmentAndInjuryWordingIsTreatedAsMedical() {
        for text in ["右膝半月板术后", "医生要求避免负重", "腰伤还没好", "做完手术三个月", "怀孕中"] {
            XCTAssertTrue(TrainingConstraintReview.readsAsMedicalLimit(text), text)
        }
    }

    func testPainWordingIsMedicalEvenWhenAlsoAPreference() {
        // "跪姿会疼" is both — the medical reading wins, because it is the safety-relevant one.
        XCTAssertTrue(TrainingConstraintReview.readsAsMedicalLimit("跪姿会疼"))
    }

    // MARK: - End to end through the profile

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func readyProfile(restriction: String) -> StructuredProfile {
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now)
        profile.primaryGoal = .init(value: .fatLoss, provenance: .stated, confirmedAt: now)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now)
        profile.weekdays = .init(value: [1, 2, 4, 5], provenance: .stated, confirmedAt: now)
        profile.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: now)
        // Fat loss wants a light-cardio day, so a walking space is needed for the plan to exist at all.
        profile.equipment = .init(value: [.dumbbells, .kettlebells, .walkingSpace],
                                  provenance: .stated, confirmedAt: now)
        profile.restrictions = .init(value: restriction, provenance: .stated, confirmedAt: now)
        return profile
    }

    func testPreferenceProfileCanProduceAPlanWithoutAnyReview() throws {
        let profile = readyProfile(restriction: "不能有跪姿动作")
        let input = try profile.planningInput(at: now)
        // The preference is honoured as an exclusion, not ignored and not blocking.
        XCTAssertTrue(input.excludedExerciseIDs.contains("builtin.knee-push-up"))
        XCTAssertNil(profile.constraintReview, "不需要经过核对流程")
        XCTAssertNoThrow(try PlannerEngine.options(for: input))
    }

    func testMedicalProfileStillRequiresAReview() {
        let profile = readyProfile(restriction: "右膝半月板术后，医生要求避免深蹲")
        XCTAssertThrowsError(try profile.planningInput(at: now)) { error in
            XCTAssertTrue(error.localizedDescription.contains("核对"), error.localizedDescription)
        }
    }

    func testPlainNoneIsStillFine() {
        XCTAssertNoThrow(try readyProfile(restriction: "无").planningInput(at: now))
    }
}
