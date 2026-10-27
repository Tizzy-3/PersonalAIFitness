import Foundation
import CoreFoundation
import FitnessCore

/// Only field paths, expected shapes and fixed categories; never a raw model reply or user value.
struct InterviewProtocolError: Error, LocalizedError, Equatable, Sendable {
    let path: String
    let expected: String
    let category: String
    var finishReason: String? = nil
    var diagnostic: String {
        "interview-json-v2\npath=\(path)\nexpected=\(expected)\ncategory=\(category)\nfinish_reason=\(finishReason ?? "unavailable")\n原始回复未保存；本诊断不含回答正文或密钥。"
    }
    var errorDescription: String? { "访谈格式未通过校验：\(path) 需要\(expected)。可查看格式诊断并重新询问。" }
}

enum InterviewProtocol {
    static func decode(_ content: String, provider: InterviewProvider?) throws -> InterviewTurn {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\u{feff}")))
        var text = CoachAPI.unfencedJSON(trimmed)
        var object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            if let encoded = object as? String {
                text = CoachAPI.unfencedJSON(encoded)
                object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            }
        } catch { throw failure("$", "一个完整JSON对象", "invalid_json") }
        guard let root = object as? [String: Any] else { throw failure("$", "JSON对象", "wrong_type") }
        try keys(root, allowed: ["questions", "extractions", "note"], at: "$")
        guard root.keys.contains("questions") else { throw failure("$.questions", "问题数组", "missing_field") }
        let rows = try array(root["questions"], at: "$.questions")
        guard rows.count <= InterviewRules.maximumQuestionsPerTurn else { throw failure("$.questions", "最多3个问题", "too_many_items") }
        var questions: [InterviewQuestion] = []
        for (index, value) in rows.enumerated() {
            let path = "$.questions[\(index)]"
            guard let row = value as? [String: Any] else { throw failure(path, "问题对象", "wrong_type") }
            try keys(row, allowed: ["topic", "kind", "prompt", "options", "unit", "minimum", "maximum", "detailKey"], at: path)
            let topicText = try string(row["topic"], at: path + ".topic")
            guard let topic = InterviewTopic(rawValue: topicText) else { throw failure(path + ".topic", "支持的访谈主题", "unknown_topic") }
            let kindText = try string(row["kind"], at: path + ".kind")
            let aliases = ["single_choice": "singleChoice", "multi_choice": "multiChoice"]
            guard let kind = InterviewQuestionKind(rawValue: aliases[kindText] ?? kindText) else { throw failure(path + ".kind", "支持的问题类型", "unknown_kind") }
            var optionsRaw = row["options"]
            if let encoded = optionsRaw as? String, let data = encoded.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data), decoded is [Any] { optionsRaw = decoded }
            let options = try array(optionsRaw, at: path + ".options").enumerated().map { i, value in
                try string(value, at: path + ".options[\(i)]")
            }
            let question = InterviewQuestion(topic: topic, kind: kind,
                prompt: try string(row["prompt"], at: path + ".prompt"), options: options,
                unit: try optionalString(row["unit"], at: path + ".unit"),
                minimum: try number(row["minimum"], at: path + ".minimum"),
                maximum: try number(row["maximum"], at: path + ".maximum"),
                detailKey: try optionalString(row["detailKey"], at: path + ".detailKey"))
            do { try question.validate() }
            catch { throw failure(path, "主题一致、题型完整且边界合法的问题", "invalid_question") }
            questions.append(question)
        }
        let extractionRows = try array(root["extractions"], at: "$.extractions")
        guard extractionRows.count <= InterviewTopic.allCases.count else { throw failure("$.extractions", "有界的档案抽取数组", "too_many_items") }
        var extractions: [InterviewExtraction] = []
        for (index, value) in extractionRows.enumerated() {
            let path = "$.extractions[\(index)]"
            guard let row = value as? [String: Any] else { throw failure(path, "抽取对象", "wrong_type") }
            try keys(row, allowed: ["topic", "rawValue", "rationale"], at: path)
            guard let topic = InterviewTopic(rawValue: try string(row["topic"], at: path + ".topic")) else {
                throw failure(path + ".topic", "支持的访谈主题", "unknown_topic")
            }
            let rawValue: String
            if let text = row["rawValue"] as? String { rawValue = text }
            else if let value = try number(row["rawValue"], at: path + ".rawValue") { rawValue = value == value.rounded() ? String(format: "%.0f", value) : String(value) }
            else { throw failure(path + ".rawValue", "该主题合法的文本编码", "missing_field") }
            let extraction = InterviewExtraction(topic: topic, rawValue: rawValue,
                rationale: try optionalString(row["rationale"], at: path + ".rationale") ?? "")
            do { try extraction.validate() }
            catch { throw failure(path + ".rawValue", "该主题合法的值（动作必须来自真实库）", "invalid_extraction") }
            extractions.append(extraction)
        }
        let turn = InterviewTurn(questions: questions, extractions: extractions,
            note: try optionalString(root["note"], at: "$.note") ?? "", provider: provider)
        do { try turn.validate() }
        catch { throw failure("$", "无重复ID或主题抽取、长度有界的访谈轮次", "invalid_turn") }
        return turn
    }
    private static func failure(_ path: String, _ expected: String, _ category: String) -> InterviewProtocolError {
        .init(path: path, expected: expected, category: category)
    }
    private static func keys(_ object: [String: Any], allowed: Set<String>, at path: String) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw failure(path, "约定字段；不允许额外计划或工具字段", "unknown_field") }
    }
    private static func array(_ value: Any?, at path: String) throws -> [Any] {
        if value == nil || value is NSNull { return [] }
        guard let array = value as? [Any] else { throw failure(path, "数组或null", "wrong_type") }
        return array
    }
    private static func string(_ value: Any?, at path: String) throws -> String {
        guard let text = value as? String else { throw failure(path, "文本", "wrong_type") }
        return text
    }
    private static func optionalString(_ value: Any?, at path: String) throws -> String? {
        if value == nil || value is NSNull { return nil }
        let result = try string(value, at: path).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
    private static func number(_ value: Any?, at path: String) throws -> Double? {
        if value == nil || value is NSNull { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            guard let result = Double(trimmed), result.isFinite else { throw failure(path, "有限数字或数字字符串", "wrong_type") }
            return result
        }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw failure(path, "有限数字或数字字符串，不能是布尔值", "wrong_type")
        }
        return value.doubleValue
    }
}
