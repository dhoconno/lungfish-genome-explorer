// DemultiplexingPipeline+DualForm.swift - Which way the first reads carry the secondary sequence of a Custom Definition
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The way a run reads the secondary sequence of a custom dual-index definition at Both Ends with no sample sheet
    /// (DEMUX-DUAL-FORM, BIO-DUAL-FORM item 2). The record names it as `secondaryForm`.
    public enum SecondaryForm: String, Sendable, Equatable {
        /// The bases of the column appear at the end of the read.
        case asWritten = "as-written"
        /// The column is the i5 primer's barcode, so its reverse complement appears at the end of the read.
        case reverseComplemented = "reverse-complemented"
    }

    /// The form the first reads chose and the votes that chose it, which the record keeps as `secondaryForm` and
    /// `secondaryFormVotes`.
    public struct SecondaryFormChoice: Sendable, Equatable, CustomStringConvertible {
        public let form: SecondaryForm
        /// The records read, each mate of an interleaved file one, as Cutadapt reads them.
        public let readsRead: Int
        /// The reads that only the column as written placed.
        public let asWritten: Int
        /// The reads that only the column reverse complemented placed.
        public let reverseComplemented: Int
        /// The reads that both forms placed, in different rows.
        public let disputed: Int
        /// The rows that carry the chosen form, 0 when no row carries a form and the run reads the column as written.
        public let rowsCarrying: Int

        public init(
            form: SecondaryForm, readsRead: Int, asWritten: Int, reverseComplemented: Int, disputed: Int, rowsCarrying: Int
        ) {
            self.form = form
            self.readsRead = readsRead
            self.asWritten = asWritten
            self.reverseComplemented = reverseComplemented
            self.disputed = disputed
            self.rowsCarrying = rowsCarrying
        }

        /// The choice a record names by its two fields, or nil when it names none.
        public init?(recordedForm: String?, votes: [String: Int]) {
            guard let recordedForm, let form = SecondaryForm(rawValue: recordedForm) else { return nil }
            self.init(
                form: form, readsRead: votes["readsRead"] ?? 0, asWritten: votes["asWritten"] ?? 0,
                reverseComplemented: votes["reverseComplemented"] ?? 0, disputed: votes["disputed"] ?? 0,
                rowsCarrying: votes["rowsCarrying"] ?? 0
            )
        }

        /// The record's `secondaryFormVotes`.
        public var votes: [String: Int] {
            [
                "readsRead": readsRead, "asWritten": asWritten, "reverseComplemented": reverseComplemented,
                "disputed": disputed, "rowsCarrying": rowsCarrying,
            ]
        }

        public var description: String {
            "\(form.rawValue) readsRead \(readsRead) asWritten \(asWritten) reverseComplemented \(reverseComplemented) "
                + "disputed \(disputed) rowsCarrying \(rowsCarrying)"
        }

        /// The line of the Operations Panel row, its Log and the command's log, a line of information and no warning
        /// (UX-WORDS-2 section 3 (c)).
        public var line: String {
            let first = "of the first \(DemultiplexError.grouped(readsRead)) reads"
            guard rowsCarrying > 0 else {
                return "The run read each secondary sequence as written, since too few \(first) carry a barcode pair to tell "
                    + "which way it is written."
            }
            switch form {
            case .asWritten:
                return "The run read each secondary sequence as written, since \(DemultiplexError.grouped(asWritten)) \(first) "
                    + "carry it that way."
            case .reverseComplemented:
                return "The run read each secondary sequence reverse complemented, as the i5 primer's barcode, since "
                    + "\(DemultiplexError.grouped(reverseComplemented)) \(first) carry it that way."
            }
        }

        /// `entries` with each secondary sequence as this form reads it, so the writer, unchanged, writes its lines.
        func oriented(_ entries: [(name: String, first: String, second: String)]) -> [(name: String, first: String, second: String)] {
            guard form == .reverseComplemented else { return entries }
            return entries.map { ($0.name, $0.first, PlatformAdapters.reverseComplement($0.second.uppercased())) }
        }
    }

    /// The records the choice reads, the count Detect reads (`DemultiplexingPipeline+Scout.swift:38`).
    static let secondaryFormReadLimit = 10_000
    /// A row carries a form when more than this many votes for the form land in it, Detect's reject threshold
    /// (`DemultiplexingPipeline+Scout.swift:40`). Chance votes spread over all the rows, so they make no row carry a form.
    static let secondaryFormRowThreshold = 3

    /// Chooses the way the first reads carry the secondary sequence of each row (BIO-DUAL-FORM item 2). It tests every row's
    /// anchored pair as the writer places it (`writeObservedLinkedAdapterFASTA`), the first barcode at each offset from 0 to
    /// the 5' distance and the second ending 0 to the 3' distance bases before the read end, on the strand as written and
    /// on the other strand, once with the column as written and once reverse complemented. Each barcode may hold at most
    /// floor(error rate x its length) substitutions, an N of a barcode matching any base, and no indel, which is Cutadapt's
    /// budget for each side of a linked line. No Cutadapt run starts, so the line cap counts each line once. A read that
    /// only one form places is a vote for that form in the rows it lands in, and a read that both forms place in different
    /// rows is disputed. No row carrying a form reads the column as written with no more than 3 disputed reads, and throws
    /// ``DemultiplexError/dualFormUndecided(kitName:rows:)`` with more. Rows carrying both forms throw
    /// ``DemultiplexError/dualFormMixed(kitName:asWritten:reverseComplemented:)``. It returns nil when the input gives no
    /// record as FASTQ, as at the preflight of a FASTA input, whose run reads the FASTQ made from it.
    func chooseSecondaryForm(
        of entries: [(name: String, first: String, second: String)], config: DemultiplexConfig
    ) async throws -> SecondaryFormChoice? {
        let rows = entries.map { DualFormRow(first: $0.first, second: $0.second, errorRate: config.effectiveErrorRate) }
        let fivePrime = max(0, config.maxDistanceFrom5Prime)
        let threePrime = max(0, config.maxDistanceFrom3Prime)
        var readsRead = 0, asWritten = 0, reverseComplemented = 0, disputed = 0
        var writtenVotes = [Int](repeating: 0, count: rows.count)
        var reverseVotes = [Int](repeating: 0, count: rows.count)
        var disputedRows = Set<Int>()
        do {
            for try await record in FASTQReader(validateSequence: false).records(from: resolveInputFASTQ(config.inputURL)) {
                readsRead += 1
                let read = Array(record.sequence.uppercased().utf8)
                var written: [Int] = []
                var reversed: [Int] = []
                for (index, row) in rows.enumerated() {
                    let placed = row.places(read, fivePrime: fivePrime, threePrime: threePrime)
                    if placed.asWritten { written.append(index) }
                    if placed.reverseComplemented { reversed.append(index) }
                }
                if written == reversed {
                    // No row, or the same rows both ways, as for a secondary sequence that is its own reverse complement.
                } else if reversed.isEmpty {
                    asWritten += 1
                    written.forEach { writtenVotes[$0] += 1 }
                } else if written.isEmpty {
                    reverseComplemented += 1
                    reversed.forEach { reverseVotes[$0] += 1 }
                } else {
                    disputed += 1
                    disputedRows.formUnion(written)
                    disputedRows.formUnion(reversed)
                }
                if readsRead >= Self.secondaryFormReadLimit { break }
            }
        } catch {
            guard readsRead > 0 else { return nil }
        }
        let threshold = Self.secondaryFormRowThreshold
        let carryWritten = writtenVotes.indices.filter { writtenVotes[$0] > threshold }
        let carryReverse = reverseVotes.indices.filter { reverseVotes[$0] > threshold }
        let kitName = config.barcodeKit.displayName
        func names(_ indices: [Int]) -> [String] { indices.sorted().map { entries[$0].name } }
        let form: SecondaryForm
        let carrying: Int
        switch (carryWritten.isEmpty, carryReverse.isEmpty) {
        case (true, true):
            guard disputed <= threshold else {
                throw DemultiplexError.dualFormUndecided(kitName: kitName, rows: names(Array(disputedRows)))
            }
            (form, carrying) = (.asWritten, 0)
        case (false, true):
            (form, carrying) = (.asWritten, carryWritten.count)
        case (true, false):
            (form, carrying) = (.reverseComplemented, carryReverse.count)
        case (false, false):
            // The rows of the form fewer rows carry are named, and both sets on a tie (UX-WORDS-2 section 3 (a)).
            throw DemultiplexError.dualFormMixed(
                kitName: kitName,
                asWritten: carryWritten.count > carryReverse.count ? [] : names(carryWritten),
                reverseComplemented: carryReverse.count > carryWritten.count ? [] : names(carryReverse)
            )
        }
        return SecondaryFormChoice(
            form: form, readsRead: readsRead, asWritten: asWritten, reverseComplemented: reverseComplemented,
            disputed: disputed, rowsCarrying: carrying
        )
    }

    /// ``requireBarcodesAboveChance(config:adapterFASTA:counts:readsSearched:unassigned:paired:unassignedReadsURL:)`` for a
    /// run that chose `secondaryForm`, whose refusal says the way the column is written is not the cause, since the run
    /// looked for it both ways (UX-WORDS-2 section 3 (b)). The floor itself is unchanged.
    func requireBarcodesAboveChance(
        config: DemultiplexConfig, adapterFASTA: URL, counts: [String: Int], readsSearched: Int, unassigned: Int,
        paired: Bool, unassignedReadsURL: URL?, secondaryForm: SecondaryFormChoice?
    ) async throws -> DemultiplexChanceFloor.Outcome? {
        do {
            return try await requireBarcodesAboveChance(
                config: config, adapterFASTA: adapterFASTA, counts: counts, readsSearched: readsSearched,
                unassigned: unassigned, paired: paired, unassignedReadsURL: unassignedReadsURL
            )
        } catch DemultiplexError.noBarcodeAboveChance(let kitName, _) where secondaryForm != nil {
            throw DemultiplexError.noBarcodeAboveChance(kitName: kitName, readsSecondaryBothWays: true)
        }
    }
}

