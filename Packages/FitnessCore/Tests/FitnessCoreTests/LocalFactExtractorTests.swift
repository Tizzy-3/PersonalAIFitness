import XCTest
import Foundation
@testable import FitnessCore

/// The local extractor exists so a chat endpoint that only speaks prose can still fill a profile.
/// Its whole value depends on one property: it reads only what is unmistakably stated.
final class LocalFactExtractorTests: XCTestCase {

    // MARK: - Equipment

    func testReadsTheEquipmentPeopleActuallyName() {
        XCTAssertEqual(LocalFactExtractor.equipment(in: "家里有哑铃和壶铃"),
                       [.dumbbells, .kettlebells])
        XCTAssertEqual(LocalFactExtractor.equipment(in: "有卧推凳和杠铃"),
                       [.bench, .barbell])
    }

    func testHomeTrainingWithoutNamingToolsFallsBackToBodyweight() {
        XCTAssertEqual(LocalFactExtractor.equipment(in: "在家练，没买器材"), [.bodyweight])
    }

    func testNoMentionOfEquipmentYieldsNothing() {
        XCTAssertTrue(LocalFactExtractor.equipment(in: "我想减脂，目标是明年瘦到75kg").isEmpty)
    }

    // MARK: - Schedule

    func testReadsWeekdaysInSeveralForms() {
        XCTAssertEqual(LocalFactExtractor.weekdays(in: "周一周二周四周五可以练"), [1, 2, 4, 5])
        XCTAssertEqual(LocalFactExtractor.weekdays(in: "周一、周三、周五"), [1, 3, 5])
        XCTAssertEqual(LocalFactExtractor.weekdays(in: "星期六和星期天"), [6, 7])
    }

    func testMinutesAreOnlyTakenFromATimePhrase() {
        XCTAssertEqual(LocalFactExtractor.minutesPerSession(in: "每次30分钟"), 30)
        XCTAssertEqual(LocalFactExtractor.minutesPerSession(in: "每次 45 分钟"), 45)
        // A number that is not followed by a time unit must not become a duration.
        XCTAssertNil(LocalFactExtractor.minutesPerSession(in: "我想瘦到75kg"))
        // Outside the supported range is refused rather than clamped.
        XCTAssertNil(LocalFactExtractor.minutesPerSession(in: "每次5分钟"))
    }

    // MARK: - Goal and experience

    func testGoalOnlyFromClearWording() {
        XCTAssertEqual(LocalFactExtractor.goal(in: "我想要减肥"), .fatLoss)
        XCTAssertEqual(LocalFactExtractor.goal(in: "主要想增肌"), .muscleGain)
        XCTAssertNil(LocalFactExtractor.goal(in: "随便练练"))
    }

    func testExperienceOnlyFromClearWording() {
        XCTAssertEqual(LocalFactExtractor.experience(in: "有点运动经验但不多"), .beginner)
        XCTAssertEqual(LocalFactExtractor.experience(in: "练了几年了"), .regular)
        XCTAssertNil(LocalFactExtractor.experience(in: "不知道算不算有经验"))
    }

    // MARK: - Pain is the one that must never be guessed

    func testExplicitDenialIsRecognised() {
        XCTAssertTrue(LocalFactExtractor.deniesPainNow(in: "目前没有疼痛或不适"))
        XCTAssertTrue(LocalFactExtractor.deniesPainNow(in: "不疼了，可以练"))
    }

    func testSilenceIsNotADenial() {
        XCTAssertFalse(LocalFactExtractor.deniesPainNow(in: "家里有哑铃和壶铃"))
        XCTAssertFalse(LocalFactExtractor.deniesPainNow(in: "我想减脂"))
    }

    func testPastPainIsNotTodaysAnswer() {
        // "I used to have pain" says nothing about right now.
        XCTAssertFalse(LocalFactExtractor.deniesPainNow(in: "之前膝盖疼过"))
        // Explicitly saying it is fine *now* does describe today, so that one counts.
        XCTAssertTrue(LocalFactExtractor.deniesPainNow(in: "上周腰疼，现在不疼了"))
    }

    func testMentioningPainIsNeverADenial() {
        XCTAssertFalse(LocalFactExtractor.deniesPainNow(in: "今天膝盖有点疼"))
        XCTAssertFalse(LocalFactExtractor.deniesPainNow(in: "有点不适"))
    }
}
