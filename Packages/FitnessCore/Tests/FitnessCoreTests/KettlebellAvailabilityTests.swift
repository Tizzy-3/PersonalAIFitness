import XCTest
@testable import FitnessCore

final class KettlebellAvailabilityTests: XCTestCase {
    func testKettlebellEquipmentUsesOnlyExplicitlyReviewedAlternatives() {
        XCTAssertEqual(PlanningEquipment.kettlebells.title, "壶铃")
        XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: "builtin.goblet-squat", equipment: [.kettlebells]))
        XCTAssertTrue(PlannerEngine.isAvailable(exerciseID: "builtin.kettlebell-deadlift", equipment: [.kettlebells]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.dumbbell-bench-press", equipment: [.kettlebells]))
        XCTAssertFalse(PlannerEngine.isAvailable(exerciseID: "builtin.goblet-squat", equipment: []))
    }
}
