import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

private final class SimpleConstraintChatFixture: @unchecked Sendable {
    struct Reply { let status: Int; let content: String }
    private let lock = NSLock()
    private var replies: [Reply] = []
    private var bodies: [Data] = []
    func reset(_ replies: [Reply]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; bodies = [] }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        bodies.append(try HTTPRequestBodyFixture.read(request))
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        if reply.status != 200 { return (reply.status, Data(reply.content.utf8)) }
        return (200, try JSONSerialization.data(withJSONObject:
            ["choices": [["message": ["content": reply.content], "finish_reason": "stop"]]]))
    }
    func requests() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}

private final class SimpleConstraintChatProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = SimpleConstraintChatFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class SimpleConstraintChatTests: XCTestCase {
    private let valid = #"{"excludedExerciseIDs":["builtin.bird-dog"],"avoidedPositions":["kneeling"],"excludedWeekdays":[5],"restDateKeys":["2028-02-29"],"maxSessionMinutes":25,"allowedExerciseIDs":null,"questions":["这个日期只休息一次吗？"],"unresolved":["还没有说明活动的具体要求"]}"#
    private let service = AIConfiguration(endpoint: "https://fixture.example/chat/completions", model: "fixture")

    private func session() throws -> InterviewSession {
        var value = InterviewSession()
        var chat = ConstraintChatSession(sourceText: "", legacySourceText: "原档案里的安排")
        try chat.appendUser("我不习惯跪姿，周五有固定事务。")
        value.constraintChat = chat
        try value.addNarrative("我不习惯跪姿，周五有固定事务。")
        return value
    }

