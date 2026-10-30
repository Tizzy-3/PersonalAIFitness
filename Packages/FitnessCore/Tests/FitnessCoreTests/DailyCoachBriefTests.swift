import Foundation
import XCTest
@testable import FitnessCore

/// The home-screen brief must say only what the saved facts support: safety first, no encouragement
/// on a caution or safety day, and never a plan when there is no plan.
final class DailyCoachBriefTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func exercise() throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.barbell-bench-press"))
    }

    private func plan(sets: Int = 3) throws -> PlanVersion {
        let item = PlannedExercise(exercise: try exercise(), setCount: sets, targetReps: 10, restSeconds: 90)
        return PlanVersion(name: "上肢", items: [item], confirmedAt: now.addingTimeInterval(-86_400))
    }

    private func checkIn(pain: Bool?, energy: Int? = nil, minutes: Int? = nil) -> PreWorkoutCheckIn {
        PreWorkoutCheckIn(createdAt: now, energy: energy, painReported: pain, availableMinutes: minutes)
    }

    private func make(checkIn: PreWorkoutCheckIn? = nil,
                      restrictions: String? = nil,
                      plan: PlanVersion? = nil,
                      hasWeeklyProgram: Bool = true,
                      restDay: Bool = false,
                      active: WorkoutSession? = nil,
                      lastFinished: WorkoutSession? = nil,
                      feedback: SessionFeedback? = nil,
                      completedToday: SessionFeedback? = nil) -> DailyCoachBrief {
        DailyCoachBrief.make(now: now, checkIn: checkIn, profileRestrictions: restrictions,
                             plan: plan, hasWeeklyProgram: hasWeeklyProgram, isConstraintRestDay: restDay,
                             activeSession: active, lastFinishedSession: lastFinished,
                             lastFeedback: feedback, completedToday: completedToday, calendar: calendar)
    }

    // MARK: - Safety wins

    func testReportedPainOutranksThePlanAndTheCompletedWorkout() throws {
        let brief = make(checkIn: checkIn(pain: true), plan: try plan())
        XCTAssertEqual(brief.tone, .safety)
        XCTAssertFalse(brief.tone.allowsEncouragement)
        XCTAssertTrue(brief.headline.contains("别急着"))
        XCTAssertFalse(brief.needsPainAnswer)

        let withFeedback = make(checkIn: checkIn(pain: true), plan: try plan(),
                                completedToday: SessionFeedback(sessionID: UUID(), completedWorkingSets: 9))
        XCTAssertEqual(withFeedback.tone, .safety, "疼痛不能被一次已完成训练覆盖")
    }

    func testNullRestrictionsAreNotTreatedAsALimit() {
        for text in ["无", "无已知限制", "无运动限制", "没有已知限制", "none", " 无 ", ""] {
            XCTAssertFalse(DailyCoachBrief.isRealRestriction(text), text)
        }
        XCTAssertTrue(DailyCoachBrief.isRealRestriction("右膝半月板术后，医生要求避免深蹲"))
    }

    func testProfileRestrictionBlocksAutomaticPlanning() throws {
        let brief = make(checkIn: checkIn(pain: false), restrictions: "腰椎间盘突出", plan: try plan())
        XCTAssertEqual(brief.tone, .safety)
        XCTAssertTrue(brief.headline.contains("限制"))
    }

    // MARK: - No plan / rest

    func testFirstRunSaysWhatHappensNextInsteadOfShowingAPlan() {
        let brief = make(hasWeeklyProgram: false)
        XCTAssertEqual(brief.tone, .welcome)
        XCTAssertEqual(brief.needsPainAnswer, true)
        XCTAssertTrue(brief.details.contains { $0.contains("目标") })
    }

    func testRestDayIsStatedAsRestAndNamesTheConstraintWhenItApplies() {
        let plain = make(restDay: false)
        XCTAssertEqual(plain.tone, .rest)
        XCTAssertTrue(plain.details.contains { $0.contains("休息日") })

        let constraint = make(restDay: true)
        XCTAssertEqual(constraint.tone, .rest)
        XCTAssertTrue(constraint.details.contains { $0.contains("明确排除") })
    }

    // MARK: - Missing pain answer

    func testPlanIsNotPresentedAsClearedWithoutAPainAnswer() throws {
        let brief = make(checkIn: nil, plan: try plan())
        XCTAssertEqual(brief.tone, .caution)
        XCTAssertTrue(brief.needsPainAnswer)
        XCTAssertFalse(brief.tone.allowsEncouragement)
        XCTAssertFalse(brief.headline.contains("今天练"))
    }

    func testAnsweredNoPainGivesThePlanBrief() throws {
        let brief = make(checkIn: checkIn(pain: false), plan: try plan())
        XCTAssertEqual(brief.tone, .plan)
        XCTAssertTrue(brief.headline.contains("上肢"))
        XCTAssertFalse(brief.needsPainAnswer)
        XCTAssertTrue(brief.details.first?.contains("个动作") ?? false)
    }

    // MARK: - Already finished today

    func testFinishedSessionIsReportedBeforeAnyFurtherTraining() {
        let feedback = SessionFeedback(sessionID: UUID(), createdAt: now, completedWorkingSets: 7,
                                       totalSeconds: 1_800, tooHard: true)
        let brief = make(checkIn: checkIn(pain: false), completedToday: feedback)
        XCTAssertEqual(brief.tone, .done)
        XCTAssertTrue(brief.details.first?.contains("7") ?? false)
        XCTAssertTrue(brief.details.contains { $0.contains("更吃力") })
    }

    func testPostSessionPainIsCalledOutWithoutDiagnosing() {
        let feedback = SessionFeedback(sessionID: UUID(), createdAt: now, completedWorkingSets: 4,
                                       totalSeconds: 900, painReported: true)
        let brief = make(checkIn: checkIn(pain: false), completedToday: feedback)
        XCTAssertEqual(brief.tone, .done)
        XCTAssertTrue(brief.details.contains { $0.contains("报告了疼痛") })
        XCTAssertFalse(brief.details.contains { $0.contains("诊断") })
    }

    // MARK: - Running workout

    private func runningSession() throws -> WorkoutSession {
        let started = now.addingTimeInterval(-600)
        let set = LoggedSet(reps: 10)
        let session = WorkoutSession(name: "上肢", sourcePlanVersionID: nil, startedAt: started,
                                     exercises: [WorkoutExercise(exercise: try exercise(), sets: [set, set, set])])
        return session
    }

    func testActiveSessionIsSurfacedBeforeStartingAnother() throws {
        let brief = make(checkIn: checkIn(pain: false), active: try runningSession())
        XCTAssertEqual(brief.tone, .plan)
        XCTAssertEqual(brief.headline, "正在训练中。")
        XCTAssertFalse(brief.needsPainAnswer, "进行中的训练不需要先追问疼痛")
    }

    // MARK: - Low energy / short time

    func testLowEnergySuggestsTheConfirmedReductionPathInsteadOfLoweringSets() throws {
        let brief = make(checkIn: checkIn(pain: false, energy: 1), plan: try plan())
        XCTAssertEqual(brief.tone, .caution)
        XCTAssertTrue(brief.details.contains { $0.contains("今天少一点") })
        XCTAssertFalse(brief.details.contains { $0.contains("减到") }, "简报不能自己改组数")
    }

    func testRecordedTimeShorterThanThePlanIsNamed() throws {
        let brief = make(checkIn: checkIn(pain: false, minutes: 10), plan: try plan())
        XCTAssertEqual(brief.tone, .caution)
        XCTAssertTrue(brief.details.contains { $0.contains("10 分钟") })
    }

    // MARK: - Evidence hygiene

    func testEvidenceComesOnlyFromSavedFacts() throws {
        let brief = make(checkIn: checkIn(pain: false), plan: try plan())
        XCTAssertFalse(brief.evidence.isEmpty)
        XCTAssertTrue(brief.evidence.contains { $0.contains("训练前记录") })
        XCTAssertTrue(brief.evidence.contains { $0.contains("今日计划") })
        for line in brief.evidence { XCTAssertFalse(line.isEmpty) }
    }

    func testDetailsNeverExceedTwoLines() throws {
        let session = try WorkoutSession.start(plan: try plan(), at: now.addingTimeInterval(-1_800))
        let brief = make(checkIn: checkIn(pain: false, energy: 5), plan: try plan(), lastFinished: session)
        XCTAssertLessThanOrEqual(brief.details.count, 2)
    }

    func testEmptyPlanIsNeverDescribedAsTraining() {
        let brief = make(plan: nil, hasWeeklyProgram: false)
        XCTAssertNotEqual(brief.tone, .plan)
    }

    // MARK: - Agreement with the real readiness engine

    func testBriefSurfacesAQuestionExactlyWhenReadinessWouldRefuseToClearToday() {
        XCTAssertNotNil(ReadinessEngine.blockingQuestion(checkIn: nil, profile: StructuredProfile(), now: now))
        XCTAssertNotNil(ReadinessEngine.blockingQuestion(
            checkIn: PreWorkoutCheckIn(createdAt: now.addingTimeInterval(-86_400), painReported: false),
            profile: StructuredProfile(), now: now), "昨天的回答不能当作今天已回答")

        XCTAssertNil(ReadinessEngine.blockingQuestion(checkIn: checkIn(pain: false), profile: StructuredProfile(),
                                                      now: now))
        XCTAssertNil(ReadinessEngine.blockingQuestion(checkIn: checkIn(pain: true), profile: StructuredProfile(),
                                                      now: now), "报告疼痛不等于还需要回答同一个问题")

        var restricted = StructuredProfile()
        restricted.restrictions = ProfileField(value: "医生要求避免负重", provenance: .confirmed,
                                               confirmedAt: now.addingTimeInterval(-86_400), note: nil)
        let restrictedQuestion = ReadinessEngine.blockingQuestion(checkIn: checkIn(pain: false),
                                                                  profile: restricted, now: now)
        XCTAssertNotNil(restrictedQuestion)
        XCTAssertTrue(restrictedQuestion?.contains("限制") ?? false)
    }

    func testCautionForLowEnergyAndClearedDayDisagreeAsExpected() throws {
        let lowEnergy = make(checkIn: checkIn(pain: false, energy: 1), plan: try plan())
        XCTAssertEqual(lowEnergy.tone, .caution)
        let cleared = make(checkIn: checkIn(pain: false), plan: try plan())
        XCTAssertEqual(cleared.tone, .plan)
        XCTAssertNil(ReadinessEngine.blockingQuestion(checkIn: checkIn(pain: false), profile: StructuredProfile(),
                                                      now: now),
                     "已经回答了疼痛、也没有记录限制时，没有阻塞性问题")
    }
}

