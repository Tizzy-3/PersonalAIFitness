import Foundation

/// A rejected model reply, carrying a machine-readable reason so the correction turn can name the
/// actual defect instead of repeating "that was wrong".
///
/// `detail` is what the person sees; `reason` is what the model is told. Neither contains the raw
/// reply, a user value, or a key — only the shape of the problem.
///
/// A preview of the reply is kept separately in `diagnostic` and is **never** put in
/// `errorDescription`. The reply can contain the person's own health narrative, and a rejected
/// model output must not be surfaced in an alert, a log line, a stored record or a support paste.
struct ModelOutputRejection: Error, LocalizedError, Equatable, Sendable {
    let reason: String
    let detail: String
    /// Sanitised, truncated preview for local diagnostics only. Never shown to the person and never
    /// included in `errorDescription`.
    var preview: String? = nil

    var errorDescription: String? { detail }

    /// Short machine-readable line for the in-app format diagnostic screen, which the person
    /// chooses to open. Still truncated and newline-collapsed.
    var diagnostic: String {
        var lines = ["model-output", "reason=\(reason)"]
        if let preview, !preview.isEmpty { lines.append("preview=\(preview)") }
        lines.append("原始回复未保存；本诊断不含完整回答或密钥。")
        return lines.joined(separator: "\n")
    }
}

extension ModelOutputRejection {
    /// Builds a rejection for "the reply was not a JSON object". The preview is captured for the
    /// diagnostic only; the person sees `detail` alone.
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
