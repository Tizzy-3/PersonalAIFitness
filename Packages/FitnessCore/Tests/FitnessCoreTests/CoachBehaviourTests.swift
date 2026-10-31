import XCTest
import Foundation
@testable import FitnessCore

/// The person asked for a coach that "encourages and confirms you can train" rather than letting a
/// bad mood remove the session. These tests pin the line between encouragement and overruling safety.
final class CoachBehaviourTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func exercise() throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.barbell-bench-press"))
    }

    private func plan(sets: Int = 3) throws -> PlanVersion {
        PlanVersion(name: "上肢",
                    items: [PlannedExercise(exercise: try exercise(), setCount: sets,
                                            targetReps: 10, restSeconds: 90)],
                    confirmedAt: now)
    }

    private func session(completed: Int, planned: Int = 3) throws -> WorkoutSession {
        let started = now.addingTimeInterval(-86_400 - 1_800)
        let sets = (0..<planned).map { index in
            LoggedSet(loadKG: 20, reps: 10,
                      completedAt: index < completed ? started.addingTimeInterval(300) : nil)
        }
        var value = WorkoutSession(name: "上肢", startedAt: started,
                                   exercises: [WorkoutExercise(exercise: try exercise(), sets: sets)])
        try value.finish(early: false, at: now.addingTimeInterval(-86_400))
        return value
    }

    // MARK: - Yesterday's review

    func testYesterdayReviewUsesRealNumbersNotPraise() throws {
        let review = YesterdayReview.make(session: try session(completed: 2), feedback: nil,
                                          calories: 120, plan: try plan(), now: now)
        XCTAssertTrue(review.trainedYesterday)
        XCTAssertTrue(review.details.first?.contains("2 / 3") ?? false)
        XCTAssertTrue(review.details.first?.contains("120") ?? false)
    }

    func testAbsentSessionSaysSoInsteadOfInventingProgress() {
        let review = YesterdayReview.make(session: nil, feedback: nil, calories: nil,
                                          plan: nil, now: now)
        XCTAssertFalse(review.trainedYesterday)
        XCTAssertTrue(review.headline.contains("没有训练记录"))
    }

    func testHardMovementsAreNamedNotJustScored() throws {
        var value = try session(completed: 3)
        value.exercises[0].exertion = 5
        let review = YesterdayReview.make(session: value, feedback: nil, calories: nil,
                                          plan: try plan(), now: now)
        XCTAssertTrue(review.feltHard)
        // The catalogue name is 杠铃卧推; asserting the wrong label would pass only by luck.
        XCTAssertTrue(review.details.contains { $0.contains("杠铃卧推") })
    }

    func testPainYesterdaySuppressesTheEncouragementToTrain() throws {
        let feedback = SessionFeedback(sessionID: UUID(), createdAt: now, painReported: true)
        let review = YesterdayReview.make(session: try session(completed: 3), feedback: feedback,
                                          calories: nil, plan: try plan(), now: now)
        XCTAssertTrue(review.headline.contains("疼"))
        XCTAssertNil(review.encouragement, "说了疼就不能再劝今天照常训练")
    }

    // MARK: - Skip responses

    func testReluctanceGetsOneConcretePushNotARestDay() throws {
        let reply = SkipResponse.reply(to: .reluctance, plan: try plan())
        XCTAssertFalse(reply.acceptsRest)
        let option = try XCTUnwrap(reply.smallerOption)
        XCTAssertTrue(option.contains("2 组"), "应给出比原计划更小的具体数量")
        XCTAssertTrue(reply.message.contains("不想练"))
    }

    func testPainIsAcceptedImmediatelyWithoutNegotiation() {
        let reply = SkipResponse.reply(to: .pain, plan: nil)
        XCTAssertTrue(reply.acceptsRest)
        XCTAssertNil(reply.smallerOption, "疼的时候不该再给一个少做点的选项")
        XCTAssertTrue(reply.message.contains("先别练"))
    }

    func testRestrictionDefersToTheProfessional() {
        let reply = SkipResponse.reply(to: .restriction, plan: nil)
        XCTAssertTrue(reply.acceptsRest)
        XCTAssertTrue(reply.message.contains("医生"))
    }

    func testClassificationDoesNotInventPainFromVagueText() {
        XCTAssertEqual(SkipResponse.classify("今天不想练"), .reluctance)
        XCTAssertEqual(SkipResponse.classify("没时间"), .reluctance)
        XCTAssertEqual(SkipResponse.classify("今天太累了"), .reluctance)
        // Explicit signals do move it.
        XCTAssertEqual(SkipResponse.classify("膝盖有点疼"), .pain)
        XCTAssertEqual(SkipResponse.classify("医生说要休息两周"), .restriction)
    }

    func testNoPlanStillGivesAStartingPoint() {
        let reply = SkipResponse.reply(to: .reluctance, plan: nil)
        XCTAssertFalse(reply.acceptsRest)
        XCTAssertNotNil(reply.smallerOption)
        XCTAssertTrue(reply.smallerOption?.contains("五分钟") ?? false)
    }
}
