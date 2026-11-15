// SingleCellNotHost+Pool.swift - The raw barcodes, the ambient pool and the flag (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pool is ranks 45,000 to 90,000 by UMI in the raw matrix among barcodes with a UMI, ties in barcode-byte order
// (C collation), from LGE's own sort and never a file's order. With fewer than 90,000 such barcodes it runs to the last,
// and with fewer than 45,000 there is none (ADJ-SC-3 item 1). The raw list of 10x holds 6,794,880 barcodes, so they are
// held by index in one byte buffer and never as one String each (ARCH-SCHEMA-SPIKE B6).

import Foundation
import LungfishIO

/// The barcodes of a raw list, held by index in one buffer.
public struct SingleCellBarcodeTable: @unchecked Sendable {
    private let bytes: Data
    private let starts: [UInt32]
    private let lengths: [UInt8]
    /// The indices in byte order, or nil when the list is in byte order already.
    private let order: [UInt32]?

    /// Reads one barcode a line, with or without a carriage return.
    public init(data: Data) {
        bytes = data
        var starts: [UInt32] = []
        var lengths: [UInt8] = []
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < base.count {
                var end = start
                while end < base.count, base[end] != UInt8(ascii: "\n") { end += 1 }
                var stop = end
                if stop > start, base[stop - 1] == UInt8(ascii: "\r") { stop -= 1 }
                starts.append(UInt32(start))
                lengths.append(UInt8(min(stop - start, 255)))
                start = end + 1
            }
        }
        self.starts = starts
        self.lengths = lengths
        let sorted = data.withUnsafeBytes { raw in
            (1..<max(starts.count, 1)).allSatisfy { Self.compare(raw, starts, lengths, $0 - 1, $0) <= 0 }
        }
        if sorted {
            order = nil
        } else {
            var permutation = (0..<starts.count).map(UInt32.init)
            data.withUnsafeBytes { raw in permutation.sort { Self.compare(raw, starts, lengths, Int($0), Int($1)) < 0 } }
            order = permutation
        }
    }

    public var count: Int { starts.count }
    public var isSorted: Bool { order == nil }

    public func barcode(at index: Int) -> String {
        let start = Int(starts[index])
        return String(decoding: bytes[bytes.startIndex + start ..< bytes.startIndex + start + Int(lengths[index])], as: UTF8.self)
    }

    /// The index of `barcode` in the list, by binary search in byte order.
    public func index(of barcode: String) -> Int? {
        let key = Array(barcode.utf8)
        return bytes.withUnsafeBytes { raw -> Int? in
            var low = 0
            var high = starts.count
            while low < high {
                let middle = (low + high) / 2
                let at = order.map { Int($0[middle]) } ?? middle
                let found = key.withUnsafeBytes { Self.compare(raw, Int(starts[at]), Int(lengths[at]), $0, 0, key.count) }
                if found == 0 { return at }
                if found < 0 { low = middle + 1 } else { high = middle }
            }
            return nil
        }
    }

    /// Runs `body` with a comparison of two indices in byte order, valid only inside `body`.
    func withComparison<T>(_ body: ((Int, Int) -> Int32) throws -> T) rethrows -> T {
        try bytes.withUnsafeBytes { raw in try body { Self.compare(raw, starts, lengths, $0, $1) } }
    }

    private static func compare(_ raw: UnsafeRawBufferPointer, _ starts: [UInt32], _ lengths: [UInt8], _ a: Int, _ b: Int) -> Int32 {
        compare(raw, Int(starts[a]), Int(lengths[a]), raw, Int(starts[b]), Int(lengths[b]))
    }

    private static func compare(
        _ left: UnsafeRawBufferPointer, _ leftStart: Int, _ leftLength: Int, _ right: UnsafeRawBufferPointer, _ rightStart: Int, _ rightLength: Int
    ) -> Int32 {
        guard let l = left.baseAddress, let r = right.baseAddress else { return Int32(leftLength - rightLength) }
        let found = memcmp(l + leftStart, r + rightStart, min(leftLength, rightLength))
        return found != 0 ? found : Int32(leftLength - rightLength)
    }
}

