import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

private final class ConstraintSuggestionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [String] = []
    private var bodies: [Data] = []
    func reset(_ content: String) { reset([content]) }
    func reset(_ replies: [String]) { lock.lock(); defer { lock.unlock() }; self.replies = replies; bodies = [] }
    func respond(_ request: URLRequest) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        bodies.append(try HTTPRequestBodyFixture.read(request))
        guard !replies.isEmpty else { throw URLError(.resourceUnavailable) }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": replies.removeFirst()], "finish_reason": "stop"]]])
    }
    func requestBody() -> Data? { lock.lock(); defer { lock.unlock() }; return bodies.last }
    func requests() -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
}
private final class ConstraintSuggestionProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = ConstraintSuggestionFixture()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.fixture.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class ConstraintSuggestionTests: XCTestCase {
    private let valid = #"{"excludedExerciseIDs":["builtin.bird-dog"],"avoidedPositions":["kneeling"],"excludedWeekdays":[2],"restDateKeys":["2028-02-29"],"maxSessionMinutes":25,"questions":["这个休息日只执行一次吗？"],"unresolved":[]}"#

    func testKnownConstraintsRemainSuggestionsAndSingleDatesAreNotExpandedIntoWeekdays() throws {
        let value = try ConstraintSuggestion.decode(valid)
        XCTAssertEqual(value.excludedWeekdays, [2])
        XCTAssertEqual(value.restDateKeys, ["2028-02-29"])
        XCTAssertEqual(value.avoidedPositions, [.kneeling])
        XCTAssertEqual(value.maxSessionMinutes, 25)
        XCTAssertEqual(value.questions.count, 1)
    }

    func testUnknownMovementsAndUnauthorizedHealthPermissionFieldsAreRejectedWithoutRawEcho() throws {
        for content in [valid.replacingOccurrences(of: "builtin.bird-dog", with: "invented-by-model"),
                        String(valid.dropLast()) + #", "painFreeConfirmed":true}"#,
                        String(valid.dropLast()) + #", "mode":"practicalOnly"}"#,
                        "PRIVATE-FAILED-OUTPUT"] {
            XCTAssertThrowsError(try ConstraintSuggestion.decode(String(content))) { error in
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
                XCTAssertFalse(error.localizedDescription.contains("invented-by-model"))
            }
        }
    }

    func testMalformedDateDuplicateIDsAndOutOfRangeLimitsAreRejected() throws {
        for content in [valid.replacingOccurrences(of: "2028-02-29", with: "2027-02-29"),
                        valid.replacingOccurrences(of: "[2]", with: "[2,2]"),
                        valid.replacingOccurrences(of: "\"maxSessionMinutes\":25", with: "\"maxSessionMinutes\":5"),
                        valid.replacingOccurrences(of: "\"maxSessionMinutes\":25", with: "\"maxSessionMinutes\":true")] {
            XCTAssertThrowsError(try ConstraintSuggestion.decode(content))
        }
    }