/// The reply shown right after a workout is saved. Same rule as the daily brief: report, don't praise
/// what the app cannot verify, and never turn a reported pain into a success message.
final class SessionCoachReplyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func exercise() throws -> Exercise {
        try XCTUnwrap(ExerciseCatalog.exercise(id: "builtin.barbell-bench-press"))
    }

    private func session(completedSets: Int, plannedSets: Int = 3) throws -> WorkoutSession {
        let sets = (0..<plannedSets).map { index in
            LoggedSet(reps: 10, loadKG: 20, completedAt: index < completedSets ? now : nil)
        }
        var session = WorkoutSession(name: "上肢", startedAt: now.addingTimeInterval(-1_800),
                                     exercises: [WorkoutExercise(exercise: try exercise(), sets: sets)])
        try session.finish(early: false, at: now)
        try session.validate()
        return session
    }

    func testPainIsReportedWithTheAreaAndWithoutADiagnosis() throws {
        let feedback = SessionFeedback(sessionID: UUID(), painReported: true, painAreas: ["右肩"])
        let reply = SessionCoachReply.make(feedback: feedback, session: try session(completedSets: 3))
        XCTAssertTrue(reply.isSafetyConcern)
        XCTAssertTrue(reply.headline.contains("右肩"))
        XCTAssertFalse(reply.headline.contains("好") || reply.headline.contains("棒"))
        XCTAssertFalse(reply.details.contains { $0.contains("诊断") })
    }

    func testTooHardDoesNotTriggerProgression() throws {
        let feedback = SessionFeedback(sessionID: UUID(), perceivedExertion: 9, tooHard: true)
        let reply = SessionCoachReply.make(feedback: feedback, session: try session(completedSets: 3))
        XCTAssertTrue(reply.headline.contains("吃力"))
        XCTAssertTrue(reply.details.contains { $0.contains("同样的量") })
        XCTAssertFalse(reply.details.contains { $0.contains("加重量") || $0.contains("提高强度") })
    }

    func testAchievementStylePraiseRequiresAnActualRecord() throws {
        let feedback = SessionFeedback(sessionID: UUID(), perceivedExertion: 7)
        let reply = SessionCoachReply.make(feedback: feedback, session: try session(completedSets: 2))
        XCTAssertTrue(reply.details.first?.contains("2 / 3") ?? false)
        XCTAssertFalse(reply.isSafetyConcern)
    }

    func testZeroCompletedSetsIsRecordedAsSuch() throws {
        let feedback = SessionFeedback(sessionID: UUID(), perceivedExertion: nil)
        let reply = SessionCoachReply.make(feedback: feedback, session: try session(completedSets: 0))
        XCTAssertTrue(reply.headline.contains("没有完成"))
        XCTAssertFalse(reply.isSafetyConcern)
    }

    func testHeadroomIsNotProgressionByItself() throws {
        let feedback = SessionFeedback(sessionID: UUID(), perceivedExertion: 5)
        let reply = SessionCoachReply.make(feedback: feedback, session: try session(completedSets: 3))
        XCTAssertTrue(reply.details.contains { $0.contains("现在先按原量") })
    }
}
