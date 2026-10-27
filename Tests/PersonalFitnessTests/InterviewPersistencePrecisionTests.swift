import XCTest
import FitnessCore
@testable import PersonalFitness

final class InterviewPersistencePrecisionTests: XCTestCase {
    @MainActor
    func testPublishedInterviewUsesTheSameRepresentationAsSavedPayload() throws {
        let store = try TrainingStore(inMemory: true)
        var original = try store.startInterview()
        original.profile.primaryGoal = ProfileField(value: .strength, provenance: .stated,
                                                     confirmedAt: Date(timeIntervalSince1970: 1_790_000_000.1234567))
        let expected = try RecordCodec.decode(InterviewSession.self, from: RecordCodec.encode(original))
        try store.saveInterview(original)
        XCTAssertEqual(store.interview, expected)
        XCTAssertEqual(try store.startInterview(), expected)
    }

    @MainActor
    func testUpdateReturnsTheCanonicalSavedSessionRatherThanItsInputCopy() throws {
        let store = try TrainingStore(inMemory: true)
        let returned = try store.updateInterview { value in
            try value.setValue(.minutes(30), for: .minutes, at: Date())
        }
        XCTAssertEqual(returned, store.interview)
        let canonical = try RecordCodec.decode(InterviewSession.self, from: RecordCodec.encode(returned))
        XCTAssertEqual(returned, canonical)
    }
}
