import XCTest
import FitnessCore
@testable import PersonalFitness

final class HistoryValidationTests: XCTestCase {
    @MainActor
    func testCalendarScreenshotFixtureUsesOnlyAnIsolatedMemoryStoreAndValidRecords() throws {
        let fixture = try HistoryValidationData.makeStore()
        XCTAssertNil(fixture.storageURL)
        XCTAssertNil(fixture.recoverySnapshotURL)
        XCTAssertGreaterThanOrEqual(fixture.sessions.count, 2)
        XCTAssertEqual(fixture.sessions.filter { $0.status.isOngoing }.count, 1)
        XCTAssertEqual(fixture.activeSession?.status, .paused)
        for session in fixture.sessions { XCTAssertNoThrow(try session.validate()) }
        XCTAssertNoThrow(try fixture.snapshot().validate())

        let ordinary = try TrainingStore(inMemory: true)
        XCTAssertTrue(ordinary.sessions.isEmpty)
        XCTAssertTrue(ordinary.planVersions.isEmpty)
    }
}
