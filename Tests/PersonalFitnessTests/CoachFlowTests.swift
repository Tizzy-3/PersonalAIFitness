import XCTest
@testable import PersonalFitness

final class CoachFlowTests: XCTestCase {
    @MainActor
    func testDailyConversationDoesNotTriggerAWeeklyReplan() {
        XCTAssertFalse(CoachConversationView.requestsWeeklyReplan("今天很累，训练能不能轻一点"))
        XCTAssertFalse(CoachConversationView.requestsWeeklyReplan("这一周怎么安排的？"))
        XCTAssertFalse(CoachConversationView.requestsWeeklyReplan("不要调整周计划"))
        XCTAssertFalse(CoachConversationView.requestsWeeklyReplan("保持每周安排不变"))
        XCTAssertTrue(CoachConversationView.requestsWeeklyReplan("重新制定一周计划"))
        XCTAssertTrue(CoachConversationView.requestsWeeklyReplan("调整一下周计划"))
    }
}
