import XCTest
import FitnessCore
@testable import PersonalFitness

/// The interview wire protocol is untrusted input: these tests pin what the app refuses.
final class InterviewClientTests: XCTestCase {
    private func session() -> InterviewSession {
        InterviewSession(createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testNumberStringsNullFieldsAndJSONStringOptionsAreCanonicalized() throws {
        let text = #"{"questions":[{"topic":"minutes","kind":"number","prompt":"每次多久？","minimum":"15","maximum":"120","unit":"分钟","options":null}],"extractions":null,"note":null}"#
        let turn = try InterviewAPI.decodeTurn(text, session: session(), provider: nil)
        XCTAssertEqual(turn.questions.first?.minimum, 15)
        XCTAssertEqual(turn.questions.first?.maximum, 120)
        XCTAssertEqual(turn.note, "")
        let options = #"{"questions":[{"topic":"primaryGoal","kind":"single_choice","prompt":"目标？","options":"[\"strength\",\"generalFitness\"]"}]}"#
        XCTAssertEqual(try InterviewAPI.decodeTurn(options, session: session(), provider: nil).questions.first?.options, ["strength", "generalFitness"])
    }
    func testDoubleEncodedFencedJSONRemainsDataAndDecodesOnce() throws {
        let object = #"{"questions":[],"note":"可以继续"}"#
        let encoded = String(decoding: try JSONEncoder().encode(object), as: UTF8.self)
        XCTAssertEqual(try InterviewAPI.decodeTurn("```json\n" + encoded + "\n```", session: session(), provider: nil).note, "可以继续")
    }
    func testBooleanRangeAndMaliciousAdditionalFieldsAreRejectedWithPrivateDiagnostic() throws {
        for text in [
            #"{"questions":[{"topic":"minutes","kind":"number","prompt":"私人提示PRIVATE","minimum":true,"maximum":120}]}"#,
            #"{"questions":[],"plan":{"private":"PRIVATE"}}"#
        ] {
            XCTAssertThrowsError(try InterviewAPI.decodeTurn(text, session: session(), provider: nil)) { error in
                guard let issue = error as? InterviewProtocolError else { return XCTFail("Need structured diagnostic") }
                XCTAssertTrue(issue.diagnostic.contains("path="))
                XCTAssertFalse(issue.diagnostic.contains("PRIVATE"))
                XCTAssertFalse(issue.localizedDescription.contains("PRIVATE"))
            }
        }
    }
    func testFullArchivedDialogueAndOwnWordsReachNextInterviewRequest() throws {
        var value = session()
        let date = value.createdAt
        try value.addNarrative("本人想为九月徒步做准备", at: date)
        for index in 0..<5 {
            let question = InterviewQuestion(topic: .capability, kind: .text, prompt: "具体情况？", detailKey: "capability.detail_\(index)")
            try value.appendTurn(.init(questions: [question]), at: date)
            try value.answer([.init(questionID: question.id, text: index == 0 ? "FIRST-DEEP-ANSWER" : "继续补充", answeredAt: date)], at: date)
        }
        value = try value.restartedPreservingProfile(at: date.addingTimeInterval(1))
        let text = try InterviewAPI.requestJSON(session: value, model: "fixture")
        XCTAssertTrue(text.contains("FIRST-DEEP-ANSWER"))
        XCTAssertTrue(text.contains("本人想为九月徒步做准备"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual((object["savedConversation"] as? [Any])?.count, 5)
        let exercise = try XCTUnwrap((object["candidateExercises"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(exercise.keys), Set(["id", "name", "englishName", "equipment", "muscle"]))
    }

    func testValidReplyIsDecodedIntoQuestionsAndExtractions() throws {
        let json = """
        {"questions":[{"topic":"primaryGoal","kind":"singleChoice","prompt":"最主要的目标是什么？",
        "options":["generalFitness","strength"]}],
        "extractions":[{"topic":"minutes","rawValue":"45","rationale":"用户说四十五分钟"}],
        "note":"先了解一下你的目标。"}
        """
        let turn = try InterviewAPI.decodeTurn(json, session: session(),
                                               provider: InterviewProvider(host: "api.example.com",
                                                                           model: "test-model"))
        XCTAssertEqual(turn.questions.count, 1)
        XCTAssertEqual(turn.questions[0].topic, .primaryGoal)
        XCTAssertEqual(turn.questions[0].kind, .singleChoice)
        XCTAssertEqual(turn.extractions.count, 1)
        XCTAssertEqual(turn.extractions[0].topic, .minutes)
        XCTAssertEqual(turn.provider?.model, "test-model")
    }

    func testFencedJSONIsUnwrapped() throws {
        let json = """
        ```json
        {"questions":[],"extractions":[],"note":"好的"}
        ```
        """
        let turn = try InterviewAPI.decodeTurn(json, session: session(), provider: nil)
        XCTAssertTrue(turn.questions.isEmpty)
        XCTAssertEqual(turn.note, "好的")
    }

    func testUnknownTopicIsRefused() {
        let json = """
        {"questions":[{"topic":"bloodType","kind":"text","prompt":"血型？"}],"note":""}
        """
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(json, session: session(), provider: nil))
    }

    func testUnknownQuestionKindIsRefused() {
        let json = """
        {"questions":[{"topic":"primaryGoal","kind":"slider","prompt":"目标？"}],"note":""}
        """
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(json, session: session(), provider: nil))
    }

    func testTooManyQuestionsAreRefused() {
        let questions = (0..<4).map { _ in
            "{\"topic\":\"capability\",\"kind\":\"text\",\"prompt\":\"说明一下\"}"
        }.joined(separator: ",")
        let json = "{\"questions\":[\(questions)],\"note\":\"\"}"
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(json, session: session(), provider: nil))
    }

    func testUnparseableExtractionIsRefused() {
        let json = """
        {"questions":[],"extractions":[{"topic":"minutes","rawValue":"一会儿"}],"note":""}
        """
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(json, session: session(), provider: nil))
    }

    func testExtractionWithInventedExerciseIsRefused() {
        let json = """
        {"questions":[],"extractions":[{"topic":"exclusions","rawValue":"builtin.magic-press"}],"note":""}
        """
        XCTAssertThrowsError(try InterviewAPI.decodeTurn(json, session: session(), provider: nil))
    }

    func testMalformedJSONIsRefused() {
        XCTAssertThrowsError(try InterviewAPI.decodeTurn("这不是 JSON", session: session(), provider: nil))
        XCTAssertThrowsError(try InterviewAPI.decodeTurn("{\"questions\":", session: session(), provider: nil))
    }

    func testRequestJSONCarriesOnlySettledFactsAndOpenTopics() throws {
        var state = session()
        state.profile.primaryGoal = .init(value: .strength, provenance: .stated, confirmedAt: Date())
        state.profile.minutesPerSession = .init(value: 30, provenance: .inferred)
        let json = try InterviewAPI.requestJSON(session: state, model: "test")
        // Parse rather than slice: the payload also carries the whole exercise catalogue, so a text
        // search would match unrelated content.
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let answered = try XCTUnwrap(object["answeredProfile"] as? [String: String])
        let pending = try XCTUnwrap(object["pendingInferences"] as? [String: String])
        let open = try XCTUnwrap(object["openTopics"] as? [String])
        // The settled goal is sent; the unconfirmed inference is not.
        XCTAssertEqual(answered["primaryGoal"], "提高基础力量")
        XCTAssertNil(answered["minutes"])
        // It is reported separately as a pending inference, so the model neither re-asks nor treats
        // it as settled.
        XCTAssertEqual(pending["minutes"], "30 分钟")
        // A pending inference is not treated as an open question either.
        XCTAssertFalse(open.contains("minutes"))
    }
}
