// FASTQQualityByteCounter.swift - Q20/Q30 bases counted from raw FASTQ bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Counts the bases of one FASTQ file at or above Q20 and Q30 from its raw
/// bytes, fed in chunks of any size, without building a `FASTQRecord`.
///
/// It follows `FASTQReader`'s record rules so the counts match the record
/// path exactly: blank lines between records, wrapped sequence and quality
/// lines (a quality line may start with '@' or '+'), one trailing CR dropped
/// per line, the empty read whose blank quality line a line reader dropped,
/// and the encoding detected once, from the first complete quality. A base
/// counts at Q20 when its byte is at least the encoding's offset plus 20.
/// The one difference: no line-length limit, where the reader refused lines
/// over 1,000,000 characters.
struct FASTQQualityByteCounter {
    private enum State {
        case header
        case sequence
        case quality
    }

    private var state = State.header
    private var inRecord = false
    private var lineNumber = 0
    private var sequenceLength = 0
    private var qualityLength = 0
    /// The thresholds of the detected encoding, nil until the first record
    /// completes; that record's quality bytes wait in `firstQuality`.
    private var thresholds: (q20: UInt8, q30: UInt8)?
    private var firstQuality: [UInt8] = []
    /// A line the last chunk ended inside.
    private var pendingLine: [UInt8] = []
    private var baseCount: Int64 = 0
    private var q20Count: Int64 = 0
    private var q30Count: Int64 = 0

    mutating func consume(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var start = 0
        while start < bytes.count {
            guard let found = memchr(base + start, 0x0A, bytes.count - start) else {
                pendingLine.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start...]))
                return
            }
            let end = base.distance(to: UnsafeRawPointer(found))
            if pendingLine.isEmpty {
                try line(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            } else {
                pendingLine.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                let held = pendingLine
                pendingLine.removeAll(keepingCapacity: true)
                try held.withUnsafeBytes { try line($0) }
            }
            start = end + 1
        }
    }

    mutating func finish() throws -> FASTQQualityFractions {
        if !pendingLine.isEmpty {
            let held = pendingLine
            pendingLine.removeAll()
            try held.withUnsafeBytes { try line($0) }
        }
        if state == .quality, inRecord, qualityLength < sequenceLength {
            throw FASTQError.qualityLengthMismatch(
                line: lineNumber, sequenceLength: sequenceLength, qualityLength: qualityLength
            )
        }
        if state != .header || inRecord {
            throw FASTQError.unexpectedEndOfFile
        }
        return FASTQQualityFractions(baseCount: baseCount, q20Count: q20Count, q30Count: q30Count)
    }

    /// One line without its newline, as `FASTQReader` would be handed it.
    private mutating func line(_ raw: UnsafeRawBufferPointer) throws {
        lineNumber += 1
        var bytes = raw
        if let last = bytes.last, last == UInt8(ascii: "\r") {
            bytes = UnsafeRawBufferPointer(rebasing: bytes.dropLast())
        }
        let first = bytes.first

        switch state {
        case .header:
            if bytes.isEmpty { return }
            guard first == UInt8(ascii: "@") else {
                throw FASTQError.invalidHeader(line: lineNumber, content: String(decoding: bytes, as: UTF8.self))
            }
            startRecord()

        case .sequence:
            if first == UInt8(ascii: "+") {
                qualityLength = 0
                state = .quality
            } else {
                sequenceLength += bytes.count
            }

        case .quality:
            if sequenceLength == 0, qualityLength == 0, first == UInt8(ascii: "@"), inRecord {
                // An empty read whose blank quality line was dropped: this
                // line is the next header. The reader detects no encoding here.
                startRecord()
                return
            }
            qualityLength += bytes.count
            if qualityLength > sequenceLength {
                throw FASTQError.qualityLengthMismatch(
                    line: lineNumber, sequenceLength: sequenceLength, qualityLength: qualityLength
                )
            }
            if let thresholds {
                count(bytes, thresholds: thresholds)
            } else {
                firstQuality.append(contentsOf: bytes)
            }
            guard qualityLength == sequenceLength else { return }

            if thresholds == nil {
                let encoding = QualityEncoding.detect(fromBytes: firstQuality)
                let detected = (q20: encoding.asciiOffset + 20, q30: encoding.asciiOffset + 30)
                thresholds = detected
                firstQuality.withUnsafeBytes { count($0, thresholds: detected) }
                firstQuality = []
            }
            inRecord = false
            state = .header
        }
    }

    private mutating func startRecord() {
        inRecord = true
        sequenceLength = 0
        qualityLength = 0
        state = .sequence
    }

    private mutating func count(_ quality: UnsafeRawBufferPointer, thresholds: (q20: UInt8, q30: UInt8)) {
        var q20: Int64 = 0
        var q30: Int64 = 0
        for byte in quality {
            if byte >= thresholds.q20 { q20 += 1 }
            if byte >= thresholds.q30 { q30 += 1 }
        }
        baseCount += Int64(quality.count)
        q20Count += q20
        q30Count += q30
    }
}
