import Foundation
import XCTest
@testable import FitnessCore

final class PersonalizedPlanningTests: XCTestCase {
    private func interview() -> InterviewSession {
        let date = Date()
        var session = InterviewSession(createdAt: date)
        session.profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: date)
        session.profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .stated, confirmedAt: date)
        session.profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: date)
        session.profile.weekdays = ProfileField(value: [1, 3, 5], provenance: .stated, confirmedAt: date)
        session.profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: date)
        session.profile.equipment = ProfileField(value: [.bodyweight, .dumbbells, .bench, .walkingSpace], provenance: .stated, confirmedAt: date)
        session.profile.restrictions = ProfileField(value: "无", provenance: .stated, confirmedAt: date)
        return session
    }

    private func reply(_ input: PlanningInput) throws -> PersonalizedPlanReply {
        let pool = try PlannerEngine.candidatePool(input: input)
        return PersonalizedPlanReply(choices: pool.mapValues { $0.last! }, explanation: "协议测试：根据已确认资料选择可用动作", limitations: ["实际重量待本人校准"])
    }

    func testModelChoicesActuallyDetermineMovementsAndCanBeReplayed() throws {
        let session = interview()
        let snapshot = AppSnapshot(interview: session)
        let input = try session.profile.planningInput()
        let selected = try reply(input)
        let draft = try PlanningDraft.makePersonalized(profile: session.profile, reply: selected, snapshot: snapshot,
                                                      providerHost: "fixture.invalid", model: "fixture")
        XCTAssertEqual(draft.personalization?.choices, selected.choices)
        XCTAssertEqual(draft.selection?.explanation, selected.explanation)
        XCTAssertEqual(draft.options, [try PlannerEngine.synthesize(input: draft.input, choices: selected.choices)])
        let locallyDefaulted = try PlannerEngine.synthesize(input: draft.input)
        XCTAssertNotEqual(draft.options[0].days.flatMap(\.items).map(\.exerciseID),
                          locallyDefaulted.days.flatMap(\.items).map(\.exerciseID))
        XCTAssertEqual(draft.decision, .pending)
        XCTAssertNil(draft.appliedProgramID)
        XCTAssertTrue(draft.matches(snapshot: snapshot))
    }

    func testReplyRejectsMissingPatternInsteadOfLocallyPickingDefault() throws {
        let input = try interview().profile.planningInput()
        var selected = try reply(input)
        selected.choices.removeValue(forKey: selected.choices.keys.sorted().first!)
        XCTAssertThrowsError(try selected.validate(input: input))
    }

    func testUnknownMovementOrExtraPrescriptionFieldsAreRejected() throws {
        let input = try interview().profile.planningInput()
        var selected = try reply(input)
        selected.choices["squat"] = "invented.exercise"
        XCTAssertThrowsError(try selected.validate(input: input))
        let data = try JSONSerialization.data(withJSONObject: ["choices": [:], "explanation": "不合法", "limitations": [], "loadKG": 42])
        XCTAssertThrowsError(try PersonalizedPlanReply.decode(data: data, input: input))
    }

    func testConfirmedInterviewChangeInvalidatesUnconfirmedPersonalizedDraft() throws {
        let session = interview()
        let snapshot = AppSnapshot(interview: session)
        let draft = try PlanningDraft.makePersonalized(profile: session.profile, reply: reply(session.profile.planningInput()),
                                                      snapshot: snapshot, providerHost: "fixture.invalid", model: "fixture")
        var changed = snapshot
        changed.interview?.profile.minutesPerSession.value = 45
        XCTAssertFalse(draft.matches(snapshot: changed))
    }

    func testFrozenChoicesCannotBeChangedWithoutChangingValidatedWeek() throws {
        let session = interview()
        var draft = try PlanningDraft.makePersonalized(profile: session.profile, reply: reply(session.profile.planningInput()),
                                                      snapshot: AppSnapshot(interview: session), providerHost: "fixture.invalid", model: "fixture")
        draft.personalization?.choices["squat"] = "builtin.leg-press"
        XCTAssertThrowsError(try draft.validate())
    }

    func testPersonalizedPendingDraftSurvivesBackupRoundTrip() throws {
        let session = interview()
        var snapshot = AppSnapshot(interview: session)
        snapshot.planningDrafts = [try PlanningDraft.makePersonalized(profile: session.profile, reply: reply(session.profile.planningInput()),
                                                                    snapshot: snapshot, providerHost: "fixture.invalid", model: "fixture")]
        let restored = try SnapshotCodec.decode(SnapshotCodec.encode(snapshot))
        XCTAssertEqual(restored.planningDrafts, snapshot.planningDrafts)
    }

    func testOldDraftWithoutPersonalizationFieldStillDecodes() throws {
        let session = interview()
        let old = try PlanningDraft.make(input: session.profile.planningInput(), snapshot: AppSnapshot(interview: session))
        let encoded = try JSONEncoder().encode(old)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "personalization")
        let decoded = try JSONDecoder().decode(PlanningDraft.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.personalization)
        try decoded.validate()
    }

    func testBlankRestrictionCannotStandInForExplicitNoRestrictions() throws {
        var session = interview()
        session.profile.restrictions.value = ""
        XCTAssertThrowsError(try session.profile.planningInput())
    }
}
