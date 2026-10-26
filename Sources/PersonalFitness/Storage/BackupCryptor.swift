import Foundation
import CryptoKit
import CommonCrypto
import Security
import FitnessCore

/// Portable encrypted backups contain domain DTOs, never a live SwiftData database or credentials.
enum BackupCryptor {
    static let maximumFileBytes = 32 * 1_024 * 1_024
    private static let magic = "PAF-ENCRYPTED-BACKUP"
    private static let version = 1
    private static let rounds = 210_000
    private static let allowedRounds = 100_000...1_000_000

    private struct Envelope: Codable {
        var magic: String
        var version: Int
        var kdf: String
        var rounds: Int
        var salt: Data
        var sealed: Data
    }

    private struct AuthenticatedHeader: Codable {
        var magic: String
        var version: Int
        var kdf: String
        var rounds: Int
        var salt: Data
    }

    nonisolated static func encrypt(_ snapshot: AppSnapshot, passphrase: String) throws -> Data {
        guard passphrase.count >= 8, passphrase.utf8.count <= 1_024 else {
            throw StorageError.backup("备份口令至少 8 个字符，最多 1024 个 UTF-8 字节。口令丢失后无法恢复。")
        }
        let payload = try SnapshotCodec.encode(snapshot)
        guard payload.count <= maximumFileBytes / 2 else { throw StorageError.backup("核心记录过大，超过当前备份大小限制。") }
        let salt = try randomData(count: 16)
        let header = AuthenticatedHeader(magic: magic, version: version, kdf: "PBKDF2-SHA256", rounds: rounds, salt: salt)
        let authenticatedData = try encodeHeader(header)
        let key = try deriveKey(passphrase: passphrase, salt: salt, rounds: rounds)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: authenticatedData)
        guard let combined = sealed.combined else { throw StorageError.backup("无法完成备份加密。") }
        let envelope = Envelope(magic: magic, version: version, kdf: header.kdf, rounds: rounds, salt: salt, sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = try encoder.encode(envelope)
        guard output.count <= maximumFileBytes else { throw StorageError.backup("备份文件超出当前大小限制。") }
        return output
    }

    nonisolated static func decrypt(_ data: Data, passphrase: String) throws -> AppSnapshot {
        guard data.count <= maximumFileBytes, !data.isEmpty else { throw StorageError.backup("备份为空或超过 32 MB 限制。") }
        guard !passphrase.isEmpty, passphrase.utf8.count <= 1_024 else { throw StorageError.backup("请输入备份口令。") }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw StorageError.backup("不是受支持的加密备份，或文件已损坏。") }
        guard envelope.magic == magic, envelope.version == version, envelope.kdf == "PBKDF2-SHA256" else {
            throw StorageError.backup("不支持此备份格式或版本。请使用创建备份时相同或更新的 App。")
        }
        guard allowedRounds.contains(envelope.rounds), envelope.salt.count == 16,
              envelope.sealed.count >= 28, envelope.sealed.count <= maximumFileBytes / 2 + 28 else {
            throw StorageError.backup("备份参数无效，已拒绝读取。")
        }
        let header = AuthenticatedHeader(magic: envelope.magic, version: envelope.version, kdf: envelope.kdf, rounds: envelope.rounds, salt: envelope.salt)
        let authenticatedData = try encodeHeader(header)
        let key = try deriveKey(passphrase: passphrase, salt: envelope.salt, rounds: envelope.rounds)
        let payload: Data
        do {
            payload = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key, authenticating: authenticatedData)
        } catch {
            throw StorageError.backup("口令不正确，或备份已被修改/损坏。当前数据没有改变。")
        }
        do { return try SnapshotCodec.decode(payload) }
        catch { throw StorageError.backup("备份内容未通过完整性检查：\(error.localizedDescription)") }
    }

    nonisolated private static func encodeHeader(_ header: AuthenticatedHeader) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(header)
    }

    nonisolated private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw StorageError.backup("无法取得安全随机数，未创建备份。") }
        return Data(bytes)
    }

    nonisolated private static func deriveKey(passphrase: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let password = [UInt8](passphrase.utf8)
        var keyBytes = [UInt8](repeating: 0, count: 32)
        defer { _ = keyBytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        let status = keyBytes.withUnsafeMutableBytes { keyBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                        saltBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                        keyBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw StorageError.backup("备份口令派生失败。") }
        return SymmetricKey(data: keyBytes)
    }
}
