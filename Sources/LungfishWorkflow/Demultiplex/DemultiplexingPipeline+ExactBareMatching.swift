// DemultiplexingPipeline+ExactBareMatching.swift - Exact bare-barcode matching for the Swift-native demultiplex engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    struct ExactBareBarcodeMatch: Sendable {
        let barcodeIndex: Int
        let start: Int
        let length: Int
    }

    struct ExactBareBarcodeAssignment: Sendable {
        let barcodeIndex: Int
        let trim5p: Int
        let trim3p: Int
    }

    struct ExactBareBarcodeAccumulator: Sendable {
        let barcodeID: String
        var readIDs: [String] = []
        var previewRecords: [FASTQRawRecord] = []
        var trimEntries: [DemuxTrimEntry] = []
        var readCount: Int = 0
        var baseCount: Int64 = 0
        var minReadLength: Int = Int.max
        var maxReadLength: Int = 0
        var readLengthHistogram: [Int: Int] = [:]

        mutating func add(
            readID: String,
            previewRecord: FASTQRawRecord,
            outputLength: Int,
            trimEntry: DemuxTrimEntry?,
            previewLimit: Int = 1000
        ) {
            readIDs.append(readID)
            if previewRecords.count < previewLimit {
                previewRecords.append(previewRecord)
            }
            if let trimEntry {
                trimEntries.append(trimEntry)
            }
            readCount += 1
            baseCount += Int64(outputLength)
            minReadLength = min(minReadLength, outputLength)
            maxReadLength = max(maxReadLength, outputLength)
            readLengthHistogram[outputLength, default: 0] += 1
        }

        mutating func merge(_ other: ExactBareBarcodeAccumulator, previewLimit: Int = 1000) {
            guard other.readCount > 0 else { return }
            readIDs.append(contentsOf: other.readIDs)
            if previewRecords.count < previewLimit {
                previewRecords.append(contentsOf: other.previewRecords.prefix(previewLimit - previewRecords.count))
            }
            trimEntries.append(contentsOf: other.trimEntries)
            readCount += other.readCount
            baseCount += other.baseCount
            minReadLength = min(minReadLength, other.finalizedMinReadLength)
            maxReadLength = max(maxReadLength, other.maxReadLength)
            for (length, count) in other.readLengthHistogram {
                readLengthHistogram[length, default: 0] += count
            }
        }

        var finalizedMinReadLength: Int {
            readCount > 0 ? minReadLength : 0
        }
    }

    struct ExactBareBarcodeShardResult: Sendable {
        let shardIndex: Int
        let barcodeAccumulators: [ExactBareBarcodeAccumulator]
        let unassigned: ExactBareBarcodeAccumulator
        let totalReads: Int
        let assignedReads: Int
        let mateCalls: DemultiplexMateCallCounter
    }

    /// Pairs adjacent mates while the exact-bare engine streams records, so
    /// both mates of a fragment follow the fragment's call (A9, D6). Mates
    /// are found by `FASTQReadLayoutClassifier.areMates`, the rule the
    /// by-name split uses. A run of single reads places each record alone.
    struct ExactBareMatePairer {
        /// Records that go to one barcode, or to unassigned when `call` is nil.
        struct Fragment {
            let records: [FASTQRawRecord]
            let call: Int?
        }

        let placesMates: Bool
        private(set) var calls = DemultiplexMateCallCounter()
        private var pending: (record: FASTQRawRecord, call: Int?)?

        init(placesMates: Bool) {
            self.placesMates = placesMates
        }

        /// Takes the next record and its own call, and returns the fragments ready to place.
        mutating func add(_ record: FASTQRawRecord, call: Int?) -> [Fragment] {
            guard placesMates else { return [Fragment(records: [record], call: call)] }
            guard let previous = pending else {
                pending = (record, call)
                return []
            }
            if FASTQReadLayoutClassifier.areMates(Self.headerText(previous.record), Self.headerText(record)) {
                pending = nil
                let decision = DemultiplexFragmentCall.call(previous.call, call)
                calls.count(decision.outcome)
                return [Fragment(records: [previous.record, record], call: decision.call)]
            }
            pending = (record, call)
            calls.countSingleRead()
            return [Fragment(records: [previous.record], call: previous.call)]
        }

        /// Returns the last record when it had no mate.
        mutating func finish() -> [Fragment] {
            guard let previous = pending else { return [] }
            pending = nil
            calls.countSingleRead()
            return [Fragment(records: [previous.record], call: previous.call)]
        }

        private static func headerText(_ record: FASTQRawRecord) -> String {
            record.header.hasPrefix("@") ? String(record.header.dropFirst()) : record.header
        }
    }

    struct ExactBareBarcodeMatcher: Sendable {
        struct Candidate: Sendable {
            let barcodeIndex: Int
        }

        let barcodeCount: Int
        let barcodeLocation: BarcodeLocation
        let maxDistanceFrom5Prime: Int
        let maxDistanceFrom3Prime: Int
        let mapsByLength: [Int: [UInt64: [Candidate]]]
        let lengths: [Int]

        init?(
            barcodes: [BarcodeEntry],
            barcodeLocation: BarcodeLocation,
            maxDistanceFrom5Prime: Int,
            maxDistanceFrom3Prime: Int,
            includeReverseComplements: Bool
        ) {
            var mapsByLength: [Int: [UInt64: [Candidate]]] = [:]
            for (index, barcode) in barcodes.enumerated() {
                let primary = barcode.i7Sequence.uppercased()
                guard let primaryCode = Self.twoBitCode(primary) else {
                    return nil
                }
                mapsByLength[primary.count, default: [:]][primaryCode, default: []]
                    .append(Candidate(barcodeIndex: index))

                if includeReverseComplements {
                    let rc = PlatformAdapters.reverseComplement(primary)
                    if rc != primary {
                        guard let rcCode = Self.twoBitCode(rc) else {
                            return nil
                        }
                        mapsByLength[rc.count, default: [:]][rcCode, default: []]
                            .append(Candidate(barcodeIndex: index))
                    }
                }
            }
            self.barcodeCount = barcodes.count
            self.barcodeLocation = barcodeLocation
            self.maxDistanceFrom5Prime = max(0, maxDistanceFrom5Prime)
            self.maxDistanceFrom3Prime = max(0, maxDistanceFrom3Prime)
            self.mapsByLength = mapsByLength
            self.lengths = mapsByLength.keys.sorted()
        }

        func assignment(for sequence: String) -> ExactBareBarcodeAssignment? {
            let bytes = Array(sequence.utf8)
            guard let match = findAny(in: bytes) else { return nil }
            return ExactBareBarcodeAssignment(
                barcodeIndex: match.barcodeIndex,
                trim5p: 0,
                trim3p: 0
            )
        }

        private func findAny(in bytes: [UInt8]) -> ExactBareBarcodeMatch? {
            var best: ExactBareBarcodeMatch?
            for length in lengths {
                guard length <= bytes.count,
                      let map = mapsByLength[length] else { continue }
                if let match = findMatch(
                    in: bytes,
                    length: length,
                    startRange: 0...(bytes.count - length),
                    map: map,
                    preferLast: false
                ) {
                    if best == nil || match.start < best!.start {
                        best = match
                    }
                }
            }
            return best
        }

        private func findMatch(
            in bytes: [UInt8],
            length: Int,
            startRange: ClosedRange<Int>,
            map: [UInt64: [Candidate]],
            preferLast: Bool
        ) -> ExactBareBarcodeMatch? {
            guard length > 0, length <= 31 else { return nil }
            var code: UInt64 = 0
            var validBases = 0
            let mask = length == 31 ? UInt64.max >> 2 : (UInt64(1) << UInt64(length * 2)) - 1
            var best: ExactBareBarcodeMatch?

            for (index, byte) in bytes.enumerated() {
                guard let bits = Self.baseBits(byte) else {
                    code = 0
                    validBases = 0
                    continue
                }
                code = ((code << 2) | UInt64(bits)) & mask
                validBases += 1
                guard validBases >= length else { continue }

                let start = index - length + 1
                guard startRange.contains(start),
                      let candidates = map[code],
                      let candidate = candidates.first else {
                    continue
                }
                let match = ExactBareBarcodeMatch(
                    barcodeIndex: candidate.barcodeIndex,
                    start: start,
                    length: length
                )
                if best == nil
                    || (!preferLast && match.start < best!.start)
                    || (preferLast && match.start > best!.start) {
                    best = match
                }
            }
            return best
        }

        static func twoBitCode(_ sequence: String) -> UInt64? {
            guard !sequence.isEmpty, sequence.utf8.count <= 31 else { return nil }
            var code: UInt64 = 0
            for byte in sequence.utf8 {
                guard let bits = baseBits(byte) else { return nil }
                code = (code << 2) | UInt64(bits)
            }
            return code
        }

        private static func baseBits(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "A"), UInt8(ascii: "a"): return 0
            case UInt8(ascii: "C"), UInt8(ascii: "c"): return 1
            case UInt8(ascii: "G"), UInt8(ascii: "g"): return 2
            case UInt8(ascii: "T"), UInt8(ascii: "t"): return 3
            default: return nil
            }
        }
    }

    func supportsExactBareBarcodeDemux(_ config: DemultiplexConfig) -> Bool {
        guard config.sampleAssignments.isEmpty,
              !config.barcodeKit.isDualIndexed,
              config.barcodeKit.pairingMode == .singleEnd || config.barcodeKit.pairingMode == .symmetric,
              config.resolvedAdapterContext is BareAdapterContext else {
            return false
        }
        guard config.barcodeKit.barcodes.allSatisfy({
            $0.i5Sequence == nil && ExactBareBarcodeMatcher.twoBitCode($0.i7Sequence.uppercased()) != nil
        }) else {
            return false
        }
        return true
    }

    func shouldSearchBareBarcodeReverseComplements(_ config: DemultiplexConfig) -> Bool {
        config.searchReverseComplement
            || config.symmetryMode == .symmetric
            || config.barcodeKit.kitType == .fluidigmAccessArray
            || config.barcodeKit.vendor == "custom"
    }

    final class ExactBareFASTQOutputCache {
        private let limit: Int
        private var handles: [String: FileHandle] = [:]
        private var usageOrder: [String] = []

        init(limit: Int = 64) {
            self.limit = max(1, limit)
        }

        func write(_ record: FASTQRawRecord, to url: URL) throws {
            let key = url.path
            let handle = try handle(for: key, url: url)
            try handle.write(contentsOf: Data(record.fastqString.utf8))
        }

        func closeAll() throws {
            var firstError: Error?
            for (_, handle) in handles {
                do {
                    try handle.close()
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            handles.removeAll()
            usageOrder.removeAll()
            if let firstError { throw firstError }
        }

        private func handle(for key: String, url: URL) throws -> FileHandle {
            if let existing = handles[key] {
                markUsed(key)
                return existing
            }

            if handles.count >= limit, let evictKey = usageOrder.first {
                usageOrder.removeFirst()
                if let evicted = handles.removeValue(forKey: evictKey) {
                    try evicted.close()
                }
            }

            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            handles[key] = handle
            usageOrder.append(key)
            return handle
        }

        private func markUsed(_ key: String) {
            usageOrder.removeAll { $0 == key }
            usageOrder.append(key)
        }
    }
}
