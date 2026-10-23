import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// SHA-256 over bytes or a file, through CryptoKit on macOS and swift-crypto's `Crypto` on Linux.
///
/// The two modules expose the same `SHA256` API, so one body serves both. On Linux the digest runs on BoringSSL,
/// which picks the SHA instructions at run time, so the static binary needs no `-march` flag.
public enum PortableDigest {
    /// Bytes read per chunk when hashing a file.
    public static let fileChunkSize = 1 << 20

    /// The lowercase hexadecimal SHA-256 of `data`.
    public static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// The lowercase hexadecimal SHA-256 of the file at `url`, read in chunks so a large file never sits in memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try sha256Hex(reading: handle)
    }

    /// The lowercase hexadecimal SHA-256 of what `handle` reads from its offset to its end, in chunks. The caller keeps
    /// the handle, so a file checked with `fstat` is hashed through the same descriptor.
    package static func sha256Hex(reading handle: FileHandle) throws -> String {
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: fileChunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in bytes {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
