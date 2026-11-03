import XCTest
import Foundation
@testable import PersonalFitness

/// The coach answers in Markdown regardless of what it is asked for, so the bubble has to render it.
/// These tests pin the parsing, including the cases where Markdown must NOT be treated as structure.
final class CoachMarkdownTests: XCTestCase {

    // MARK: - Inline styling is parsed, markers are not shown

    func testBoldMarkersBecomeBoldText() {
        let attributed = try? AttributedString(
            markdown: "今天**先别加重量**，找找感觉。",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let plain = String(attributed?.characters.map(Character.init) ?? [])
        XCTAssertFalse(plain.contains("**"), "星号不能显示出来")
        XCTAssertTrue(plain.contains("先别加重量"))
    }

    // MARK: - Block structure

    func testBulletedListKeepsItsStructure() {
        let blocks = CoachMarkdownBlocks.split("""
        我建议这样安排：
        - 周一 卧推 3 组
        - 周三 划船 3 组
        """)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .bullet, .bullet])
        XCTAssertEqual(blocks[1].text, "周一 卧推 3 组")
    }

    func testNumberedListKeepsItsMarker() {
        let blocks = CoachMarkdownBlocks.split("""
        1. 先做卧推
        2. 再做划船
        """)
        XCTAssertEqual(blocks.count, 2)
        if case .numbered(let marker) = blocks[0].kind {
            XCTAssertEqual(marker, "1.")
        } else {
            XCTFail("编号列表应当被识别")
        }
        XCTAssertEqual(blocks[1].text, "再做划船")
    }

    func testHeadingsAreFlattenedNotShownWithHashes() {
        let blocks = CoachMarkdownBlocks.split("### 今天的安排\n先热身。")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .heading)
        XCTAssertEqual(blocks[0].text, "今天的安排", "井号不能留在正文里")
    }

    // MARK: - Things that must not be mangled

    func testPlainProseStaysOneParagraph() {
        let blocks = CoachMarkdownBlocks.split("昨天练得不错，今天继续。")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testBlankLinesDoNotProduceEmptyBlocks() {
        let blocks = CoachMarkdownBlocks.split("第一段\n\n\n第二段")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertTrue(blocks.allSatisfy { !$0.text.isEmpty })
    }

    func testAMinusSignInsideASentenceIsNotABullet() {
        // Only a leading "- " starts a bullet; "5-3" or "重量-次数" must stay as text.
        let blocks = CoachMarkdownBlocks.split("这次是 5-3 组，重量-次数都要记。")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .paragraph)
    }

    func testEmptyReplyProducesNoBlocks() {
        XCTAssertTrue(CoachMarkdownBlocks.split("").isEmpty)
        XCTAssertTrue(CoachMarkdownBlocks.split("   \n  \n").isEmpty)
    }

    // MARK: - Malformed Markdown degrades gracefully

    func testUnbalancedMarkersStillRenderText() {
        // A stray ** must not swallow the rest of the message or crash the parser.
        let blocks = CoachMarkdownBlocks.split("这里有**没有闭合的加粗")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].text.contains("没有闭合的加粗"))
    }
}
