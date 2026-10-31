import XCTest
import Foundation
import FitnessCore
@testable import PersonalFitness

/// The model-output layer has two separate jobs, and both are tested here: repairing the *shape*
/// real models produce, and still refusing anything that would change meaning.
final class ModelOutputToleranceTests: XCTestCase {

    // MARK: - Shape repair

    func testExtractsObjectFromProseFenceAndQuotedString() {
        let plain = #"{"a":1}"#
        XCTAssertEqual(ModelOutputRepair.extractJSONObject(plain), plain)

        // Prose before and after, plus a markdown fence.
        let fenced = "好的，结果如下：\n```json\n{\"a\":1}\n```\n以上。"
        XCTAssertEqual(ModelOutputRepair.extractJSONObject(fenced), plain)

        // A model that returns the object as a JSON *string* containing JSON. The literal below is
        // the text `"{\"a\":1}"`, quotes included.
        let quoted = #""{\"a\":1}""#
        XCTAssertEqual(ModelOutputRepair.extractJSONObject(quoted), plain)

        XCTAssertNil(ModelOutputRepair.extractJSONObject("抱歉，我无法整理。"))
    }

    func testTrailingCommasAreRemovedOnlyOutsideStrings() {
        let input = #"{"a":1,"b":[1,2,],"c":"逗号,保留",}"#
        let output = ModelOutputRepair.removingTrailingCommas(input)
        XCTAssertEqual(output, #"{"a":1,"b":[1,2],"c":"逗号,保留"}"#)
        // The comma inside the string value survives untouched.
        XCTAssertTrue(output.contains("逗号,保留"))

        // Pretty-printed replies put the comma on its own line; whitespace after a comma must not
        // hide the fact that it is trailing.
        let multiline = "{\n  \"a\": 1,\n  \"b\": 2,\n}"
        XCTAssertEqual(ModelOutputRepair.removingTrailingCommas(multiline),
                       "{\n  \"a\": 1,\n  \"b\": 2\n}")

        XCTAssertEqual(ModelOutputRepair.removingTrailingCommas(#"{"a":[1,2, ]}"#), #"{"a":[1,2 ]}"#)
        // A comma followed by a real value is never removed.
        XCTAssertEqual(ModelOutputRepair.removingTrailingCommas(#"{"a":1,"b":2}"#), #"{"a":1,"b":2}"#)
    }

    func testIntegerCoercionAcceptsUnitsButNeverGuessesDecimals() {
        XCTAssertEqual(ModelOutputRepair.integer(25), 25)
        XCTAssertEqual(ModelOutputRepair.integer("25"), 25)
        XCTAssertEqual(ModelOutputRepair.integer("25分钟"), 25)
        XCTAssertEqual(ModelOutputRepair.integer(" 25 min"), 25)
        // A fractional value must not be rounded, and a boolean must not become 1 or 0.
        XCTAssertNil(ModelOutputRepair.integer("25.5"))
        XCTAssertNil(ModelOutputRepair.integer(25.5))
        XCTAssertNil(ModelOutputRepair.integer(true))
        XCTAssertNil(ModelOutputRepair.integer(NSNumber(value: true)))
        XCTAssertNil(ModelOutputRepair.integer("二十五"))
        XCTAssertNil(ModelOutputRepair.integer(nil))
    }

    func testKeyDiffReportsBothDirections() {
        let object: [String: Any] = ["answer": "x", "mode": "practicalOnly", "painFree": true]
        XCTAssertEqual(ModelOutputRepair.unknownKeys(in: object, allowed: ["answer", "evidence"]),
                       ["mode", "painFree"])
        XCTAssertEqual(ModelOutputRepair.missingKeys(in: object, required: ["answer", "evidence"]),
                       ["evidence"])
    }

    // MARK: - Correction message names the defect

    func testCorrectionMessageCarriesTheReasonAndFullKeyList() {
        let text = ModelOutputRejection.correction(
            reason: "包含不允许多余字段：mode",
            allowedKeys: ["a", "b"],
            extraRules: "不要输出计划。")
        XCTAssertTrue(text.contains("包含不允许多余字段：mode"))
        XCTAssertTrue(text.contains("a, b"))
        XCTAssertTrue(text.contains("不要输出计划。"))
        XCTAssertTrue(text.contains("JSON"))
    }

    // MARK: - Meaning is still enforced

    private let valid = #"{"excludedExerciseIDs":["builtin.bird-dog"],"avoidedPositions":["kneeling"],"excludedWeekdays":[5],"restDateKeys":["2028-02-29"],"maxSessionMinutes":25,"allowedExerciseIDs":null,"questions":["这个日期只休息一次吗？"],"unresolved":["还没有说明活动的具体要求"]}"#

    func testFormattedVariantsThatPreserveMeaningAreAccepted() throws {
        // Fence, prose, trailing comma, a minute count written with a unit, and a weekday sent as a
        // string. Every one of these is the same candidate; only the representation differs.
        var body = valid
        body = body.replacingOccurrences(of: #""maxSessionMinutes":25"#,
                                         with: #""maxSessionMinutes":"25分钟""#)
        body = body.replacingOccurrences(of: #""excludedWeekdays":[5],"#,
                                         with: #""excludedWeekdays":["5"],"#)
        body.removeLast()                     // drop the closing brace
        body += "," + "}"                     // re-add it after a trailing comma
        let wrapped = "整理如下：\n```json\n" + body + "\n```\n请确认。"
        let candidate = try SimpleConstraintChatAPI.decode(wrapped)
        XCTAssertEqual(candidate.maxSessionMinutes, 25)
        XCTAssertEqual(candidate.excludedWeekdays, [5])
        XCTAssertEqual(candidate.avoidedPositions, [.kneeling])
        XCTAssertEqual(candidate.restDateKeys, ["2028-02-29"])
    }

    func testMeaningChangingFieldsAreStillRejectedAndNamed() {
        // A privilege field must not sneak in through the tolerant path.
        let withMode = String(valid.dropLast()) + #", "mode":"practicalOnly"}"#
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(withMode)) { error in
            let rejection = error as? ModelOutputRejection
            XCTAssertEqual(rejection?.reason.contains("mode"), true)
            XCTAssertFalse(error.localizedDescription.contains("practicalOnly"),
                           "拒绝原因不回显模型给出的原始值")
        }
        // A missing mandatory field is named, not merely called invalid.
        let missing = valid.replacingOccurrences(of: #""allowedExerciseIDs":null,"#, with: "")
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(missing)) { error in
            XCTAssertEqual((error as? ModelOutputRejection)?.reason.contains("allowedExerciseIDs"), true)
        }
    }

    func testOutOfRangeValuesStillFailAfterCoercion() {
        // "5" parses as an integer, but 5 minutes is below the 15-minute floor.
        let tooShort = valid.replacingOccurrences(of: #""maxSessionMinutes":25"#,
                                                  with: #""maxSessionMinutes":"5""#)
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(tooShort))
        // "25.5" is not truncated into a valid 25.
        let fractional = valid.replacingOccurrences(of: #""maxSessionMinutes":25"#,
                                                    with: #""maxSessionMinutes":"25.5""#)
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(fractional))
    }

    func testNonJSONFailureKeepsTheReplyOutOfTheVisibleMessage() {
        // A refusal, a truncated stream and a wrong-endpoint HTML page all used to look identical.
        // The preview is kept for the diagnostic screen, but the reply can contain the person's own
        // health narrative, so it must never reach an alert, a log line or a stored record.
        let refusal = "抱歉，我需要更多信息才能整理。请告诉我具体的医生建议。"
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode(refusal)) { error in
            let rejection = error as? ModelOutputRejection
            XCTAssertEqual(rejection?.reason, "返回内容不是 JSON 对象")
            XCTAssertFalse(error.localizedDescription.contains("抱歉"),
                           "原始回复不能出现在用户可见错误里")
            // The diagnostic the person chooses to open does carry it, truncated.
            XCTAssertTrue(rejection?.diagnostic.contains("preview=") ?? false)
            XCTAssertTrue(rejection?.diagnostic.contains("抱歉") ?? false)
        }
    }

    func testPreviewIsTruncatedAndDoesNotEchoTheWholeReply() {
        let long = String(repeating: "很长的说明文字", count: 200)
        let preview = ModelOutputRejection.sanitizedPreview(long)
        XCTAssertLessThanOrEqual(preview.count, 120)
        XCTAssertLessThan(preview.count, long.count)
        // Newlines are collapsed so the alert stays readable.
        XCTAssertFalse(preview.contains("\n"))
    }

    func testEmptyReplyHasItsOwnPreview() {
        XCTAssertEqual(ModelOutputRejection.sanitizedPreview("   \n  "), "（空回复）")
    }

    // MARK: - Conversation turn is separate from extraction

    func testConversationTurnDecodesAndKeepsTheReplyVerbatim() throws {
        let content = #"{"reply":"好，那周四我给你安排 15 分钟快走，可以吗？","topic":"周四安排"}"#
        let turn = try SimpleConstraintChatAPI.decodeConversation(content)
        XCTAssertEqual(turn.reply, "好，那周四我给你安排 15 分钟快走，可以吗？")
        XCTAssertEqual(turn.topic, "周四安排")
    }

    func testConversationTurnAcceptsProseInAFence() throws {
        let content = "好的：" + "\n```json\n" + #"{"reply":"你先说说哪里不舒服？"}"# + "\n```"
        let turn = try SimpleConstraintChatAPI.decodeConversation(content)
        XCTAssertEqual(turn.reply, "你先说说哪里不舒服？")
        XCTAssertEqual(turn.topic, "")
    }

    func testConversationTurnRejectsAPlanOrExtraFields() {
        let withPlan = #"{"reply":"好","plan":{"sets":3}}"#
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decodeConversation(withPlan)) { error in
            XCTAssertEqual((error as? ModelOutputRejection)?.reason.contains("plan"), true)
        }
    }

    func testConversationTurnRequiresANonEmptyReply() {
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decodeConversation(#"{"reply":"   ","topic":""}"#))
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decodeConversation(#"{"topic":"x"}"#))
    }

    func testNonJSONStillFails() {
        XCTAssertThrowsError(try SimpleConstraintChatAPI.decode("抱歉，我无法整理这些内容。"))
    }
}