    private func api() -> SimpleConstraintChatAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimpleConstraintChatProtocol.self]
        return SimpleConstraintChatAPI(client: CoachHTTPClient(session: URLSession(configuration: configuration)))
    }

    func testExactEightFieldsKeepQuestionsAndUnresolvedAsUnanswered() throws {
        let candidate = try SimpleConstraintChatAPI.decode(valid)
        XCTAssertEqual(candidate.excludedWeekdays, [5])
        XCTAssertEqual(candidate.restDateKeys, ["2028-02-29"])
        XCTAssertEqual(candidate.avoidedPositions, [.kneeling])
        XCTAssertEqual(candidate.questions, ["这个日期只休息一次吗？"])
        XCTAssertEqual(candidate.unresolved, ["还没有说明活动的具体要求"])
        XCTAssertNil(candidate.allowedExerciseIDs)
    }

    func testHealthPermissionModeMissingFieldsAndUnknownFieldsAreRejected() {
        for content in [String(valid.dropLast()) + #", "mode":"practicalOnly"}"#,
                        String(valid.dropLast()) + #", "painFree":true}"#,
                        String(valid.dropLast()) + #", "medicalClearance":true}"#,
                        String(valid.dropLast()) + #", "allLimitsRepresentedConfirmed":true}"#,
                        valid.replacingOccurrences(of: #""allowedExerciseIDs":null,"#, with: ""),
                        "PRIVATE-INVALID-CONTENT"] {
            XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(content)) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
                XCTAssertFalse(error.localizedDescription.contains("medicalClearance"))
            }
        }
    }

    func testIllegalIDsDatesAndBooleanMinutesCannotEnterCandidate() {
        for content in [valid.replacingOccurrences(of: "builtin.bird-dog", with: "imaginary-movement"),
                        valid.replacingOccurrences(of: "2028-02-29", with: "2027-02-29"),
                        valid.replacingOccurrences(of: "[5]", with: "[5,5]"),
                        valid.replacingOccurrences(of: #""maxSessionMinutes":25"#, with: #""maxSessionMinutes":true"#),
                        valid.replacingOccurrences(of: #""allowedExerciseIDs":null"#, with: #""allowedExerciseIDs":["imaginary-movement"]"#)] {
            XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(content))
        }
    }

    func testAllowedMovementsNeedTheirSpecificRecordedGuidanceInsteadOfGenericPermission() throws {
        let candidate = ConstraintChatCandidate(allowedExerciseIDs: ["builtin.bird-dog"])
        var chat = ConstraintChatSession(sourceText: "")
        XCTAssertThrowsError(try SimpleConstraintChatAPI.validateEvidence(candidate, chat: chat))
        chat.professionalNote = "已被告知可以轻度活动。"
        XCTAssertThrowsError(try SimpleConstraintChatAPI.validateEvidence(candidate, chat: chat))
        let name = try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.bird-dog")?.name)
        chat.professionalNote = "本人记录：专业人士明确允许\(name)。"
        XCTAssertNoThrow(try SimpleConstraintChatAPI.validateEvidence(candidate, chat: chat))
        // This still does not create medical clearance, a human answer, or a saved review.
        XCTAssertNil(chat.mode); XCTAssertNil(chat.painFree); XCTAssertNil(chat.confirmedAt)
    }

    func testPayloadDisclosesConversationSourcesAndReferenceWithoutRawHealthOrCredentials() throws {
        let value = try session()
        let text = try SimpleConstraintChatAPI.requestJSON(session: value, legacyRestrictions: "原档案里的安排",
            at: Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["legacySourceText"] as? String, "原档案里的安排")
        XCTAssertEqual((object["messages"] as? [[String: Any]])?.count, 1)
        XCTAssertNotNil(object["referenceDate"]); XCTAssertNotNil(object["timeZone"])
        XCTAssertTrue(text.contains("不习惯跪姿"))
        XCTAssertFalse(text.contains("HKQuantity")); XCTAssertFalse(text.contains("fixture-key"))
        let movements = try XCTUnwrap(object["supportedExercises"] as? [[String: String]])
        XCTAssertEqual(Set(movements.compactMap { $0["id"] }), Set(PlannerEngine.supportedMovementIDs))
        XCTAssertFalse(text.contains("painFreeConfirmed"))
    }

    func testPayloadRejectsChangedOriginalOrLegacyBeforeAnyNetworkRequest() throws {
        var value = try session()
        XCTAssertThrowsError(try SimpleConstraintChatAPI.requestJSON(session: value, legacyRestrictions: "更新的原档案"))
        value.constraintChat?.sourceText = "过期的限制"
        XCTAssertThrowsError(try SimpleConstraintChatAPI.requestJSON(session: value, legacyRestrictions: "原档案里的安排"))
    }

    @MainActor
    func testRealHTTPRequestReturnsOnlyCandidateAndDoesNotMutateInterview() async throws {
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 200, content: valid)])
        let original = try session()
        let candidate = try await api().reply(session: original, legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
        XCTAssertEqual(candidate.excludedWeekdays, [5])
        XCTAssertNil(original.constraintChat?.candidate); XCTAssertNil(original.profile.constraintReview)
        let request = try XCTUnwrap(SimpleConstraintChatProtocol.fixture.requests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0]["content"]?.contains("不替本人回答健康问题") ?? false)
        XCTAssertTrue(messages[1]["content"]?.contains("原档案里的安排") ?? false)
    }

    @MainActor
    func testOneCorrectionNeverForwardsRejectedRawResponseAndStopsAfterSecondInvalidReply() async throws {
        let value = try session()
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 200, content: "PRIVATE-FIRST"), .init(status: 200, content: valid)])
        _ = try await api().reply(session: value, legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
        var requests = SimpleConstraintChatProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(String(decoding: try XCTUnwrap(requests.last), as: UTF8.self).contains("PRIVATE-FIRST"))
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 200, content: "PRIVATE-FIRST"), .init(status: 200, content: "PRIVATE-SECOND")])
        do {
            _ = try await api().reply(session: value, legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
            XCTFail("An invalid second response must not be accepted")
        } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        requests = SimpleConstraintChatProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 2)
    }

    @MainActor
    func testUnsupportedJSONModeThenOneCorrectionMakesAtMostThreeRequests() async throws {
        let unsupported = #"{"error":{"param":"response_format","code":"unsupported_parameter","message":"PRIVATE-PROVIDER-DETAIL"}}"#
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 400, content: unsupported),
            .init(status: 200, content: "PRIVATE-BAD-REPLY"), .init(status: 200, content: valid)])
        _ = try await api().reply(session: session(), legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
        let requests = SimpleConstraintChatProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 3)
        let bodies = try requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertNotNil(bodies[0]["response_format"])
        XCTAssertNil(bodies[1]["response_format"]); XCTAssertNil(bodies[2]["response_format"])
        XCTAssertFalse(String(decoding: requests[2], as: UTF8.self).contains("PRIVATE-BAD-REPLY"))
        XCTAssertFalse(String(decoding: requests[2], as: UTF8.self).contains("PRIVATE-PROVIDER-DETAIL"))
    }

    @MainActor
    func testAuthenticationFailureDoesNotRetryOrPretendToHaveAConversation() async throws {
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 401, content: "{}")])
        do {
            _ = try await api().reply(session: session(), legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
            XCTFail("Authentication must fail")
        } catch { XCTAssertEqual(error as? CoachClientError, .authentication) }
        XCTAssertEqual(SimpleConstraintChatProtocol.fixture.requests().count, 1)
    }
    @MainActor
    func testCoachCanReturnTemporaryLowIntensityDateWithoutDemandingMovementList() async throws {
        let response = #"{"excludedExerciseIDs":[],"avoidedPositions":[],"excludedWeekdays":[],"restDateKeys":[],"maxSessionMinutes":null,"allowedExerciseIDs":null,"questions":[],"unresolved":[],"gentleDateKey":"2028-02-29"}"#
        SimpleConstraintChatProtocol.fixture.reset([.init(status: 200, content: response)])
        let original = try session()
        let candidate = try await api().reply(session: original, legacyRestrictions: "原档案里的安排", configuration: service, key: "fixture-key")
        XCTAssertEqual(candidate.gentleDateKey, "2028-02-29")
        XCTAssertNil(candidate.allowedExerciseIDs)
        XCTAssertNil(original.constraintChat?.mode)
        XCTAssertNil(original.constraintChat?.gentleActivityAllowed)
        let request = try XCTUnwrap(SimpleConstraintChatProtocol.fixture.requests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertTrue(messages[0]["content"]?.contains("不得要求用户点名具体动作") ?? false)
    }

}
