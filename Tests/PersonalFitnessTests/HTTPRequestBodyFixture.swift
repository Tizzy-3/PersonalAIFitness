import Foundation

/// URLSession may expose a POST body to URLProtocol as a stream rather than inline Data.
/// Read either representation in protocol fixtures; never change the production request to suit a test.
enum HTTPRequestBodyFixture {
    static func read(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw URLError(.requestBodyStreamExhausted) }
        stream.open()
        defer { stream.close() }
        let capacity = 4_096
        var buffer = [UInt8](repeating: 0, count: capacity)
        var result = Data()
        while true {
            let count = stream.read(&buffer, maxLength: capacity)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return result }
            guard result.count + count <= 512 * 1_024 else { throw URLError(.dataLengthExceedsMaximum) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
