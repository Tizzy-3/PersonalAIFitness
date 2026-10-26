import XCTest
import FitnessCore
@testable import PersonalFitness

/// The interview wire protocol is untrusted input: these tests pin what the app refuses.
final class InterviewClientTests: XCTestCase {
    private func session() -> InterviewSession {
        InterviewSession(createdAt: Date(timeIntervalSince1970: 1_790_000_000))
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
        // The settled goal is sent with its human-readable title.
        XCTAssertTrue(json.contains("提高基础力量"))
        // The unconfirmed inference must not be presented as an answered fact.
        XCTAssertFalse(json.contains("30 分钟"))
        // It is reported as a pending inference so the model neither re-asks nor treats it as settled.
        XCTAssertTrue(json.contains("pendingInferences"))
        XCTAssertTrue(json.contains("30 分钟"))
        XCTAssertFalse(json.contains("\"answeredProfile\" : [\n    \"minutes\""))
    }
}
