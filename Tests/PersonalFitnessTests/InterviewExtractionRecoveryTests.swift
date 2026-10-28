import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

/// Synthetic protocol fixtures, never the user's medical narrative or body measurements.
final class InterviewExtractionRecoveryTests: XCTestCase {
    func testUnitsAndLocalizedEquipmentArrayBecomePendingCandidates() throws {
        let json = #"{"questions":[],"extractions":[{"topic":"height","rawValue":"168 cm"},{"topic":"weight","rawValue":"74.5公斤"},{"topic":"equipment","rawValue":["哑铃","壶铃"]}]}"#
        let turn = try InterviewAPI.decodeTurn(json, session: InterviewSession(), provider: nil)
        XCTAssertNil(turn.extractionIssues)
        var state = InterviewSession()
        for extraction in turn.extractions { try state.applyExtraction(extraction, at: Date()) }
        XCTAssertEqual(state.profile.heightCM.value, 168)
        XCTAssertEqual(state.profile.weightKG.value, 74.5)
        XCTAssertEqual(Set(state.profile.equipment.value ?? []), [.dumbbells, .kettlebells])
        XCTAssertEqual(state.profile.equipment.provenance, .inferred)
        XCTAssertFalse(state.profile.isUsable(.equipment))
        XCTAssertNil(state.profile.adultStatus.value)
    }

    func testBadRawValueIsNotStoredAndValidQuestionAndExtractionSurvive() throws {
        let json = #"{"questions":[{"topic":"capability","kind":"text","prompt":"想先聊哪类活动能力？"}],"extractions":[{"topic":"experience","rawValue":{"PRIVATE_BAD":"not-a-level"}},{"topic":"minutes","rawValue":25}]}"#
        let turn = try InterviewAPI.decodeTurn(json, session: InterviewSession(), provider: nil)
        XCTAssertEqual(turn.questions.count, 1)
        XCTAssertEqual(turn.extractions.map(\.topic), [.minutes])
        XCTAssertEqual(turn.extractionIssues, [.init(topic: .experience, code: .invalidValue)])
        let encoded = String(decoding: try JSONEncoder().encode(turn), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_BAD"))
        XCTAssertEqual(try JSONDecoder().decode(InterviewTurn.self, from: Data(encoded.utf8)), turn)
    }

    func testConflictingDuplicatesAndAdultInferenceAreNotCandidates() throws {
        let json = #"{"questions":[],"extractions":[{"topic":"minutes","rawValue":"20"},{"topic":"minutes","rawValue":"60"},{"topic":"adultStatus","rawValue":true}]}"#
        let turn = try InterviewAPI.decodeTurn(json, session: InterviewSession(), provider: nil)
        XCTAssertTrue(turn.extractions.isEmpty)
        XCTAssertEqual(Set(turn.extractionIssues?.map(\.topic) ?? []), [.minutes, .adultStatus])
    }

    func testUnsafeTopLevelFieldsStillRejectWholeReply() {
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(#"{"questions":[],"plan":{"apply":true}}"#, session: InterviewSession(), provider: nil))
    }
}