/// One row of a custom dual-index definition as the choice of form tests it.
private struct DualFormRow {
    let first: [UInt8]
    let reverseFirst: [UInt8]
    let second: [UInt8]
    let reverseSecond: [UInt8]
    let firstErrors: Int
    let secondErrors: Int

    init(first: String, second: String, errorRate: Double) {
        let first = first.uppercased()
        let second = second.uppercased()
        self.first = Array(first.utf8)
        self.reverseFirst = Array(PlatformAdapters.reverseComplement(first).utf8)
        self.second = Array(second.utf8)
        self.reverseSecond = Array(PlatformAdapters.reverseComplement(second).utf8)
        func errors(_ bases: String) -> Int { Int((errorRate * Double(bases.filter { $0 != "N" }.count)).rounded(.down)) }
        firstErrors = errors(first)
        secondErrors = errors(second)
    }

    /// Whether the lines of each form place `read`, on the strand as written (`^first...back$`) or on the other strand
    /// (`^front...rc(first)$`), at some pair of distances.
    func places(_ read: [UInt8], fivePrime: Int, threePrime: Int) -> (asWritten: Bool, reverseComplemented: Bool) {
        var asWritten = false
        var reverseComplemented = false
        if let start = Self.front(first, firstErrors, read, fivePrime) {
            asWritten = Self.pairs(start, first.count, back: second, secondErrors, read, threePrime)
            reverseComplemented = Self.pairs(start, first.count, back: reverseSecond, secondErrors, read, threePrime)
        }
        if let end = Self.back(reverseFirst, firstErrors, read, threePrime) {
            if !asWritten, let start = Self.front(reverseSecond, secondErrors, read, fivePrime) {
                asWritten = Self.fits(start, reverseSecond.count, end, reverseFirst.count, read.count)
            }
            if !reverseComplemented, let start = Self.front(second, secondErrors, read, fivePrime) {
                reverseComplemented = Self.fits(start, second.count, end, reverseFirst.count, read.count)
            }
        }
        return (asWritten, reverseComplemented)
    }

