import CryptoKit
import Foundation

public struct DeterministicTarEntry: Sendable, Hashable {
    public let path: String
    public let data: Data
    public let mode: Int

    public init(path: String, data: Data, mode: Int = 0o644) {
        self.path = path
        self.data = data
        self.mode = mode
    }
}

public enum DeterministicTarError: Error, LocalizedError {
    case pathTooLong(String)
    case invalidArchive(String)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Tar entry path is too long for deterministic ustar writer: \(path)"
        case .invalidArchive(let reason):
            return "Invalid tar archive: \(reason)"
        }
    }
}

public struct DeterministicTarWriter {
    public init() {}

    public func archive(entries: [DeterministicTarEntry], to output: URL) throws {
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var archive = Data()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            archive.append(try header(for: entry))
            archive.append(entry.data)
            archive.append(Data(repeating: 0, count: padding(for: entry.data.count)))
        }
        archive.append(Data(repeating: 0, count: 1024))
        try archive.write(to: output, options: .atomic)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func header(for entry: DeterministicTarEntry) throws -> Data {
        guard let name = entry.path.data(using: .utf8), name.count <= 100 else {
            throw DeterministicTarError.pathTooLong(entry.path)
        }

        var block = Data(repeating: 0, count: 512)
        write(name, into: &block, at: 0, length: 100)
        write(octal: entry.mode, into: &block, at: 100, length: 8)
        write(octal: 0, into: &block, at: 108, length: 8)
        write(octal: 0, into: &block, at: 116, length: 8)
        write(octal: entry.data.count, into: &block, at: 124, length: 12)
        write(octal: 0, into: &block, at: 136, length: 12)
        for offset in 148..<156 {
            block[offset] = 0x20
        }
        block[156] = UInt8(ascii: "0")
        write(Data("ustar".utf8), into: &block, at: 257, length: 6)
        write(Data("00".utf8), into: &block, at: 263, length: 2)

        let checksum = block.reduce(0) { $0 + Int($1) }
        write(octal: checksum, into: &block, at: 148, length: 8)
        return block
    }

    private func write(_ data: Data, into block: inout Data, at offset: Int, length: Int) {
        let count = min(data.count, length)
        block.replaceSubrange(offset..<(offset + count), with: data.prefix(count))
    }

    private func write(octal value: Int, into block: inout Data, at offset: Int, length: Int) {
        let text = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - text.count - 1)) + text + "\0"
        write(Data(padded.utf8), into: &block, at: offset, length: length)
    }

    private func padding(for count: Int) -> Int {
        let remainder = count % 512
        return remainder == 0 ? 0 : 512 - remainder
    }
}

public struct DeterministicTarReader {
    public init() {}

    public static func entries(in archiveURL: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: archiveURL)
        var offset = 0
        var entries: [String: Data] = [:]

        while offset + 512 <= data.count {
            let header = Data(data[offset..<(offset + 512)])
            if header.allSatisfy({ $0 == 0 }) {
                break
            }
            guard let nameEnd = header[0..<100].firstIndex(of: 0) else {
                throw DeterministicTarError.invalidArchive("missing entry name terminator")
            }
            let nameData = header[0..<nameEnd]
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw DeterministicTarError.invalidArchive("entry name is not UTF-8")
            }
            let sizeField = header[124..<136].filter { $0 != 0 && $0 != 0x20 }
            guard let sizeText = String(data: Data(sizeField), encoding: .utf8),
                  let size = Int(sizeText, radix: 8) else {
                throw DeterministicTarError.invalidArchive("invalid size for \(name)")
            }
            offset += 512
            guard offset + size <= data.count else {
                throw DeterministicTarError.invalidArchive("truncated entry \(name)")
            }
            entries[name] = Data(data[offset..<(offset + size)])
            offset += size
            let remainder = size % 512
            if remainder != 0 {
                offset += 512 - remainder
            }
        }

        return entries
    }
}