    func testRequestContainsOnlyDisclosedSourcesAndExplicitReferenceZone() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var session = InterviewSession(createdAt: date)
        try session.addNarrative("只想避开跪姿，周二有固定安排", at: date)
        let text = try ConstraintSuggestionAPI.requestJSON(session: session, legacyRestrictions: "原档案的安排限制", at: date, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["promptVersion", "referenceDate", "timeZone", "sourceText", "legacySourceText", "userNarratives", "supportedExercises"]))
        XCTAssertEqual(object["legacySourceText"] as? String, "原档案的安排限制")
        XCTAssertTrue(text.contains("只想避开跪姿"))
        XCTAssertFalse(text.contains("HKQuantity"))
        let ids = Set(try XCTUnwrap(object["supportedExercises"] as? [[String: String]]).compactMap { $0["id"] })
        XCTAssertEqual(ids, Set(PlannerEngine.supportedMovementIDs))
    }

    @MainActor
    func testActualHTTPReplyDoesNotConfirmOrMutateTheSavedInterview() async throws {
        ConstraintSuggestionProtocol.fixture.reset(valid)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConstraintSuggestionProtocol.self]
        let client = ConstraintSuggestionAPI(client: CoachHTTPClient(session: URLSession(configuration: config)))
        let initial = InterviewSession()
        let value = try await client.suggest(session: initial, legacyRestrictions: "休息安排", configuration: .init(endpoint: "https://fixture.example/chat/completions", model: "fixture"), key: "fixture-key")
        XCTAssertEqual(value.excludedWeekdays, [2])
        XCTAssertNil(initial.profile.constraintReview)
        XCTAssertEqual(initial.profile.restrictions.provenance, .unknown)
        let data = try XCTUnwrap(ConstraintSuggestionProtocol.fixture.requestBody())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0]["content"]?.contains("不能批准运动") ?? false)
        XCTAssertTrue(messages[1]["content"]?.contains("休息安排") ?? false)
    }

    @MainActor
    func testPlannerRequestStopsAtTheSamePendingConstraintGate() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var profile = StructuredProfile()
        profile.adultStatus = .init(value: true, provenance: .stated, confirmedAt: date)
        profile.primaryGoal = .init(value: .generalFitness, provenance: .stated, confirmedAt: date)
        profile.experience = .init(value: .beginner, provenance: .stated, confirmedAt: date)
        profile.weekdays = .init(value: [1, 4], provenance: .stated, confirmedAt: date)
        profile.minutesPerSession = .init(value: 30, provenance: .stated, confirmedAt: date)
        profile.equipment = .init(value: [.bodyweight, .walkingSpace], provenance: .stated, confirmedAt: date)
        profile.restrictions = .init(value: "避开跪姿", provenance: .stated, confirmedAt: date)
        let session = InterviewSession(createdAt: date, profile: profile)
        let snapshot = AppSnapshot(interview: session)
        let eligibility = session.planningEligibility(legacyRestrictions: snapshot.profile.restrictions, at: date, snapshot: snapshot)
        XCTAssertFalse(eligibility.canGenerate)
        XCTAssertTrue(eligibility.needsConstraintReview)
        XCTAssertThrowsError(try PersonalizedPlanRequest.make(session: session, snapshot: snapshot, at: date)) { error in
            XCTAssertEqual(error.localizedDescription, CoreError.invalidState(eligibility.message).localizedDescription)
        }
    }

    @MainActor
    func testMalformedSuggestionGetsOnlyOneFormatCorrectionWithoutForwardingFailedRawText() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ConstraintSuggestionProtocol.self]
        let api = ConstraintSuggestionAPI(client: CoachHTTPClient(session: URLSession(configuration: config)))
        let service = AIConfiguration(endpoint: "https://fixture.example/chat/completions", model: "fixture")
        ConstraintSuggestionProtocol.fixture.reset(["PRIVATE-BAD-REPLY", valid])
        _ = try await api.suggest(session: InterviewSession(), legacyRestrictions: "", configuration: service, key: "fixture-key")
        let requests = ConstraintSuggestionProtocol.fixture.requests()
        XCTAssertEqual(requests.count, 2)
        let second = try XCTUnwrap(requests.last)
        XCTAssertFalse(String(decoding: second, as: UTF8.self).contains("PRIVATE-BAD-REPLY"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertEqual((body["response_format"] as? [String: String])?["type"], "json_object")
        ConstraintSuggestionProtocol.fixture.reset(["PRIVATE-FIRST", "PRIVATE-SECOND"])
        do {
            _ = try await api.suggest(session: InterviewSession(), legacyRestrictions: "", configuration: service, key: "fixture-key")
            XCTFail("Invalid correction cannot become a suggestion")
        } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
        XCTAssertEqual(ConstraintSuggestionProtocol.fixture.requests().count, 2)
    }
}
