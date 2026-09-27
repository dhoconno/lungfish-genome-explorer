// ProcessOutputLineFramer.swift - Incremental subprocess line framing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Frames process bytes before decoding so split UTF-8 scalars survive pipe reads.
/// A carriage return delivers activity immediately; a following LF is consumed
/// as the second half of CRLF, including when it arrives in a later chunk.
public struct ProcessOutputLineFramer: Sendable {
    private var pending = Data()
    private var previousWasCR = false

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        var lines: [String] = []
        var start = data.startIndex
        for index in data.indices {
            let byte = data[index]
            if previousWasCR {
                previousWasCR = false
                if byte == 10 {
                    start = data.index(after: index)
                    continue
                }
            }
            if byte == 10 || byte == 13 {
                pending.append(contentsOf: data[start..<index])
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
                previousWasCR = byte == 13
                start = data.index(after: index)
            }
        }
        pending.append(contentsOf: data[start..<data.endIndex])
        return lines
    }

    public mutating func finish() -> [String] {
        defer {
            pending.removeAll(keepingCapacity: true)
            previousWasCR = false
        }
        return pending.isEmpty ? [] : [String(decoding: pending, as: UTF8.self)]
    }
}