/// A raw matrix's barcodes and each barcode's UMIs over every feature, as both scripts sum them.
public struct SingleCellRawMatrix: Sendable {
    public var barcodes: SingleCellBarcodeTable
    public var totals: [UInt64]

    public init(barcodes: SingleCellBarcodeTable, totals: [UInt64]) {
        self.barcodes = barcodes
        self.totals = totals
    }

    /// Reads a raw folder's barcodes and matrix by path. The matrix is read once in batches and never copied.
    public static func read(matrix: URL, barcodes: URL, sample: String) throws -> SingleCellRawMatrix {
        let data = try MatrixMarketReader.isGzipFile(barcodes)
            ? Data(try GzipInputStream(url: barcodes).readAllSync().utf8) : Data(contentsOf: barcodes, options: .mappedIfSafe)
        let table = SingleCellBarcodeTable(data: data)
        let reader = try MatrixMarketReader(url: matrix)
        defer { reader.close() }
        guard reader.size.columns == table.count else {
            throw SingleCellNotHostError.rawMatrixDiffers(sample: sample, stated: reader.size.columns, listed: table.count)
        }
        var totals = [UInt64](repeating: 0, count: table.count)
        var batch = MatrixMarketBatch(capacity: 1 << 16)
        while try reader.next(&batch) {
            try Task.checkCancellation()
            let columns = batch.columns
            let values = batch.values
            for index in 0..<values.count { totals[columns[index] - 1] &+= values[index] }
        }
        return SingleCellRawMatrix(barcodes: table, totals: totals)
    }
}

/// The ambient pool of one library's raw matrix (ADJ-SC-3 item 1).
public struct SingleCellAmbientPool: Sendable, Equatable {
    public static let poolFirstRank = 45_000
    public static let poolLastRank = 90_000

    public var barcodesWithUMI: Int
    /// The raw indices of the pool's barcodes in rank order.
    public var members: [Int] = []
    public var firstRank: Int?
    public var lastRank: Int?
    public var umiRange: ClosedRange<UInt64>?
    public var umis: UInt64 = 0
    /// `not computed: N barcodes, too few for an ambient pool` when there is no pool.
    public var words: String?

    public init(_ raw: SingleCellRawMatrix) {
        var ranked = raw.totals.indices.filter { raw.totals[$0] > 0 }.map { UInt32($0) }
        barcodesWithUMI = ranked.count
        guard ranked.count >= Self.poolFirstRank else {
            words = SingleCellNotHostFlag.noPoolWords(ranked.count)
            return
        }
        let totals = raw.totals
        let byIndex = raw.barcodes.isSorted
        raw.barcodes.withComparison { compare in
            ranked.sort { a, b in
                let left = totals[Int(a)]
                let right = totals[Int(b)]
                if left != right { return left > right }
                return byIndex ? a < b : compare(Int(a), Int(b)) < 0
            }
        }
        let last = min(Self.poolLastRank, ranked.count)
        members = ranked[(Self.poolFirstRank - 1)..<last].map { Int($0) }
        firstRank = Self.poolFirstRank
        lastRank = last
        let values = members.map { totals[$0] }
        umis = values.reduce(0, &+)
        if let low = values.min(), let high = values.max() { umiRange = low...high }
    }
}

/// The flag of a cell's not-host RNA above the ambient pool (gate GN, ADJ-SC-3 item 2).
public enum SingleCellNotHostFlag {
    public static let qBar = 0.001
    public static let minimumUMIs = 2

    /// The words of a flagged cell, or nil for a spike-in, which gets counts and no flag.
    public static func words(for kind: ReferenceSetExtraKind) -> String? {
        switch kind {
        case .virus: return "viral RNA above ambient"
        case .bacterium: return "bacterial RNA above ambient"
        case .spikeIn: return nil
        }
    }

    public static func noPoolWords(_ barcodes: Int) -> String { "not computed: \(barcodes) barcodes, too few for an ambient pool" }
    public static func noMaskWords(_ extra: String) -> String { "not computed: no rRNA mask for \(extra)" }

    /// (pool not-host UMIs + 1) / pool UMIs, with no step at 0.
    public static func rate(notHostUMIs: Int, poolUMIs: UInt64) -> Double { Double(notHostUMIs + 1) / Double(max(poolUMIs, 1)) }
}