    private static func pairs(
        _ start: Int, _ frontLength: Int, back: [UInt8], _ errors: Int, _ read: [UInt8], _ distance: Int
    ) -> Bool {
        guard let end = Self.back(back, errors, read, distance) else { return false }
        return fits(start, frontLength, end, back.count, read.count)
    }

    /// The front ends before the back begins, as Cutadapt searches the back of a linked line after the front.
    private static func fits(_ start: Int, _ frontLength: Int, _ end: Int, _ backLength: Int, _ readLength: Int) -> Bool {
        start + frontLength <= readLength - end - backLength
    }

    /// The least offset from the read's start, up to `distance`, at which `barcode` sits.
    private static func front(_ barcode: [UInt8], _ errors: Int, _ read: [UInt8], _ distance: Int) -> Int? {
        (0...distance).first { matches(barcode, errors, read, at: $0) }
    }

    /// The least number of bases, up to `distance`, between `barcode` and the read's end.
    private static func back(_ barcode: [UInt8], _ errors: Int, _ read: [UInt8], _ distance: Int) -> Int? {
        (0...distance).first { matches(barcode, errors, read, at: read.count - $0 - barcode.count) }
    }

    private static func matches(_ barcode: [UInt8], _ errors: Int, _ read: [UInt8], at start: Int) -> Bool {
        guard start >= 0, start + barcode.count <= read.count else { return false }
        var found = 0
        for index in barcode.indices where barcode[index] != UInt8(ascii: "N") && read[start + index] != barcode[index] {
            found += 1
            if found > errors { return false }
        }
        return true
    }
}
