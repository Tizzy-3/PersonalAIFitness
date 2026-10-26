import Foundation
import XCTest
import FitnessCore
@testable import PersonalFitness

private struct PlannerHTTPResponse: Sendable { let status: Int; let data: Data }

private final class PlannerProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) throws -> PlannerHTTPResponse)?
    func set(_ value: @escaping @Sendable (URLRequest) throws -> PlannerHTTPResponse) {
        lock.lock(); defer { lock.unlock() }; handler = value
    }
    func respond(_ request: URLRequest) throws -> PlannerHTTPResponse {
        lock.lock(); let value = handler; lock.unlock()
        guard let value else { throw URLError(.resourceUnavailable) }
        return try value(request)
    }
}

private final class PlannerStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = PlannerProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let stub = try Self.state.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class PlannerClientTests: XCTestCase {
    private let configuration = AIConfiguration(endpoint: "https://planner.example.invalid/v1/chat/completions", model: "fixture-model")

    private func draft() throws -> PlanningDraft {
        var profile = PersonalProfile()
        profile.goal = "PRIVATE-PROFILE-GOAL-DO-NOT-SEND"
        profile.equipmentNotes = "PRIVATE-EQUIPMENT-NOTES-DO-NOT-SEND"
        return try PlanningDraft.make(input: input(), snapshot: AppSnapshot(profile: profile))
    }

    private func input() -> PlanningInput {
        PlanningInput(goal: .generalFitness, experience: .beginner, weekdays: [1, 3, 5], minutesPerSession: 30,
                      equipment: [.bodyweight, .dumbbells, .bench, .walkingSpace],
                      adultConfirmed: true, safety: .noKnownRestrictions, painToday: false)
    }

    private func client(_ handler: @escaping @Sendable (URLRequest) throws -> PlannerHTTPResponse) -> CoachHTTPClient {
        PlannerStubProtocol.state.set(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerStubProtocol.self]
        return CoachHTTPClient(session: URLSession(configuration: configuration))
    }

    private func envelope(_ object: [String: Any]) throws -> Data {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
    }

    func testPlanningConsentPayloadOmitsRawProfileAndContainsOnlyRealReferencedMovements() throws {
        let draft = try draft()
        let json = try PlannerAPI.requestJSON(draft: draft)
        XCTAssertFalse(json.contains("PRIVATE-PROFILE"))
        XCTAssertFalse(json.contains("PRIVATE-EQUIPMENT"))
        XCTAssertFalse(json.contains("sourceProfile"))
        XCTAssertFalse(json.contains("fixture-token"))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let object = try XCTUnwrap(decoded as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["dataAsOf", "request", "options", "movementDefinitions", "allowedEvidenceIDs"]))
        let movements = try XCTUnwrap(object["movementDefinitions"] as? [[String: Any]])
        let actual = Set(movements.compactMap { $0["id"] as? String })
        let expected = Set(draft.options.flatMap(\.days).flatMap(\.items).map(\.exerciseID))
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(actual.isEmpty)
    }

    @MainActor
    func testRealProtocolFixtureSelectsExistingOptionWithoutChangingPlans() async throws {
        let draft = try draft()
        let id = try XCTUnwrap(draft.options.first?.id)
        let data = try envelope(["optionID": id, "explanation": "协议夹具选择，不是真实模型效果", "evidence": ["request", "rules", "option:\(id)"], "limitations": ["夹具验证协议"]])
        let fixture = client { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            return PlannerHTTPResponse(status: 200, data: data)
        }
        let selection = try await PlannerAPI(client: fixture).select(draft: draft, configuration: configuration, key: "fixture-token")
        XCTAssertEqual(selection.optionID, id)
        XCTAssertEqual(draft.decision, .pending)
        XCTAssertNil(draft.appliedProgramID)
        XCTAssertNil(draft.selection)
    }

    @MainActor
    func testUnknownOptionCannotBecomeAPlan() async throws {
        let draft = try draft()
        let data = try envelope(["optionID": "invented-option", "explanation": "虚构候选", "evidence": ["rules"], "limitations": []])
        let fixture = client { _ in PlannerHTTPResponse(status: 200, data: data) }
        do {
            _ = try await PlannerAPI(client: fixture).select(draft: draft, configuration: configuration, key: "fixture-token")
            XCTFail("Unknown option must be rejected")
        } catch { XCTAssertTrue(error is CoreError) }
    }

    @MainActor
    func testModelCannotReturnDirectWorkoutFields() async throws {
        let draft = try draft()
        let id = try XCTUnwrap(draft.options.first?.id)
        let data = try envelope(["optionID": id, "explanation": "不允许直接改组数", "evidence": ["rules"], "limitations": [], "items": [["setCount": 99]]])
        let fixture = client { _ in PlannerHTTPResponse(status: 200, data: data) }
        do {
            _ = try await PlannerAPI(client: fixture).select(draft: draft, configuration: configuration, key: "fixture-token")
            XCTFail("Direct write fields must be rejected")
        } catch { XCTAssertTrue(error is CoreError) }
    }

    @MainActor
    func testServiceFailureDoesNotSilentlyBecomeLocalAISuccess() async throws {
        let draft = try draft()
        let fixture = client { _ in PlannerHTTPResponse(status: 401, data: Data("not an answer".utf8)) }
        do {
            _ = try await PlannerAPI(client: fixture).select(draft: draft, configuration: configuration, key: "fixture-token")
            XCTFail("Authentication failure must remain failure")
        } catch { XCTAssertEqual(error as? CoachClientError, .authentication) }
        XCTAssertNil(draft.selection)
        XCTAssertNil(draft.appliedProgramID)
    }

    @MainActor
    func testAISelectionCreatesWeeklyAndDailyPlansOnlyAfterExplicitConfirmation() async throws {
        let store = try TrainingStore(inMemory: true)
        let exercise = try XCTUnwrap(ExerciseCatalog.exercises.first)
        let original = try store.confirmPlan(name: "原手动计划", items: [PlannedExercise(exercise: exercise)])
        let draft = try PlanningDraft.make(input: input(), snapshot: store.snapshot())
        try store.savePlanningDraft(draft)
        let id = try XCTUnwrap(draft.options.first?.id)
        let data = try envelope(["optionID": id, "explanation": "协议夹具，仅验证确认链路", "evidence": ["request", "option:\(id)"], "limitations": ["不代表真实供应商效果"]])
        let fixture = client { _ in PlannerHTTPResponse(status: 200, data: data) }
        var selected = draft
        selected.selection = try await PlannerAPI(client: fixture).select(draft: draft, configuration: configuration, key: "fixture-token")
        selected.providerHost = try configuration.validatedURL().host
        selected.model = configuration.model
        try store.savePlanningDraft(selected)
        XCTAssertEqual(store.currentPlan, original)
        XCTAssertNil(store.currentWeeklyProgram)
        let program = try store.confirmWeeklyProgram(draftID: draft.id, optionID: id)
        XCTAssertEqual(program.selectedOptionID, id)
        XCTAssertEqual(program.dayPlanVersionIDs.count, program.selectedOption?.days.filter { !$0.isRestDay }.count)
        XCTAssertEqual(store.currentWeeklyProgram?.id, program.id)
        XCTAssertNil(store.currentPlan)
        XCTAssertEqual(store.planVersions.count, 1 + program.dayPlanVersionIDs.count)
        XCTAssertThrowsError(try store.confirmWeeklyProgram(draftID: draft.id, optionID: id))
    }
}
