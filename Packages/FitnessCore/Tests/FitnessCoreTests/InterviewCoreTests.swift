import Foundation
import XCTest
@testable import FitnessCore

/// Interview, profile provenance and question-protocol tests.
/// Every fixture is synthetic; no real user history or health data is used.
final class InterviewCoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func goalQuestion() -> InterviewQuestion {
        InterviewQuestion(topic: .primaryGoal, kind: .singleChoice, prompt: "你最主要的目标是什么？",
                          options: PlanningGoal.allCases.map(\.rawValue))
    }

    private func minutesQuestion() -> InterviewQuestion {
        InterviewQuestion(topic: .minutes, kind: .number, prompt: "每次能练多久？",
                          unit: "分钟", minimum: 15, maximum: 120)
    }

    // MARK: - Profile provenance

    func testUnknownFieldCarriesNoValueAndIsNotUsable() throws {
        let field = ProfileField<Int>.unknown
        XCTAssertNil(field.value)
        XCTAssertFalse(field.isUsable)
        XCTAssertNil(field.confirmedAt)
        try field.validate(name: "测试")
        // An unknown must not carry content, or it would silently become a fact.
        XCTAssertThrowsError(try ProfileField(value: 3, provenance: .unknown).validate(name: "测试"))
    }

    func testInferenceIsNeverUsableForPlanningUntilConfirmed() throws {
        let inferred = ProfileField(value: 30, provenance: .inferred)
        XCTAssertFalse(inferred.isUsable)
        XCTAssertNil(inferred.confirmedAt)
        try inferred.validate(name: "测试")
        // An inference claiming a confirmation time is a contradiction.
        XCTAssertThrowsError(try ProfileField(value: 30, provenance: .inferred,
                                              confirmedAt: start).validate(name: "测试"))
        let confirmed = inferred.confirmed(at: start)
        XCTAssertTrue(confirmed.isUsable)
        XCTAssertEqual(confirmed.provenance, .confirmed)
        XCTAssertEqual(confirmed.confirmedAt, start)
        // Confirming an empty field must stay unknown rather than invent a value.
        XCTAssertEqual(ProfileField<Int>.unknown.confirmed(at: start).provenance, .unknown)
    }

    func testStatedValueWithoutConfirmationTimeIsRejected() {
        XCTAssertThrowsError(try ProfileField(value: 5, provenance: .stated).validate(name: "测试"))
        XCTAssertNoThrow(try ProfileField(value: 5, provenance: .stated, confirmedAt: start).validate(name: "测试"))
    }

    func testProfilePlanningInputRequiresEveryEssentialTopic() throws {
        var profile = StructuredProfile()
        XCTAssertFalse(profile.isReadyForPlanning)
        XCTAssertThrowsError(try profile.planningInput())
        XCTAssertEqual(Set(profile.missingRequiredTopics), Set(StructuredProfile.requiredTopics))

        profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: start)
        profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .stated, confirmedAt: start)
        profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: start)
        profile.weekdays = ProfileField(value: [1, 3], provenance: .stated, confirmedAt: start)
        profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: start)
        profile.equipment = ProfileField(value: [.bodyweight, .walkingSpace], provenance: .stated, confirmedAt: start)
        profile.restrictions = ProfileField(value: "无", provenance: .stated, confirmedAt: start)
        try profile.validate()
        XCTAssertTrue(profile.isReadyForPlanning)
        let input = try profile.planningInput()
        XCTAssertEqual(input.goal, .generalFitness)
        XCTAssertEqual(input.weekdays, [1, 3])
        XCTAssertEqual(input.minutesPerSession, 30)
    }

    func testInferredEssentialValueDoesNotSatisfyPlanning() {
        var profile = StructuredProfile()
        profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: start)
        profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .inferred)
        profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: start)
        profile.weekdays = ProfileField(value: [1], provenance: .stated, confirmedAt: start)
        profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: start)
        profile.equipment = ProfileField(value: [.bodyweight], provenance: .stated, confirmedAt: start)
        profile.restrictions = ProfileField(value: "无", provenance: .stated, confirmedAt: start)
        XCTAssertTrue(profile.missingRequiredTopics.contains(.primaryGoal))
        XCTAssertFalse(profile.isReadyForPlanning)
        XCTAssertThrowsError(try profile.planningInput())
    }

    func testRecordedRestrictionBlocksAutomaticPlanning() throws {
        var profile = StructuredProfile()
        profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: start)
        profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .stated, confirmedAt: start)
        profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: start)
        profile.weekdays = ProfileField(value: [1], provenance: .stated, confirmedAt: start)
        profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: start)
        profile.equipment = ProfileField(value: [.bodyweight], provenance: .stated, confirmedAt: start)
        profile.restrictions = ProfileField(value: "右膝半月板损伤", provenance: .stated, confirmedAt: start)
        try profile.validate()
        XCTAssertThrowsError(try profile.planningInput())
    }

    // MARK: - Question protocol

    func testChoiceQuestionRequiresOptionsAndRejectsNumberRanges() throws {
        XCTAssertThrowsError(try InterviewQuestion(topic: .primaryGoal, kind: .singleChoice,
                                                   prompt: "目标？").validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .primaryGoal, kind: .singleChoice,
                                                   prompt: "目标？", options: ["A", "A"]).validate())
        XCTAssertNoThrow(try goalQuestion().validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .primaryGoal, kind: .singleChoice,
                                                   prompt: "目标？", options: ["A"], unit: "分钟").validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .primaryGoal, kind: .singleChoice,
                                                   prompt: "目标？", options: ["A"], minimum: 1,
                                                   maximum: 10).validate())
    }

    func testNumberQuestionRejectsHalfRangeAndOptions() throws {
        XCTAssertNoThrow(try minutesQuestion().validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .minutes, kind: .number, prompt: "多久？",
                                                   options: ["30"]).validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .minutes, kind: .number, prompt: "多久？",
                                                   minimum: 15).validate())
        XCTAssertThrowsError(try InterviewQuestion(topic: .minutes, kind: .number, prompt: "多久？",
                                                   minimum: 120, maximum: 15).validate())
    }

    func testAnswerMustMatchItsQuestionKind() throws {
        let choice = goalQuestion()
        XCTAssertThrowsError(try InterviewAnswer(questionID: choice.id,
                                                 choice: "not-a-goal").validate(question: choice))
        XCTAssertThrowsError(try InterviewAnswer(questionID: choice.id, text: "增肌").validate(question: choice))
        XCTAssertNoThrow(try InterviewAnswer(questionID: choice.id, choice: "strength").validate(question: choice))

        let number = minutesQuestion()
        XCTAssertThrowsError(try InterviewAnswer(questionID: number.id, number: 10).validate(question: number))
        XCTAssertThrowsError(try InterviewAnswer(questionID: number.id, number: 200).validate(question: number))
        XCTAssertThrowsError(try InterviewAnswer(questionID: number.id, number: .nan).validate(question: number))
        XCTAssertNoThrow(try InterviewAnswer(questionID: number.id, number: 30).validate(question: number))
    }

    func testUnknownAndSkippedCannotCarryContent() throws {
        let question = goalQuestion()
        XCTAssertNoThrow(try InterviewAnswer(questionID: question.id, outcome: .unknown).validate(question: question))
        XCTAssertThrowsError(try InterviewAnswer(questionID: question.id, outcome: .unknown,
                                                 choice: "strength").validate(question: question))
        let strict = InterviewQuestion(topic: .primaryGoal, kind: .singleChoice, prompt: "目标？",
                                       options: ["strength"], allowUnknown: false)
        XCTAssertThrowsError(try InterviewAnswer(questionID: strict.id, outcome: .unknown).validate(question: strict))
    }

    // MARK: - Session

    private func makeSession() -> InterviewSession {
        InterviewSession(createdAt: start)
    }

    private func turn(questions: [InterviewQuestion],
                      extractions: [InterviewExtraction] = []) -> InterviewTurn {
        InterviewTurn(questions: questions, extractions: extractions, note: "继续了解你的情况。")
    }

    func testAnswerIsAppliedAndDuplicateAnswersRejected() throws {
        var session = makeSession()
        let question = goalQuestion()
        try session.appendTurn(turn(questions: [question]), at: start)
        XCTAssertEqual(session.unansweredQuestions.count, 1)
        try session.answer([InterviewAnswer(questionID: question.id, choice: "strength")],
                           at: start.addingTimeInterval(60))
        XCTAssertEqual(session.profile.primaryGoal.value, .strength)
        XCTAssertEqual(session.profile.provenance(of: .primaryGoal), .stated)
        XCTAssertTrue(session.unansweredQuestions.isEmpty)
        XCTAssertThrowsError(try session.answer([InterviewAnswer(questionID: question.id, choice: "strength")],
                                                at: start.addingTimeInterval(120)))
        // A rejected answer must not leave a partial change behind.
        XCTAssertEqual(session.profile.primaryGoal.value, .strength)
    }

    func testUnansweredQuestionIsNotSilentlyTreatedAsNegative() throws {
        var session = makeSession()
        let question = InterviewQuestion(topic: .restrictions, kind: .boolean,
                                         prompt: "有没有运动限制？")
        try session.appendTurn(turn(questions: [question]), at: start)
        XCTAssertEqual(session.unansweredQuestions.count, 1)
        XCTAssertEqual(session.profile.provenance(of: .restrictions), .unknown)
        XCTAssertFalse(session.profile.restrictions.isUsable)
    }

    func testUnknownAnswerStaysUnknownAndIsNotUsable() throws {
        var session = makeSession()
        let question = minutesQuestion()
        try session.appendTurn(turn(questions: [question]), at: start)
        try session.answer([InterviewAnswer(questionID: question.id, outcome: .unknown)],
                           at: start.addingTimeInterval(30))
        XCTAssertEqual(session.profile.provenance(of: .minutes), .unknown)
        XCTAssertNil(session.profile.minutesPerSession.value)
    }

    func testExtractionIsProvisionalUntilConfirmed() throws {
        var session = makeSession()
        let extraction = InterviewExtraction(topic: .minutes, rawValue: "45", rationale: "用户提到每次四十五分钟")
        try session.applyExtraction(extraction, at: start)
        XCTAssertEqual(session.profile.provenance(of: .minutes), .inferred)
        XCTAssertEqual(session.profile.minutesPerSession.value, 45)
        XCTAssertTrue(session.pendingInferences.contains(.minutes))
        XCTAssertFalse(session.profile.minutesPerSession.isUsable)
        XCTAssertEqual(session.phase, .awaitingReview)

        try session.confirmInference(.minutes, accept: true, at: start.addingTimeInterval(60))
        XCTAssertEqual(session.profile.provenance(of: .minutes), .confirmed)
        XCTAssertTrue(session.profile.minutesPerSession.isUsable)
        XCTAssertTrue(session.pendingInferences.isEmpty)
    }

    func testRejectingInferenceClearsIt() throws {
        var session = makeSession()
        try session.applyExtraction(InterviewExtraction(topic: .minutes, rawValue: "45"), at: start)
        try session.confirmInference(.minutes, accept: false, at: start.addingTimeInterval(60))
        XCTAssertEqual(session.profile.provenance(of: .minutes), .unknown)
        XCTAssertNil(session.profile.minutesPerSession.value)
    }

    func testUnparseableExtractionIsRejectedOutright() {
        let bad = InterviewExtraction(topic: .schedule, rawValue: "周一到周五")
        XCTAssertThrowsError(try bad.validate())
        let unknownEquipment = InterviewExtraction(topic: .equipment, rawValue: "powerRack")
        XCTAssertThrowsError(try unknownEquipment.validate())
        XCTAssertNoThrow(try InterviewExtraction(topic: .schedule, rawValue: "1,3,5").validate())
        XCTAssertNoThrow(try InterviewExtraction(topic: .equipment, rawValue: "bodyweight,dumbbells").validate())
    }

    func testTurnRejectsTooManyQuestionsAndOrphanAnswers() throws {
        let questions = (0..<4).map { index in
            InterviewQuestion(topic: .primaryGoal, kind: .text, prompt: "问题\(index)")
        }
        XCTAssertThrowsError(try InterviewTurn(questions: questions).validate())
        let question = goalQuestion()
        let orphan = InterviewAnswer(questionID: UUID(), choice: "strength")
        XCTAssertThrowsError(try InterviewTurn(questions: [question], answers: [orphan]).validate())
    }

    func testAnsweredTopicIsNotAskedAgain() throws {
        var session = makeSession()
        let question = goalQuestion()
        try session.appendTurn(turn(questions: [question]), at: start)
        try session.answer([InterviewAnswer(questionID: question.id, choice: "strength")],
                           at: start.addingTimeInterval(60))
        let repeatTurn = try session.appendTurn(turn(questions: [goalQuestion()]),
                                                at: start.addingTimeInterval(120))
        XCTAssertTrue(repeatTurn.questions.isEmpty)
        XCTAssertTrue(session.openTopics.contains(where: { $0 == .primaryGoal }) == false)
    }

    func testDeclinedTopicIsNeverAskedAgain() throws {
        var session = makeSession()
        let question = InterviewQuestion(topic: .sleep, kind: .text, prompt: "睡眠怎么样？")
        try session.appendTurn(turn(questions: [question]), at: start)
        try session.answer([InterviewAnswer(questionID: question.id, outcome: .skipped)],
                           at: start.addingTimeInterval(30))
        XCTAssertTrue(session.declinedTopics.contains(.sleep))
        XCTAssertFalse(session.openTopics.contains(.sleep))
        let repeatTurn = try session.appendTurn(turn(questions: [
            InterviewQuestion(topic: .sleep, kind: .text, prompt: "那睡眠呢？")
        ]), at: start.addingTimeInterval(60))
        XCTAssertTrue(repeatTurn.questions.isEmpty)
    }

    func testSessionPhaseFollowsProfileState() throws {
        var session = makeSession()
        XCTAssertEqual(session.phase, .inProgress)
        try session.applyExtraction(InterviewExtraction(topic: .minutes, rawValue: "30"), at: start)
        XCTAssertEqual(session.derivedPhase, .awaitingReview)
        try session.confirmInference(.minutes, accept: true, at: start.addingTimeInterval(10))
        session.adultStatus = .init(value: true, provenance: .stated, confirmedAt: start)
        session.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: start)
        session.experience = .init(value: .beginner, provenance: .stated, confirmedAt: start)
        session.weekdays = .init(value: [1, 3], provenance: .stated, confirmedAt: start)
        session.equipment = .init(value: [.bodyweight], provenance: .stated, confirmedAt: start)
        session.restrictions = .init(value: "无", provenance: .stated, confirmedAt: start)
        XCTAssertEqual(session.derivedPhase, .ready)
    }

    func testDuplicateQuestionIdentifiersAcrossTurnsAreRejected() throws {
        let question = goalQuestion()
        var session = makeSession()
        try session.appendTurn(InterviewTurn(questions: [question]), at: start)
        session.turns.append(InterviewTurn(questions: [question], createdAt: start.addingTimeInterval(60)))
        XCTAssertThrowsError(try session.validate())
    }
}
