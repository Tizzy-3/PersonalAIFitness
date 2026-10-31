import Foundation

/// A rejected model reply, carrying a machine-readable reason so the correction turn can name the
/// actual defect instead of repeating "that was wrong".
///
/// `detail` is what the person sees; `reason` is what the model is told. Neither contains the raw
/// reply, a user value, or a key — only the shape of the problem.
struct ModelOutputRejection: Error, LocalizedError, Equatable, Sendable {
    let reason: String
    let detail: String

    var errorDescription: String? { detail }
}

extension ModelOutputRejection {
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
