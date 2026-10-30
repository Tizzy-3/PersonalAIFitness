import Foundation
import XCTest
@testable import FitnessCore

final class GentleDayPlannerTests: XCTestCase {
    private let walking: Set<PlanningEquipment> = [.walkingSpace]

    func testConfirmedLightActivityProducesConcreteFiveMinuteWalking() throws {
        let condition = TemporaryActivityConstraint(dateKey: "2026-11-05", lightActivityAllowed: true,
                                                    hasConcerningSymptoms: false)
        let item = try GentleDayPlanner.suggestedWalking(for: condition, equipment: walking)
        XCTAssertEqual(item.exerciseID, "builtin.walking")
        XCTAssertEqual(item.targetSeconds, 300)
        XCTAssertEqual(condition.dateKey, "2026-11-05")
    }

    func testUnknownPermissionOrSymptomsCannotBecomeAnExercisePrescription() {
        for (permission, symptoms) in [(nil, false), (true, nil), (false, false), (true, true)] as [(Bool?, Bool?)] {
            let condition = TemporaryActivityConstraint(dateKey: "2026-11-05", lightActivityAllowed: permission,
                                                        hasConcerningSymptoms: symptoms)
            XCTAssertThrowsError(try GentleDayPlanner.suggestedWalking(for: condition, equipment: walking))
        }
    }

    func testUnavailableOrExplicitlyExcludedMovementIsNeverSuggested() {
        let condition = TemporaryActivityConstraint(dateKey: "2026-11-05", lightActivityAllowed: true,
                                                    hasConcerningSymptoms: false,
                                                    excludedExerciseIDs: ["builtin.walking"])
        XCTAssertThrowsError(try GentleDayPlanner.suggestedWalking(for: condition, equipment: walking))
        let noExclusions = TemporaryActivityConstraint(dateKey: "2026-11-05", lightActivityAllowed: true,
                                                       hasConcerningSymptoms: false)
        XCTAssertThrowsError(try GentleDayPlanner.suggestedWalking(for: noExclusions, equipment: [.bodyweight]))
    }

    func testTemporaryRestrictionOnlyMatchesItsSpecificCivilDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let thursday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        let nextWeek = try XCTUnwrap(calendar.date(byAdding: .day, value: 7, to: thursday))
        let condition = TemporaryActivityConstraint(dateKey: "2026-11-05", lightActivityAllowed: true,
                                                    hasConcerningSymptoms: false)
        XCTAssertTrue(condition.applies(on: thursday, calendar: calendar))
        XCTAssertFalse(condition.applies(on: nextWeek, calendar: calendar))
    }

    func testInvalidDateIsRejected() {
        let condition = TemporaryActivityConstraint(dateKey: "2026-02-30", lightActivityAllowed: true,
                                                    hasConcerningSymptoms: false)
        XCTAssertThrowsError(try GentleDayPlanner.suggestedWalking(for: condition, equipment: walking))
    }
    func testReviewRequiresPersonToConfirmLightActivityAndPreservesOriginalText() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var chat = ConstraintChatSession(sourceText: "合成事例：某日不能剧烈活动")
        try chat.appendUser("只需要轻一点", at: now)
        try chat.receiveCandidate(.init(gentleDateKey: "2026-11-05"), evidenceCount: 1, at: now)
        chat.setMode(.gentleActivity)
        chat.setPainFree(true, at: now)
        XCTAssertThrowsError(try chat.makeReview(at: now))
        chat.gentleActivityAllowed = true
        let review = try chat.makeReview(at: now)
        XCTAssertEqual(review.sourceText, chat.sourceText)
        XCTAssertEqual(review.temporaryActivity?.dateKey, "2026-11-05")
        XCTAssertTrue(chat.readbackLines.joined().contains("2026-11-05"))
        let encoded = try JSONEncoder().encode(review)
        XCTAssertEqual(try JSONDecoder().decode(TrainingConstraintReview.self, from: encoded), review)
        try chat.appendUser("另有新的情况", at: now)
        XCTAssertNil(chat.gentleActivityAllowed)
        XCTAssertThrowsError(try chat.makeReview(at: now))
    }

}
