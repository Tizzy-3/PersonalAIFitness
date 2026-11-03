import SwiftUI
import Foundation

/// Renders the coach's reply as rich text instead of raw Markdown.
///
/// Models answer with `**bold**`, `- lists` and `` `code` `` whether or not they are asked to. Showing
/// those markers literally made every reply look broken, so the text is parsed once into an
/// `AttributedString` and rendered with the app's own typography.
///
/// Deliberately partial: bold, italic, inline code, and line structure. Headings are flattened to
/// bold text because a chat bubble is not a document, and images/links are left as plain text rather
/// than silently turned into tappable things the person did not ask for.
struct CoachMarkdownText: View {
    let text: String
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var color: Color = FitnessTheme.ink

    var body: some View {
        Text(attributed)
            .font(.system(size: size, weight: weight, design: .rounded))
            .foregroundStyle(color)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        guard let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible))
        else { return AttributedString(text) }
        return parsed
    }
}

/// Splits a Markdown reply into display blocks so lists and paragraphs keep their structure.
///
/// `AttributedString(markdown:)` with inline-only syntax keeps text on one run; a reply that is mostly
/// a bulleted list then reads as a wall. Splitting first lets each line keep its own layout while the
/// inline styling still applies per line.
enum CoachMarkdownBlocks {
    struct Block: Identifiable, Equatable {
        let id: Int
        let kind: Kind
        let text: String

        enum Kind: Equatable {
            case paragraph
            case bullet
            case numbered(String)
            case heading
        }
    }

    static func split(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var index = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            defer { index += 1 }
            if line.isEmpty { continue }
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                blocks.append(Block(id: index, kind: .heading,
                                    text: String(line[range.upperBound...])))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                blocks.append(Block(id: index, kind: .bullet, text: String(line.dropFirst(2))))
                continue
            }
            if let match = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                let marker = String(line[line.startIndex..<match.upperBound])
                    .trimmingCharacters(in: .whitespaces)
                blocks.append(Block(id: index, kind: .numbered(marker),
                                    text: String(line[match.upperBound...])))
                continue
            }
            blocks.append(Block(id: index, kind: .paragraph, text: line))
        }
        return blocks
    }
}

/// The full coach message: one styled line per Markdown block, with bullets and numbering preserved.
struct CoachMessageText: View {
    let text: String
    var size: CGFloat = 15
    var color: Color = FitnessTheme.ink

    var body: some View {
        let blocks = CoachMarkdownBlocks.split(text)
        if blocks.isEmpty {
            CoachMarkdownText(text: text, size: size, color: color)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .paragraph:
                        CoachMarkdownText(text: block.text, size: size, color: color)
                    case .heading:
                        CoachMarkdownText(text: block.text, size: size, weight: .semibold, color: color)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").font(.system(size: size, design: .rounded)).foregroundStyle(color)
                            CoachMarkdownText(text: block.text, size: size, color: color)
                        }
                    case .numbered(let marker):
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text(marker).font(.system(size: size, design: .rounded)).foregroundStyle(color)
                            CoachMarkdownText(text: block.text, size: size, color: color)
                        }
                    }
                }
            }
        }
    }
}
