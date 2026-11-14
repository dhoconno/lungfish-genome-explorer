// FASTQReadLayoutClassifier+PairHash.swift - One whole-file pass for the counts, the order-free pair hash and the instrument
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// The order-free fingerprint of the read pairs of one file (row RS-INSTRUMENT, ruling ADJ-BULK G5).
///
/// For every pair it takes md5(Read 1 sequence, a TAB, Read 2 sequence), reads the 16 digest bytes as one 128-bit
/// number and adds the numbers modulo 2**128, as `scripts/repro/rnaseq/gse163196/pairhash.py` does. Names and
/// qualities are left out and the order of the pairs does not matter, so two uploads of one library in another order,
/// with other names or other quality bins, give one sum. Equal sums with equal pair counts mean the same multiset of
/// pairs, up to a chance collision of about 2**-128.
public struct FASTQPairHashAccumulator: Sendable, Equatable {
    private var high: UInt64 = 0
    private var low: UInt64 = 0
    public private(set) var pairs = 0

    public init() {}

    public mutating func add(read1: String, read2: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(read1.utf8.count + read2.utf8.count + 1)
        bytes.append(contentsOf: read1.utf8)
        bytes.append(0x09)
        bytes.append(contentsOf: read2.utf8)
        var digestHigh: UInt64 = 0
        var digestLow: UInt64 = 0
        var position = 0
        for byte in Insecure.MD5.hash(data: bytes) {
            if position < 8 {
                digestHigh = (digestHigh << 8) | UInt64(byte)
            } else {
                digestLow = (digestLow << 8) | UInt64(byte)
            }
            position += 1
        }
        let (sum, carried) = low.addingReportingOverflow(digestLow)
        low = sum
        high = high &+ digestHigh &+ (carried ? 1 : 0)
        pairs += 1
    }

    /// The sum as 32 lowercase hex digits.
    public var hex: String { String(format: "%016llx%016llx", high, low) }
}

extension FASTQReadLayoutClassifier {

    /// What one pass over a FASTQ file learns. The counts are those of ``countMates(in:limit:)``.
    public struct MateScan: Sendable, Equatable {
        public let scannedRecords: Int
        public let matePairs: Int
        public let unpairedRecords: Int
        public let scannedWholeFile: Bool
        /// The order-free hash of the adjacent mate pairs, nil when the file holds none.
        public let pairHash: String?
        /// The instrument facts of the read names.
        public let instrument: SequencerInstrument
    }

    private struct StopMateScan: Error {}

    /// ``countMates(in:limit:)`` plus the pair hash and the instrument facts, holding one record's sequence at a time.
    /// A cancelled task stops the scan and it throws.
    public static func scanMates(in fastqURL: URL, limit: Int = defaultRecordLimit) throws -> MateScan {
        var scanned = 0
        var pairs = 0
        var unpaired = 0
        var held: String?
        var heldSequence = ""
        var completesPair = false
        var lineIndex = 0
        var reachedLimit = false
        var hash = FASTQPairHashAccumulator()
        var instrument = SequencerInstrumentScan()
        do {
            try fastqURL.forEachLineAutoDecompressing { line in
                defer { lineIndex += 1 }
                let phase = lineIndex % 4
                if phase == 1 {
                    if completesPair {
                        hash.add(read1: heldSequence, read2: line)
                        completesPair = false
                    } else {
                        heldSequence = line
                    }
                    return
                }
                guard phase == 0 else { return }
                if line.isEmpty { return }
                guard line.hasPrefix("@") else {
                    if scanned > 0 { reachedLimit = true }
                    throw StopMateScan()
                }
                if scanned >= limit {
                    reachedLimit = true
                    throw StopMateScan()
                }
                scanned += 1
                if scanned & 0x3FFF == 0 { try Task.checkCancellation() }
                let header = String(line.dropFirst())
                instrument.observe(header: header)
                if let first = held, areMates(first, header) {
                    pairs += 1
                    held = nil
                    completesPair = true
                } else {
                    if held != nil { unpaired += 1 }
                    held = header
                    completesPair = false
                }
            }
        } catch is StopMateScan {
            // Bounded early exit, as in countMates.
        }
        if held != nil, !reachedLimit { unpaired += 1 }
        return MateScan(
            scannedRecords: scanned, matePairs: pairs, unpairedRecords: unpaired, scannedWholeFile: !reachedLimit,
            pairHash: pairs > 0 ? hash.hex : nil, instrument: instrument.result()
        )
    }
}
