import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

private struct CoachHTTPStub: Sendable {
    let status: Int
    let contentType: String
    let data: Data
    var headers: [String: String] = [:]
}

private final class CoachProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> CoachHTTPStub)?

    func set(_ handler: @escaping @Sendable (URLRequest) throws -> CoachHTTPStub) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler
    }

    func respond(to request: URLRequest) throws -> CoachHTTPStub {
        lock.lock(); let current = handler; lock.unlock()
        guard let current else { throw URLError(.resourceUnavailable) }
        return try current(request)
    }
}

private final class CoachStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = CoachProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let stub = try Self.state.respond(to: request)
            var headers = stub.headers
            headers["Content-Type"] = stub.contentType
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class CoachClientTests: XCTestCase {
    private let configuration = AIConfiguration(endpoint: "https://model.example.invalid/v1/chat/completions", model: "fixture-model")

    @MainActor
    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> CoachHTTPStub) -> CoachHTTPClient {
        CoachStubURLProtocol.state.set(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoachStubURLProtocol.self]
        return CoachHTTPClient(session: URLSession(configuration: configuration))
    }

    @MainActor
    func testConfigurationRejectsPlainHTTPAndCredentialOrQueryURLs() {
        for address in ["http://example.invalid/v1/chat/completions",
                        "https://name:password@example.invalid/v1/chat/completions",
                        "https://example.invalid/v1/chat/completions?key=x",
                        "https://example.invalid/v1/chat/completions#fragment",
                        "https://example.invalid/v1/responses",
                        "https://example.invalid/v1"] {
            XCTAssertThrowsError(try AIConfiguration(endpoint: address, model: "model").validatedURL())
        }
    }

    @MainActor
    func testKeysArePartitionedByNormalizedHostAndPort() throws {
        let same = AIConfiguration(endpoint: "https://MODEL.example.invalid:443/other/chat/completions", model: "another")
        let otherHost = AIConfiguration(endpoint: "https://other.example.invalid/v1/chat/completions", model: "fixture-model")
        let otherPort = AIConfiguration(endpoint: "https://model.example.invalid:8443/v1/chat/completions", model: "fixture-model")
        XCTAssertEqual(try configuration.credentialAccount, try same.credentialAccount)
        XCTAssertNotEqual(try configuration.credentialAccount, try otherHost.credentialAccount)
        XCTAssertNotEqual(try configuration.credentialAccount, try otherPort.credentialAccount)
    }

    @MainActor
    func testConfigPersistenceExcludesAPIKeyAndRejectsUnknownFormat() throws {
        let suite = "CoachClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try AIConfigurationStorage.save(configuration, defaults: defaults)
        XCTAssertEqual(try AIConfigurationStorage.load(defaults: defaults), configuration)
        let encoded = try JSONSerialization.jsonObject(with: defaults.data(forKey: "personal-fitness.ai-configuration.v1")!) as! [String: String]
        XCTAssertEqual(Set(encoded.keys), Set(["endpoint", "model"]))
        defaults.set(Data("invalid".utf8), forKey: "personal-fitness.ai-configuration.v1")
        XCTAssertThrowsError(try AIConfigurationStorage.load(defaults: defaults))
    }

    @MainActor
    func testValidChatCompletionHasBearerHeaderAndTextResponse() async throws {
        let client = client { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return CoachHTTPStub(status: 200, contentType: "application/json", data: Data(#"{"choices":[{"message":{"content":"fixture answer"},"finish_reason":"stop"}]}"#.utf8))
        }
        let answer = try await client.complete(configuration: configuration, key: "fixture-token", messages: [CoachMessage(role: "user", content: "fixture question")])
        XCTAssertEqual(answer, "fixture answer")
    }

    @MainActor
    func testUnauthorizedBodyIsNotShownAsError() async {
        let client = client { _ in CoachHTTPStub(status: 401, contentType: "application/json", data: Data("fixture-secret-echo".utf8)) }
        do { _ = try await client.complete(configuration: configuration, key: "fixture-token", messages: []); XCTFail("Expected 401") }
        catch { XCTAssertEqual(error as? CoachClientError, .authentication); XCTAssertFalse(error.localizedDescription.contains("fixture-secret-echo")) }
    }

    @MainActor
    func testRateLimitIsReportedWithoutAutomaticRetry() async {
        let client = client { _ in CoachHTTPStub(status: 429, contentType: "application/json", data: Data()) }
        do { _ = try await client.complete(configuration: configuration, key: "fixture-token", messages: []); XCTFail("Expected 429") }
        catch { XCTAssertEqual(error as? CoachClientError, .rateLimited) }
    }

    @MainActor
    func testHTMLResponseIsRejected() async {
        let client = client { _ in CoachHTTPStub(status: 200, contentType: "text/html", data: Data("<html>proxy login</html>".utf8)) }
        do { _ = try await client.complete(configuration: configuration, key: "fixture-token", messages: []); XCTFail("Expected unsupported response") }
        catch { XCTAssertEqual(error as? CoachClientError, .invalidResponse) }
    }

    @MainActor
    func testRedirectStatusIsNotTreatedAsAnAnswer() async {
        let client = client { _ in CoachHTTPStub(status: 302, contentType: "text/html", data: Data(), headers: ["Location": "https://other.example.invalid/v1/chat/completions"]) }
        do { _ = try await client.complete(configuration: configuration, key: "fixture-token", messages: []); XCTFail("Expected blocked redirect") }
        catch { XCTAssertEqual(error as? CoachClientError, .redirectBlocked) }
    }

    @MainActor
    func testResponseByteBoundAppliesWithoutContentLength() async {
        let client = client { _ in CoachHTTPStub(status: 200, contentType: "application/json", data: Data(repeating: 65, count: CoachHTTPClient.maximumResponseBytes + 1)) }
        do { _ = try await client.complete(configuration: configuration, key: "fixture-token", messages: []); XCTFail("Expected size limit") }
        catch { XCTAssertEqual(error as? CoachClientError, .responseTooLarge) }
    }

    @MainActor
    func testCancelledRequestDoesNotStartNetworkOrBecomeAnAnswer() async {
        let client = client { _ in
            XCTFail("A pre-cancelled request must not be sent")
            throw URLError(.cancelled)
        }
        let configuration = configuration
        let task = Task { try await client.complete(configuration: configuration, key: "fixture-token", messages: []) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation should remain distinct from a service error") }
    }

    @MainActor
    func testEmptyRefusedAndTruncatedResponsesFailClosed() {
        XCTAssertThrowsError(try CoachHTTPClient.decodeEnvelope(Data(#"{"choices":[{"message":{"content":""},"finish_reason":"stop"}]}"#.utf8)))
        XCTAssertThrowsError(try CoachHTTPClient.decodeEnvelope(Data(#"{"choices":[{"message":{"content":null,"refusal":"No"},"finish_reason":"stop"}]}"#.utf8)))
        XCTAssertThrowsError(try CoachHTTPClient.decodeEnvelope(Data(#"{"choices":[{"message":{"content":"partial"},"finish_reason":"length"}]}"#.utf8)))
    }

    @MainActor
    func testConsentJSONIsTheSameStructuredInputUsedByTheRequest() throws {
        let context = try CoachContext.make(snapshot: AppSnapshot())
        let json = try CoachAPI.requestJSON(question: "fixture question", context: context)
        let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual(payload["question"] as? String, "fixture question")
        XCTAssertEqual(payload["allowedEvidenceIDs"] as? [String], context.evidenceIDs)
        XCTAssertNotNil(payload["context"])
        XCTAssertFalse(json.contains("Authorization"))
        XCTAssertFalse(json.contains("fixture-token"))
    }

    @MainActor
    func testOnlyWholeJSONFenceIsRemoved() {
        XCTAssertEqual(CoachAPI.unfencedJSON("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(CoachAPI.unfencedJSON("```JSON\r\n{\"a\":1}\r\n```"), "{\"a\":1}")
        XCTAssertEqual(CoachAPI.unfencedJSON("text {\"a\":1}"), "text {\"a\":1}")
    }

    @MainActor
    func testStructuredProtocolReplyRequiresSeparateExplicitPlanConfirmation() async throws {
        let store = try TrainingStore(inMemory: true)
        let original = try store.confirmPlan(name: "协议夹具计划", items: [PlannedExercise(exercise: ExerciseCatalog.exercises[0])])
        let context = try CoachContext.make(snapshot: store.snapshot()).withMovementKnowledge(for: "解释计划")
        let replyObject: [String: Any] = [
            "answer": "这是协议测试回答，不是真实模型结果", "evidence": ["plan"], "limitations": ["夹具不代表模型效果"],
            "proposal": ["reason": "测试减量确认", "targetPlanVersionID": original.id.uuidString,
                         "items": [["exerciseID": original.items[0].exercise.id, "setCount": 2,
                                    "targetReps": 10, "targetSeconds": NSNull(), "restSeconds": 90]]]
        ]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: replyObject), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        let fixtureClient = client { _ in CoachHTTPStub(status: 200, contentType: "application/json", data: envelope) }
        let reply = try await CoachAPI(client: fixtureClient).reply(question: "测试减量流程", context: context,
                                                                  configuration: configuration, key: "fixture-token")
        let turn = CoachTurn(question: "测试减量流程", context: context, reply: reply)
        try store.saveCoachTurn(turn)
        XCTAssertEqual(store.currentPlan, original)
        XCTAssertEqual(store.planVersions.count, 1)
        let applied = try XCTUnwrap(store.decideCoachTurn(id: turn.id, accept: true))
        XCTAssertEqual(applied.items[0].setCount, 2)
        XCTAssertEqual(applied.parentVersionID, original.id)
        XCTAssertThrowsError(try store.decideCoachTurn(id: turn.id, accept: true))
        XCTAssertEqual(store.planVersions.count, 2)
    }
}
