// GzipPrefixDecoder.swift - Bounded decoding of the start of a plain, gzip or BGZF file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Compression
import Foundation

/// Reads at most a fixed number of decoded bytes from the start of a file.
///
/// Plain files are read as they are. Gzip files are inflated member by member,
/// so a multi-member file (BGZF, or gzip files joined with `cat`) yields the
/// same bytes as its plain copy up to the limit. Decoding uses Apple
/// Compression and needs no external tool.
///
/// Apple Compression reports every input byte as consumed when a DEFLATE
/// stream ends, so member boundaries come from the BGZF block size when the
/// member carries one, and otherwise from the gzip trailer (the ISIZE field
/// followed by the next member's magic bytes).
public enum GzipPrefixDecoder {

    /// Whether the data starts with the gzip magic bytes.
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    /// Returns up to `maxBytes` decoded bytes from the start of the file at `url`,
    /// or nil when the file cannot be opened or is empty.
    public static func decodedPrefix(of url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2), !head.isEmpty else { return nil }
        if !isGzip(head) {
            var data = head
            if data.count < maxBytes, let rest = try? handle.read(upToCount: maxBytes - data.count) {
                data.append(rest)
            }
            return data
        }
        // Compressed input needed for maxBytes of output, with room for poorly
        // compressible data and block overhead.
        let compressedBudget = maxBytes * 2 + 1_048_576
        var compressed = head
        if let rest = try? handle.read(upToCount: compressedBudget - head.count) {
            compressed.append(rest)
        }
        return decodedPrefix(ofGzipData: compressed, maxBytes: maxBytes)
    }

    /// Returns up to `maxBytes` decoded bytes from gzip data held in memory.
    public static func decodedPrefix(ofGzipData data: Data, maxBytes: Int) -> Data? {
        let bytes = [UInt8](data)
        var output = Data()
        var position = 0
        while output.count < maxBytes, let member = memberHeader(in: bytes, at: position) {
            let bodyEnd: Int
            if let blockSize = member.bgzfBlockSize {
                bodyEnd = min(bytes.count, position + blockSize - 8)
            } else {
                bodyEnd = bytes.count
            }
            guard member.bodyStart <= bodyEnd else { break }
            let before = output.count
            let ended = inflate(bytes[member.bodyStart..<bodyEnd], into: &output, maxBytes: maxBytes)
            guard ended else { break }
            let produced = output.count - before
            if let blockSize = member.bgzfBlockSize {
                position += blockSize
            } else if let next = nextMemberStart(in: bytes, after: member.bodyStart, decodedSize: produced) {
                position = next
            } else {
                break
            }
        }
        return output.isEmpty ? nil : Data(output.prefix(maxBytes))
    }

    // MARK: - Members

    private struct MemberHeader {
        let bodyStart: Int
        let bgzfBlockSize: Int?
    }

    private static func memberHeader(in bytes: [UInt8], at start: Int) -> MemberHeader? {
        guard start + 10 <= bytes.count,
              bytes[start] == 0x1F, bytes[start + 1] == 0x8B, bytes[start + 2] == 8 else { return nil }
        let flags = bytes[start + 3]
        var offset = start + 10
        var blockSize: Int?
        if flags & 0x04 != 0 {
            guard offset + 2 <= bytes.count else { return nil }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            let extraStart = offset + 2
            let extraEnd = extraStart + extraLength
            guard extraEnd <= bytes.count else { return nil }
            var field = extraStart
            while field + 4 <= extraEnd {
                let fieldLength = Int(bytes[field + 2]) | (Int(bytes[field + 3]) << 8)
                if bytes[field] == 66, bytes[field + 1] == 67, fieldLength == 2, field + 6 <= extraEnd {
                    blockSize = (Int(bytes[field + 4]) | (Int(bytes[field + 5]) << 8)) + 1
                }
                field += 4 + fieldLength
            }
            offset = extraEnd
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset <= bytes.count else { return nil }
        return MemberHeader(bodyStart: offset, bgzfBlockSize: blockSize)
    }

    /// The start of the next member: the first place after `start` where the
    /// gzip trailer's ISIZE equals the decoded size and the next magic follows.
    private static func nextMemberStart(in bytes: [UInt8], after start: Int, decodedSize: Int) -> Int? {
        let size = UInt32(truncatingIfNeeded: decodedSize)
        var index = start
        while index + 11 <= bytes.count {
            let isize = UInt32(bytes[index + 4]) | UInt32(bytes[index + 5]) << 8
                | UInt32(bytes[index + 6]) << 16 | UInt32(bytes[index + 7]) << 24
            if isize == size, bytes[index + 8] == 0x1F, bytes[index + 9] == 0x8B, bytes[index + 10] == 8 {
                return index + 8
            }
            index += 1
        }
        return nil
    }

    /// Inflates one raw DEFLATE body. Returns true when the stream ended cleanly.
    private static func inflate(_ body: ArraySlice<UInt8>, into output: inout Data, maxBytes: Int) -> Bool {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return false
        }
        defer { compression_stream_destroy(stream) }

        let bufferSize = 65_536
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        return body.withUnsafeBufferPointer { source -> Bool in
            guard let base = source.baseAddress else { return false }
            stream.pointee.src_ptr = base
            stream.pointee.src_size = source.count
            while true {
                stream.pointee.dst_ptr = destination
                stream.pointee.dst_size = bufferSize
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                switch status {
                case COMPRESSION_STATUS_END:
                    return true
                case COMPRESSION_STATUS_OK:
                    if output.count >= maxBytes { return false }
                    if produced == 0 { return false }
                default:
                    return false
                }
            }
        }
    }
}
