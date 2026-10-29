import Foundation
import XCTest
@testable import FitnessCore

final class DeferredRestScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func chat() throws -> ConstraintChatSession {
        var value = ConstraintChatSession(sourceText: "合成限制：特定时段活动范围尚未明确，避免地面动作")
        try value.appendUser("特定时段先不安排活动", at: now)
        try value.receiveCandidate(.init(avoidedPositions: [.floorWork], excludedWeekdays: [3, 4],
            questions: ["该时段具体活动范围尚未明确"], unresolved: ["该时段强度尚未明确"]), evidenceCount: 1, at: now)
        value.setMode(.affectedDaysRest); value.setPainFree(true, at: now)
        return value
    }
    func testUnknownCannotBeDeferredWithoutExplicitHumanScopeConfirmation() throws {
        XCTAssertThrowsError(try chat().makeReview(at: now))
    }
    func testHumanConfirmationStillRequiresAtLeastOneExcludedPeriod() throws {
        var value = try chat(); value.candidate?.excludedWeekdays = []; value.restScopeConfirmed = true
        XCTAssertThrowsError(try value.makeReview(at: now))
    }
    func testDeferredUnknownsAndOriginalExclusionsRemainInFrozenReview() throws {
        var value = try chat(); value.restScopeConfirmed = true
        let review = try value.makeReview(at: now)
        XCTAssertEqual(review.deferredClinicalQuestions?.count, 2)
        XCTAssertEqual(review.sourceText, value.sourceText)
        XCTAssertEqual(review.avoidedPositions, [.floorWork])
        XCTAssertEqual(review.excludedWeekdays, [3, 4])
        XCTAssertTrue(value.readbackLines.joined().contains("保留待确认"))
        XCTAssertTrue(value.readbackLines.joined().contains("不安排任何正式训练"))
    }
    func testNewAnswerOrNewCandidateRequiresScopeToBeConfirmedAgain() throws {
        var value = try chat(); value.restScopeConfirmed = true
        let candidate = try XCTUnwrap(value.candidate)
        try value.receiveCandidate(candidate, evidenceCount: 1, at: now)
        XCTAssertNil(value.restScopeConfirmed)
        value.restScopeConfirmed = true
        try value.appendUser("另有一项新限制", at: now)
        XCTAssertNil(value.restScopeConfirmed)
        XCTAssertThrowsError(try value.makeReview(at: now))
    }
    func testLegacyRuleOneRemainsLoadableButCannotClaimNewDeferralPolicy() throws {
        let old = TrainingConstraintReview(sourceText: "合成时间偏好", painFreeConfirmed: true,
            allLimitsRepresentedConfirmed: true, confirmedAt: now, rulesVersion: "training-constraints-1")
        XCTAssertNoThrow(try old.validate())
        var value = try chat(); value.restScopeConfirmed = true
        var review = try value.makeReview(at: now); review.rulesVersion = "training-constraints-1"
        XCTAssertThrowsError(try review.validate())
    }
    func testOrdinaryOrProfessionalModeCannotSilentlyUseUnresolvedAnswers() throws {
        var value = try chat(); value.setMode(.practicalOnly); value.restScopeConfirmed = true
        XCTAssertThrowsError(try value.makeReview(at: now))
        value.setMode(.professionalBoundaries); value.restScopeConfirmed = true
        XCTAssertThrowsError(try value.makeReview(at: now))
    }
    func testGeneratedOptionsNeverTrainOnExcludedWeekdaysAndKeepMovementExclusions() throws {
        var value = try chat(); value.restScopeConfirmed = true
        let review = try value.makeReview(at: now)
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: now)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: now)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: now)
        profile.weekdays = .init(value: Array(1...7), provenance: .stated, confirmedAt: now)
        profile.minutesPerSession = .init(value: 35, provenance: .stated, confirmedAt: now)
        profile.equipment = .init(value: [.bodyweight, .walkingSpace, .dumbbells, .bench], provenance: .stated, confirmedAt: now)
        profile.restrictions = .init(value: value.sourceText, provenance: .stated, confirmedAt: now)
        profile.constraintReview = review
        let options = try PlannerEngine.options(for: profile.planningInput(at: now))
        XCTAssertFalse(options.isEmpty)
        for option in options {
            XCTAssertTrue(option.days.filter { [3, 4].contains($0.weekday) }.allSatisfy(\.isRestDay))
            XCTAssertTrue(option.days.flatMap(\.items).allSatisfy { review.allows(exerciseID: $0.exerciseID) })
        }
    }
}
