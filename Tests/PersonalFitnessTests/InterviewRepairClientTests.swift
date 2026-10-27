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
        bodies.append(request.httpBody ?? Data())
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": replies.removeFirst()], "finish_reason": "stop"]]])
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
