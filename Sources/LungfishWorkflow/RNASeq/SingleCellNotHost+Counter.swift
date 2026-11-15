// SingleCellNotHost+Counter.swift - The parser of samtools' SAM text and the pairs of each record (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// An alignment counts when it is primary (no 0x4, 0x100 or 0x800 bit), carries NH:i:1, which STARsolo and Cell Ranger
// write on every aligned read, and carries a CB and a UB other than `-`. Its reference span runs from POS over every
// M, D, N, = and X of its CIGAR, and it lies in the mask when that span overlaps a mask gene by 1 base or more
// (`mtb.py:81-82`). The pairs are held per record, keyed `CB<tab>UB`, with one bit for an alignment outside the mask and
// one for an alignment at nM 0 or 1.

import Foundation

public struct SingleCellNotHostCounter {
    static let outsideBit: UInt8 = 1
    static let nearBit: UInt8 = 2

    public let extras: [SingleCellNotHostExtra]
    /// The records of each extra in turn.
    public let recordNames: [String]
    private let recordIndex: [String: Int]
    private let extraOfRecord: [Int]
    /// Each record's mask genes as 0-based half-open spans.
    private let masks: [[(start: Int, end: Int)]]
    private var pairs: [[String: UInt8]]
    /// Primary alignments at another NH, left out.
    public private(set) var multimapped = 0
    /// Primary alignments at NH 1 with no CB or no UB, left out.
    public private(set) var withoutBarcode = 0
    /// Alignments counted.
    public private(set) var counted = 0

    public init(extras: [SingleCellNotHostExtra]) {
        self.extras = extras
        var names: [String] = []
        var owner: [Int] = []
        for (number, extra) in extras.enumerated() {
            for record in extra.records where !names.contains(record) {
                names.append(record)
                owner.append(number)
            }
        }
        recordNames = names
        extraOfRecord = owner
        recordIndex = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        masks = names.enumerated().map { index, name in
            (extras[owner[index]].mask?.intervals ?? []).filter { $0.record == name }.map { (start: $0.start - 1, end: $0.end) }
        }
        pairs = Array(repeating: [:], count: names.count)
    }

    public mutating func add(samText: String) throws {
        for line in samText.split(separator: "\n", omittingEmptySubsequences: true) { try add(samLine: line) }
    }

    /// Counts one line of `samtools view`. A header line and an alignment to a record of no extra are passed over.
    public mutating func add(samLine: Substring) throws {
        let line = samLine.hasSuffix("\r") ? samLine.dropLast() : samLine
        guard !line.isEmpty, !line.hasPrefix("@") else { return }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 11, let flag = Int(fields[1]), let position = Int(fields[3]) else {
            throw SingleCellNotHostError.unreadableAlignment(String(line.prefix(80)))
        }
        guard flag & 0x904 == 0, let record = recordIndex[String(fields[2])] else { return }
        var nh: Int?
        var nm: Int?
        var cb = "-"
        var ub = "-"
        for tag in fields.dropFirst(11) where tag.count > 5 {
            let value = tag.dropFirst(5)
            switch tag.prefix(5) {
            case "NH:i:": nh = Int(value)
            case "nM:i:": nm = Int(value)
            case "CB:Z:": cb = String(value)
            case "UB:Z:": ub = String(value)
            default: break
            }
        }
        guard nh == 1 else {
            multimapped += 1
            return
        }
        guard cb != "-", ub != "-", !cb.isEmpty, !ub.isEmpty else {
            withoutBarcode += 1
            return
        }
        let start = position - 1
        let end = start + Self.referenceLength(fields[5])
        let inMask = masks[record].contains { $0.start < end && start < $0.end }
        var bits: UInt8 = inMask ? 0 : Self.outsideBit
        if let nm, nm <= 1 { bits |= Self.nearBit }
        pairs[record][cb + "\t" + ub, default: 0] |= bits
        counted += 1
    }

    /// The bases of the reference a CIGAR spans: its M, D, N, = and X lengths.
    static func referenceLength(_ cigar: Substring) -> Int {
        var length = 0
        var number = 0
        for character in cigar.utf8 {
            if character >= 48, character <= 57 {
                number = number * 10 + Int(character - 48)
                continue
            }
            switch character {
            case UInt8(ascii: "M"), UInt8(ascii: "D"), UInt8(ascii: "N"), UInt8(ascii: "="), UInt8(ascii: "X"): length += number
            default: break
            }
            number = 0
        }
        return length
    }

    /// Each barcode's counts by record and by extra. A pair on two records of one extra counts once in the extra's
    /// figure, default when any of its alignments lies outside the mask and near when any lies at nM 0 or 1.
    public func tallies() -> [String: SingleCellNotHostTally] {
        let empty = SingleCellNotHostTally(
            genome: Array(repeating: .init(), count: extras.count), records: Array(repeating: .init(), count: recordNames.count))
        var tallies: [String: SingleCellNotHostTally] = [:]
        var genome: [[String: UInt8]] = Array(repeating: [:], count: extras.count)
        for (record, keyed) in pairs.enumerated() {
            for (key, bits) in keyed {
                let barcode = String(key.prefix { $0 != "\t" })
                tallies[barcode, default: empty].records[record].add(bits)
                genome[extraOfRecord[record]][key, default: 0] |= bits
            }
        }
        for (extra, keyed) in genome.enumerated() {
            for (key, bits) in keyed { tallies[String(key.prefix { $0 != "\t" }), default: empty].genome[extra].add(bits) }
        }
        return tallies
    }

    /// Counts the lines of a file `samtools view` wrote, read 1 MiB at a time.
    public mutating func add(samFile url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var carry = Data()
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            try Task.checkCancellation()
            carry.append(chunk)
            guard let last = carry.lastIndex(of: UInt8(ascii: "\n")) else { return true }
            try add(samText: String(decoding: carry[carry.startIndex...last], as: UTF8.self))
            carry = Data(carry[carry.index(after: last)...])
            return true
        }) {}
        if !carry.isEmpty { try add(samText: String(decoding: carry, as: UTF8.self)) }
    }

    /// Refuses in words a BAM whose header lacks a not-host record of the set or holds it at another length, since
    /// its reads were not aligned to this set.
    public static func checkHeader(_ header: String, bam: String, records: [SingleCellNotHostRecord]) throws {
        var lengths: [String: Int] = [:]
        for line in header.split(separator: "\n") where line.hasPrefix("@SQ") {
            var name: String?
            var length: Int?
            for field in line.split(separator: "\t") {
                if field.hasPrefix("SN:") { name = String(field.dropFirst(3)) }
                if field.hasPrefix("LN:") { length = Int(field.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            if let name, let length { lengths[name] = length }
        }
        for record in records {
            guard let found = lengths[record.name] else { throw SingleCellNotHostError.recordMissing(bam: bam, record: record.name) }
            guard found == record.length else {
                throw SingleCellNotHostError.recordLength(bam: bam, record: record.name, bamLength: found, setLength: record.length)
            }
        }
    }
}
