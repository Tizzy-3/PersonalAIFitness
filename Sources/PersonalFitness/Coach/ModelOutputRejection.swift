import Foundation

/// A rejected model reply, carrying a machine-readable reason so the correction turn can name the
/// actual defect instead of repeating "that was wrong".
///
/// `detail` is what the person sees; `reason` is what the model is told. Neither contains the raw
/// reply, a user value, or a key — only the shape of the problem.
struct ModelOutputRejection: Error, LocalizedError, Equatable, Sendable {
    let reason: String
    let detail: String
    /// A short, sanitised preview of what the model actually sent, when the failure was "not JSON".
    /// Without it, "the reply was not JSON" is unactionable: a refusal, a truncated stream and a
    /// wrong-endpoint HTML page all look identical. Trimmed to 120 characters and stripped of
    /// newlines; never the whole reply.
    var preview: String? = nil

    var errorDescription: String? {
        guard let preview, !preview.isEmpty else { return detail }
        return "\(detail)\n\n模型实际返回的开头是：「\(preview)」"
    }
}

extension ModelOutputRejection {
    /// Builds a rejection for "the reply was not a JSON object", keeping a short preview so the
    /// person and the log can tell a refusal from a truncation from a wrong endpoint.
    static func notJSON(_ content: String, detail: String) -> ModelOutputRejection {
        ModelOutputRejection(reason: "返回内容不是 JSON 对象", detail: detail,
                             preview: sanitizedPreview(content))
    }

    /// First 120 printable characters, newlines collapsed. Deliberately not the full reply.
    static func sanitizedPreview(_ content: String) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "（空回复）" }
        return String(collapsed.prefix(120))
    }

    /// The correction turn for a rejected reply. Naming the specific defect matters: a model told
    /// "invalid" reproduces it, while a model told "these keys are not allowed: mode" does not.
    static func correction(reason: String, allowedKeys: [String], extraRules: String = "") -> String {
        var parts = [
            "上一次输出未通过本地校验：\(reason)",
            "请只输出一个 JSON 对象，不要 Markdown、代码围栏或对象外文字。",
            "顶层字段必须恰好是以下 \(allowedKeys.count) 项，多一个或少一个都会被拒绝：",
            allowedKeys.joined(separator: ", ")
        ]
        if !extraRules.isEmpty { parts.append(extraRules) }
        return parts.joined(separator: "\n")
    }
}
