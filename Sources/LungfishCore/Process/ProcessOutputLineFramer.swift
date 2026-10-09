// ProcessOutputLineFramer.swift - Incremental subprocess line framing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Frames process bytes before decoding so split UTF-8 scalars survive pipe reads.
/// A carriage return delivers activity immediately; a following LF is consumed
/// as the second half of CRLF, including when it arrives in a later chunk.
///
/// A line longer than `maxLineBytes` is delivered in pieces of at most that
/// many bytes, cut before a UTF-8 lead byte where one lies within the last
/// three bytes, so output without line breaks never grows the pending buffer
/// without bound. Lines at or under the cap frame exactly as before.
public struct ProcessOutputLineFramer: Sendable {
    /// The default cap on one delivered line, 64 KB.
    public static let defaultMaxLineBytes = 64 * 1024

    private let maxLineBytes: Int
    private var pending = Data()
    private var previousWasCR = false

    public init(maxLineBytes: Int = ProcessOutputLineFramer.defaultMaxLineBytes) {
        self.maxLineBytes = max(4, maxLineBytes)
    }

    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let count = raw.count
            var start = 0
            if previousWasCR {
                previousWasCR = false
                if raw[0] == 10 {
                    start = 1
                }
            }
            // The next LF and CR at or after `start`, found with memchr and
            // searched again only once passed, so a chunk is scanned once.
            var nextLF = Self.find(10, in: base, from: start, count: count)
            var nextCR = Self.find(13, in: base, from: start, count: count)
            while start < count {
                if nextLF < start { nextLF = Self.find(10, in: base, from: start, count: count) }
                if nextCR < start { nextCR = Self.find(13, in: base, from: start, count: count) }
                let terminator = min(nextLF, nextCR)
                guard terminator < count else {
                    appendPending(base + start, count: count - start, into: &lines)
                    return
                }
                appendPending(base + start, count: terminator - start, into: &lines)
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
                start = terminator + 1
                if raw[terminator] == 13 {
                    if start < count {
                        if raw[start] == 10 {
                            start += 1
                        }
                    } else {
                        previousWasCR = true
                    }
                }
            }
        }
        return lines
    }

    public mutating func finish() -> [String] {
        defer {
            pending.removeAll(keepingCapacity: true)
            previousWasCR = false
        }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }

    private static func find(_ byte: Int32, in base: UnsafeRawPointer, from start: Int, count: Int) -> Int {
        guard start < count, let found = memchr(base + start, byte, count - start) else { return count }
        return base.distance(to: UnsafeRawPointer(found))
    }

    /// Adds bytes to the pending line, delivering capped pieces whenever the
    /// pending line would pass `maxLineBytes`.
    private mutating func appendPending(_ bytes: UnsafeRawPointer, count: Int, into lines: inout [String]) {
        var offset = 0
        while offset < count {
            let room = maxLineBytes + 1 - pending.count
            let take = min(room, count - offset)
            pending.append(bytes.assumingMemoryBound(to: UInt8.self) + offset, count: take)
            offset += take
            if pending.count > maxLineBytes {
                var cut = maxLineBytes
                // Back off a continuation byte so a scalar is not split.
                var backoff = 0
                while backoff < 3, pending[pending.startIndex + cut] & 0xC0 == 0x80 {
                    cut -= 1
                    backoff += 1
                }
                if pending[pending.startIndex + cut] & 0xC0 == 0x80 {
                    cut = maxLineBytes
                }
                lines.append(String(decoding: pending.prefix(cut), as: UTF8.self))
                pending = Data(pending.dropFirst(cut))
            }
        }
    }
}
