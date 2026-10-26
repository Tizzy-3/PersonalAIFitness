import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct BackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let content = configuration.file.regularFileContents,
              !content.isEmpty, content.count <= BackupCryptor.maximumFileBytes else {
            throw StorageError.backup("请选择不超过 32 MB 的有效备份文件。")
        }
        data = content
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard !data.isEmpty, data.count <= BackupCryptor.maximumFileBytes else {
            throw StorageError.backup("备份文件为空或超出大小限制。")
        }
        return FileWrapper(regularFileWithContents: data)
    }
}
