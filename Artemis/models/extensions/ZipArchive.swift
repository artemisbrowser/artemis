import Compression
import Foundation

/// unpacks a .zip where there is no `ditto` to call (iOS): stored and deflated entries, found
/// through the central directory, which holds the true sizes even when the local headers defer
/// them to a data descriptor. no zip64
nonisolated enum ZipArchive {
    private enum Failure: Error {
        case malformed
        case unsupported(method: UInt16)
    }

    static func extract(_ zip: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard data.count >= 22,
            let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
                .first(where: { data.uint32(at: $0) == 0x0605_4b50 })
        else { throw Failure.malformed }
        let fm = FileManager.default
        var offset = Int(data.uint32(at: end + 16))
        for _ in 0..<Int(data.uint16(at: end + 10)) {
            guard offset + 46 <= data.count, data.uint32(at: offset) == 0x0201_4b50 else { throw Failure.malformed }
            let method = data.uint16(at: offset + 10)
            let compressed = Int(data.uint32(at: offset + 20)), size = Int(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let local = Int(data.uint32(at: offset + 42))
            let name = String(decoding: data[offset + 46..<offset + 46 + nameLength], as: UTF8.self)
            offset += 46 + nameLength + Int(data.uint16(at: offset + 30)) + Int(data.uint16(at: offset + 32))
            // an entry may only land inside `destination`
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw Failure.malformed }
            let target = destination.appending(path: name)
            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let start = local + 30 + Int(data.uint16(at: local + 26)) + Int(data.uint16(at: local + 28))
            guard start + compressed <= data.count else { throw Failure.malformed }
            let body = data[start..<start + compressed]
            let bytes: Data
            switch method {
            case 0: bytes = Data(body)
            case 8: bytes = try inflate(body, size: size)
            default: throw Failure.unsupported(method: method)
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target)
        }
    }

    /// raw DEFLATE, which is what Compression calls ZLIB
    private static func inflate(_ body: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, body.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.malformed }
        return out
    }
}

nonisolated private extension Data {
    func uint16(at index: Int) -> UInt16 {
        UInt16(self[startIndex + index]) | UInt16(self[startIndex + index + 1]) << 8
    }

    func uint32(at index: Int) -> UInt32 {
        UInt32(uint16(at: index)) | UInt32(uint16(at: index + 2)) << 16
    }
}
