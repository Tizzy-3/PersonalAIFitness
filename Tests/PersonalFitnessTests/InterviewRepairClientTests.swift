import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

private final class InterviewRepairFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []
    private var bodies: [Data] = []
    func reset(_ replies: [String]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; bodies = [] }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        bodies.append(try HTTPRequestBodyFixture.read(request))
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        let reason = reply == "FIXTURE_TRUNCATED" ? "length" : "stop"
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": reply], "finish_reason": reason]]])
    }
    func requests() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}
private final class InterviewRepairProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = InterviewRepairFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
final class InterviewRepairClientTests: XCTestCase {
    private func api() -> InterviewAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterviewRepairProtocol.self]
        return InterviewAPI(client: CoachHTTPClient(session: URLSession(configuration: configuration)))
    }
    @MainActor
    func testAIAsksARealFirstQuestionWithoutAnyUserIntroduction() async throws {
        InterviewRepairProtocol.fixture.reset([#"{"questions":[{"topic":"capability","kind":"text","prompt":"你现在能连续步行多久？"},{"topic":"minutes","kind":"number","prompt":"你每次方便练多久？","unit":"分钟"}],"extractions":[],"note":"我先来问，你只需回答。"}"#])
        let session = InterviewSession()
        let turn = try await api().nextTurn(session: session, configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-token")
        XCTAssertEqual(turn.questions.map(\.topic), [.minutes])
        XCTAssertTrue((session.narratives ?? []).isEmpty)
        XCTAssertEqual(InterviewRepairProtocol.fixture.requests().count, 1)
    }
    @MainActor
    func testAIReceivesExistingFactsAndProactivelyDeepensWithoutNewNarrative() async throws {
        InterviewRepairProtocol.fixture.reset([#"{"questions":[{"topic":"capability","kind":"text","prompt":"你刚才说能走20分钟，最后几分钟感觉怎样？","detailKey":"capability.walking_effort"}],"extractions":[],"note":"我继续问一个具体细节。"}"#])
        var session = InterviewSession()
        let first = InterviewQuestion(topic: .capability, kind: .text, prompt: "能连续步行多久？")
        try session.appendTurn(.init(questions: [first]))
        try session.answer([.init(questionID: first.id, text: "SYNTHETIC-WALK-20-MINUTES", answeredAt: Date())])
        let turn = try await api().nextTurn(session: session, configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-token", scope: .details)
        XCTAssertEqual(turn.questions.first?.detailKey, "capability.walking_effort")
        let body = try XCTUnwrap(InterviewRepairProtocol.fixture.requests().first)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("SYNTHETIC-WALK-20-MINUTES"))
        XCTAssertTrue((session.narratives ?? []).isEmpty)
        XCTAssertEqual(InterviewRepairProtocol.fixture.requests().count, 1)
    }

    @MainActor
    func testTruncatedQuestionGetsOneShortRetryWithSameInterviewContext() async throws {
        InterviewRepairProtocol.fixture.reset(["FIXTURE_TRUNCATED", #"{"questions":[{"topic":"minutes","kind":"number","prompt":"每次能练多久？","unit":"分钟"}],"extractions":[],"note":""}"#])
        let turn = try await api().nextTurn(session: InterviewSession(),
            configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-token")
        XCTAssertEqual(turn.questions.map(\.topic), [.minutes])
        let requests = InterviewRepairProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 2)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests.last)) as? [String: Any])
        let messages = try XCTUnwrap(payload["messages"] as? [[String: String]])
        XCTAssertTrue(messages.last?["content"]?.contains("最多一个最重要的问题") == true)
        XCTAssertNil(payload["response_format"])
    }
    @MainActor
    func testMalformedReplyGetsOneCorrectionWithoutForwardingPrivateRawReply() async throws {
        InterviewRepairProtocol.fixture.reset(["PRIVATE_BAD_REPLY", #"{"questions":[],"note":"继续了解"}"#])
        let turn = try await api().nextTurn(session: InterviewSession(), configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-token")
        XCTAssertEqual(turn.formatRepairUsed, true)
        let requests = InterviewRepairProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 2)
        let second = try XCTUnwrap(requests.last)
        XCTAssertFalse(String(decoding: second, as: UTF8.self).contains("PRIVATE_BAD_REPLY"))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual((payload["messages"] as? [Any])?.count, 3)
    }
    @MainActor
    func testFailedCorrectionStopsAndExposesOnlySafeDiagnosticMetadata() async throws {
        InterviewRepairProtocol.fixture.reset(["PRIVATE_FIRST", "PRIVATE_SECOND"])
        do {
            _ = try await api().nextTurn(session: InterviewSession(), configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-token")
            XCTFail("Invalid JSON must not be accepted")
        } catch let error as InterviewProtocolError {
            XCTAssertEqual(error.finishReason, "stop")
            XCTAssertTrue(error.diagnostic.contains("path="))
            XCTAssertFalse(error.diagnostic.contains("PRIVATE"))
        }
        XCTAssertEqual(InterviewRepairProtocol.fixture.requests().count, 2)
    }
}
