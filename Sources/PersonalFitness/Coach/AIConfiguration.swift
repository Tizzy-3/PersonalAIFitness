import Foundation
import Security

struct AIConfiguration: Codable, Equatable, Sendable {
    var endpoint: String
    var model: String

    func validatedURL() throws -> URL {
        guard endpoint.count <= 2_048,
              let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port == nil || (1...65_535).contains(components.port!),
              components.path.hasSuffix("/chat/completions"),
              let url = components.url else {
            throw CoachClientError.configuration("请输入完整 HTTPS Chat Completions 地址，例如 https://你的服务/v1/chat/completions。地址不能带用户名、口令、查询参数或片段。")
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty, trimmedModel.count <= 200,
              !trimmedModel.contains(where: { $0.isNewline || $0 == "\t" }) else {
            throw CoachClientError.configuration("请填写服务提供的有效模型名称。")
        }
        return url
    }

    var normalized: AIConfiguration {
        AIConfiguration(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                        model: model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A key belongs to an HTTPS host and effective port, never to an arbitrary new endpoint.
    var credentialAccount: String {
        get throws {
            let url = try validatedURL()
            return "\(url.host!.lowercased()):\(url.port ?? 443)"
        }
    }

    var destination: String {
        (try? validatedURL().absoluteString) ?? "尚未配置有效接口"
    }
}

enum AIConfigurationStorage {
    private static let configurationKey = "personal-fitness.ai-configuration.v1"

    static func load(defaults: UserDefaults = .standard) throws -> AIConfiguration? {
        guard let data = defaults.data(forKey: configurationKey) else { return nil }
        guard let configuration = try? JSONDecoder().decode(AIConfiguration.self, from: data) else {
            throw CoachClientError.configuration("保存的接口配置无法读取，请重新填写。密钥不在此配置中。")
        }
        _ = try configuration.validatedURL()
        return configuration.normalized
    }

    static func save(_ configuration: AIConfiguration, defaults: UserDefaults = .standard) throws {
        _ = try configuration.validatedURL()
        defaults.set(try JSONEncoder().encode(configuration.normalized), forKey: configurationKey)
    }
}

enum AIKeychain {
    private static let service = "com.personalfitness.private.ai-api-key.v1"

    private static func query(for configuration: AIConfiguration) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: try configuration.credentialAccount,
         kSecAttrSynchronizable as String: false]
    }

    static func load(for configuration: AIConfiguration) throws -> String? {
        var query = try query(for: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw CoachClientError.configuration("无法读取本机密钥（Keychain 状态 \(status)）。请解锁设备，必要时重新填写密钥。")
        }
        return value
    }

    static func save(_ key: String, for configuration: AIConfiguration) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8_192,
              !key.contains(where: \.isWhitespace) else {
            throw CoachClientError.configuration("请填写有效 API Key，不能包含空格或换行。")
        }
        let query = try query(for: configuration)
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CoachClientError.configuration("密钥未保存（Keychain 状态 \(status)），请检查设备解锁及签名权限后重试。")
        }
    }

    static func remove(for configuration: AIConfiguration) throws {
        let status = SecItemDelete(try query(for: configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CoachClientError.configuration("密钥未移除（Keychain 状态 \(status)）。")
        }
    }
}
