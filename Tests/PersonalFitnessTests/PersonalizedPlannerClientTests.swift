import XCTest
import FitnessCore
@testable import PersonalFitness

private final class CompositionFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> Data)?
    func set(_ value: @escaping @Sendable (URLRequest) throws -> Data) { lock.lock(); defer { lock.unlock() }; handler = value }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); let selected = handler; lock.unlock()
        guard let selected else { throw URLError(.badServerResponse) }
        return try selected(request)
    }
}

private final class CompositionFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = CompositionFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class PersonalizedPlannerClientTests: XCTestCase {
    private func interview() -> InterviewSession {
        let date = Date()
        var value = InterviewSession(createdAt: date)
        value.profile.adultStatus = ProfileField(value: true, provenance: .stated, confirmedAt: date)
        value.profile.primaryGoal = ProfileField(value: .generalFitness, provenance: .stated, confirmedAt: date)
        value.profile.experience = ProfileField(value: .beginner, provenance: .stated, confirmedAt: date)
        value.profile.weekdays = ProfileField(value: [1, 3, 5], provenance: .stated, confirmedAt: date)
        value.profile.minutesPerSession = ProfileField(value: 30, provenance: .stated, confirmedAt: date)
        value.profile.equipment = ProfileField(value: [.bodyweight, .dumbbells, .bench, .walkingSpace], provenance: .stated, confirmedAt: date)
        value.profile.restrictions = ProfileField(value: "无", provenance: .stated, confirmedAt: date)
        value.profile.capabilityNote = ProfileField(value: "CONFIRMED-CAPABILITY", provenance: .confirmed, confirmedAt: date)
        return value
    }

    private func request() throws -> PersonalizedPlanRequest {
        let session = interview()
        var snapshot = AppSnapshot(interview: session)
        snapshot.profile.equipmentNotes = "UNRELATED-RAW-PROFILE-NOT-SENT"
        return try PersonalizedPlanRequest.make(session: session, snapshot: snapshot)
    }

    func testPersonalizedPlanReceivesOwnNarrativeAndDeepAnswersAfterRestart() throws {
        var value = interview()
        let date = value.createdAt.addingTimeInterval(1)
        try value.addNarrative("NARRATIVE-SPECIFIC-HIKING-GOAL", at: date)
        let question = InterviewQuestion(topic: .capability, kind: .text, prompt: "具体能力？", detailKey: "capability.hiking_limit")
        try value.appendTurn(.init(questions: [question]), at: date)
        try value.answer([.init(questionID: question.id, text: "DEEP-ANSWER-RECORDED", answeredAt: date)], at: date)
        value = try value.restartedPreservingProfile(at: date.addingTimeInterval(1))
        XCTAssertThrowsError(try PersonalizedPlanRequest.make(session: value, snapshot: .init(interview: value)))
        try value.setValue(.text("无"), for: .restrictions, at: date.addingTimeInterval(2))
        let request = try PersonalizedPlanRequest.make(session: value, snapshot: .init(interview: value))
        let text = try PersonalizedPlannerAPI.requestJSON(request)
        XCTAssertTrue(text.contains("NARRATIVE-SPECIFIC-HIKING-GOAL"))
        XCTAssertTrue(text.contains("DEEP-ANSWER-RECORDED"))
        XCTAssertEqual(request.profile.capabilityNote.value, "CONFIRMED-CAPABILITY")
        XCTAssertFalse(request.confirmedFacts.values.contains("DEEP-ANSWER-RECORDED"))
    }

    func testPayloadUsesConfirmedInterviewAndRealMovementPoolInsteadOfWholeWeeklyOptions() throws {
        let prepared = try request()
        let preview = try PersonalizedPlannerAPI.requestJSON(prepared)
        XCTAssertTrue(preview.contains("CONFIRMED-CAPABILITY"))
        XCTAssertFalse(preview.contains("UNRELATED-RAW-PROFILE-NOT-SENT"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(preview.utf8)) as? [String: Any])
        XCTAssertNil(object["options"])
        XCTAssertNil(object["profile"])
        let definitions = try XCTUnwrap(object["movementDefinitions"] as? [[String: Any]])
        XCTAssertEqual(Set(definitions.compactMap { $0["id"] as? String }), Set(prepared.pool.values.flatMap { $0 }))
    }

    func testUnconfirmedExtractionBlocksCompositionUntilUserResolvesIt() throws {
        var session = interview()
        session.profile.sleepNote = ProfileField(value: "UNCONFIRMED-PRIVATE", provenance: .inferred)
        XCTAssertThrowsError(try PersonalizedPlanRequest.make(session: session, snapshot: AppSnapshot(interview: session)))
    }

    func testActualHTTPProtocolPathReturnsChoicesButDoesNotActivatePlan() async throws {
        let prepared = try request()
        let choices = prepared.pool.mapValues { $0.last! }
        let reply = PersonalizedPlanReply(choices: choices, explanation: "协议夹具验证动作选择，不代表真实模型效果", limitations: ["夹具"])
        let content = String(decoding: try JSONEncoder().encode(reply), as: UTF8.self)
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        CompositionFixtureProtocol.state.set { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return envelope
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompositionFixtureProtocol.self]
        let http = CoachHTTPClient(session: URLSession(configuration: config))
        let result = try await PersonalizedPlannerAPI(client: http).compose(prepared,
                                                                           configuration: AIConfiguration(endpoint: "https://fixture.invalid/v1/chat/completions", model: "fixture"),
                                                                           key: "fixture-token")
        XCTAssertEqual(result.choices, choices)
        XCTAssertEqual(prepared.baseline.decision, .pending)
        XCTAssertNil(prepared.baseline.appliedProgramID)
    }

    func testMalformedServiceReplyDoesNotFallBackToLocallyChosenWeek() async throws {
        let prepared = try request()
        let content = "{\"choices\":{},\"explanation\":\"遗漏动作\",\"limitations\":[]}"
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        CompositionFixtureProtocol.state.set { _ in envelope }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CompositionFixtureProtocol.self]
        do {
            _ = try await PersonalizedPlannerAPI(client: CoachHTTPClient(session: URLSession(configuration: config)))
                .compose(prepared, configuration: AIConfiguration(endpoint: "https://fixture.invalid/v1/chat/completions", model: "fixture"), key: "fixture-token")
            XCTFail("Invalid service choices must fail, never fall back to local defaults")
        } catch { XCTAssertNil(prepared.baseline.selection) }
    }
}
