import XCTest
import FitnessCore
@testable import PersonalFitness

final class BackupCryptorTests: XCTestCase {
    func testEncryptedBackupRoundTripAndRandomSalt() throws {
        var profile = PersonalProfile()
        profile.heightCM = 176
        profile.restrictions = "仅用于隔离测试的限制备注"
        let source = AppSnapshot(profile: profile)
        let first = try BackupCryptor.encrypt(source, passphrase: "仅供测试的备份口令123")
        let second = try BackupCryptor.encrypt(source, passphrase: "仅供测试的备份口令123")
        XCTAssertNotEqual(first, second)
        let decoded = try BackupCryptor.decrypt(first, passphrase: "仅供测试的备份口令123")
        XCTAssertEqual(decoded.profile, source.profile)
        XCTAssertEqual(decoded.planVersions, source.planVersions)
        XCTAssertEqual(decoded.sessions, source.sessions)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains(profile.restrictions))
    }

    func testWrongPasswordAndCiphertextTamperingAreRejected() throws {
        let data = try BackupCryptor.encrypt(AppSnapshot(), passphrase: "correct-password")
        XCTAssertThrowsError(try BackupCryptor.decrypt(data, passphrase: "wrong-password"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(object["sealed"] as? String)))
        sealed[sealed.count - 1] ^= 1
        object["sealed"] = sealed.base64EncodedString()
        let damaged = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try BackupCryptor.decrypt(damaged, passphrase: "correct-password"))
    }

    func testHeaderAndKDFLimitsAreCheckedBeforeExpensiveWork() throws {
        let data = try BackupCryptor.encrypt(AppSnapshot(), passphrase: "correct-password")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["rounds"] = Int.max
        XCTAssertThrowsError(try BackupCryptor.decrypt(JSONSerialization.data(withJSONObject: object), passphrase: "correct-password"))
        object["rounds"] = 210_000
        object["version"] = 99
        XCTAssertThrowsError(try BackupCryptor.decrypt(JSONSerialization.data(withJSONObject: object), passphrase: "correct-password"))
        XCTAssertThrowsError(try BackupCryptor.decrypt(Data(), passphrase: "correct-password"))
        XCTAssertThrowsError(try BackupCryptor.encrypt(AppSnapshot(), passphrase: "short"))
    }
}
