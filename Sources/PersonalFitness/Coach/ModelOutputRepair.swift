import Foundation
import CoreFoundation

/// Repairs the ways real models actually differ from the strict protocol, before validation runs.
///
/// Every transformation here is *representation only* — it never invents a value, never turns an
/// unknown into a fact, and never drops a field the rules depend on. Anything it cannot express is
/// left exactly as the model wrote it, so validation still fails loudly rather than silently passing
/// something the model did not say.
///
/// Why this exists: the decoders are deliberately strict — they must reject `mode`, `painFree`,
/// `medicalClearance` and other privilege-escalating fields. But a strict decoder that is also
/// *brittle* turns a formatting quirk into a dead end for the person using the app. Repairing shape
/// and enforcing meaning are two different jobs; this file only does the first.
enum ModelOutputRepair {

    /// Pulls the outermost JSON object out of whatever the model wrapped it in: prose before or
    /// after, markdown fences, or a JSON-encoded string that itself contains JSON.
    static func extractJSONObject(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{feff}")))
        trimmed = stripFence(trimmed)
        if trimmed.hasPrefix("\""), trimmed.hasSuffix("\""), trimmed.count >= 2,
           let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
           let inner = decoded as? String {
            trimmed = stripFence(inner.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
        return removingTrailingCommas(String(trimmed[start...end]))
    }

    private static func stripFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var body = text
        if let firstNewline = body.firstIndex(of: "\n") {
            body = String(body[body.index(after: firstNewline)...])
        }
        if body.hasSuffix("```") { body = String(body.dropLast(3)) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a comma that sits before `}` or `]`, including when whitespace or a newline sits
    /// between them. String literals are skipped, so a comma inside a value is never touched.
    static func removingTrailingCommas(_ text: String) -> String {
        let characters = Array(text)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        // Position in `output` of the most recent comma, cleared by any non-whitespace token. If it
        // is still set when a closing bracket arrives, that comma was trailing.
        var lastCommaIndex: Int?
        var inString = false
        var escaped = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inString = true
                lastCommaIndex = nil
                output.append(character)
            case ",":
                lastCommaIndex = output.count
                output.append(character)
            case "}", "]":
                // `lastCommaIndex` is cleared by every non-whitespace token, so a non-nil value here
                // means only whitespace followed the comma: it is trailing and must go.
                if let comma = lastCommaIndex { output.remove(at: comma) }
                lastCommaIndex = nil
                output.append(character)
            case " ", "\n", "\r", "\t":
                // Whitespace between a comma and a closing bracket does not cancel it.
                output.append(character)
            default:
                lastCommaIndex = nil
                output.append(character)
            }
            index += 1
        }
        return String(output)
    }

    /// An integer from the shapes models actually send: `25`, `"25"`, `"25分钟"`, `"25 min"`.
    /// Returns nil for booleans, decimals with a fractional part, and anything unparseable — a value
    /// that cannot be represented exactly is never rounded into one.
    static func integer(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = Int(trimmed) { return exact }
            // Take a leading signed number and ignore a trailing unit label.
            var digits = ""
            for character in trimmed {
                if character.isNumber || (digits.isEmpty && (character == "-" || character == "+")) {
                    digits.append(character)
                } else { break }
            }
            guard !digits.isEmpty, let result = Int(digits) else { return nil }
            // Refuse a decimal like "25.5" rather than truncating it.
            let remainder = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix(".") { return nil }
            return result
        }
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let double = number.doubleValue
            guard double.isFinite, double == double.rounded(), double >= Double(Int.min), double <= Double(Int.max) else { return nil }
            return Int(double)
        }
        return nil
    }

    /// Keys present in the object but not in the protocol. Reported back to the model; never a reason
    /// to accept the object.
    static func unknownKeys(in object: [String: Any], allowed: Set<String>) -> [String] {
        object.keys.filter { !allowed.contains($0) }.sorted()
    }

    static func missingKeys(in object: [String: Any], required: Set<String>) -> [String] {
        required.filter { object[$0] == nil }.sorted()
    }
}
