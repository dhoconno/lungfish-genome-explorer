// SingleCellNotHost.swift - Not-host UMIs a barcode from the SAM text samtools prints (Phase 5.2 lane RS-NOTHOST)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Gate GN counts not-host RNA a barcode (`docs/plans/2026-11-13-phase-5-rnaseq-reproduction.md:94`, ADJ-SC-3 items 1 to
// 4). A UMI is a unique (CB, UB) pair among primary alignments at NH 1 that carry both tags, kept per record, and a
// genome's figure is its unique pairs over its records, so a pair seen on two records counts once. A pair is in the
// default column when any of its alignments lies outside the extra's rRNA mask, and in the masked column otherwise, as
// `scripts/repro/rnaseq/gse296788/mtb.py` counts them. The counter reads SAM text, so its tests need no samtools, and
// `SingleCellNotHostPass` feeds it the lines of `samtools view`.

import Foundation

/// A not-host sequence record of a reference set, with its length in bases.
public struct SingleCellNotHostRecord: Sendable, Equatable {
    public var name: String
    public var length: Int

    public init(name: String, length: Int) {
        self.name = name
        self.length = length
    }
}

/// One not-host extra of a reference set as the pass counts it.
public struct SingleCellNotHostExtra: Sendable, Equatable {
    /// A named rRNA mask, the `gene_biotype "rRNA"` gene lines of a GTF the person gave for the extra.
    public struct Mask: Sendable, Equatable {
        public struct Interval: Sendable, Equatable {
            public var record: String
            /// 1-based and inclusive, as the GTF gives them.
            public var start: Int
            public var end: Int
            public var geneID: String

            public init(record: String, start: Int, end: Int, geneID: String) {
                self.record = record
                self.start = start
                self.end = end
                self.geneID = geneID
            }
        }

        public var name: String
        public var file: String
        public var sha256: String
        /// The organism the words name, such as `Mtb Erdman`.
        public var organism: String
        public var intervals: [Interval]

        public init(name: String, file: String, sha256: String, organism: String, intervals: [Interval]) {
            self.name = name
            self.file = file
            self.sha256 = sha256
            self.organism = organism
            self.intervals = intervals
        }

        /// The words of the masked column (ADJ-SC-3 item 4), never host rRNA and never another organism.
        public var maskedWords: String { "on \(organism) rRNA genes, source not resolved" }
    }

    public var name: String
    public var kind: ReferenceSetExtraKind
    public var records: [String]
    public var mask: Mask?

    public init(name: String, kind: ReferenceSetExtraKind, records: [String], mask: Mask?) {
        self.name = name
        self.kind = kind
        self.records = records
        self.mask = mask
    }

    /// What the record says of the extra's mask: the masked column's words, the words of a bacterium with no mask
    /// (BIO-NOTHOST-BARCODE item 6), or nothing for a virus or spike-in, which has no rRNA to mask.
    public var maskWords: String {
        if let mask { return mask.maskedWords }
        return kind == .bacterium ? "rRNA not masked: no annotation given for \(name)" : ""
    }
}

/// The default and masked UMIs of a barcode, each with its UMIs that have an alignment at nM 0 or 1.
public struct SingleCellNotHostCounts: Sendable, Equatable {
    public var umis: Int
    public var maskedUMIs: Int
    public var umisNM01: Int
    public var maskedUMIsNM01: Int

    public init(umis: Int = 0, maskedUMIs: Int = 0, umisNM01: Int = 0, maskedUMIsNM01: Int = 0) {
        self.umis = umis
        self.maskedUMIs = maskedUMIs
        self.umisNM01 = umisNM01
        self.maskedUMIsNM01 = maskedUMIsNM01
    }

    public var isEmpty: Bool { umis == 0 && maskedUMIs == 0 }

    mutating func add(_ bits: UInt8) {
        let near = bits & SingleCellNotHostCounter.nearBit != 0
        if bits & SingleCellNotHostCounter.outsideBit != 0 {
            umis += 1
            if near { umisNM01 += 1 }
        } else {
            maskedUMIs += 1
            if near { maskedUMIsNM01 += 1 }
        }
    }

    mutating func add(_ other: SingleCellNotHostCounts) {
        umis += other.umis
        maskedUMIs += other.maskedUMIs
        umisNM01 += other.umisNM01
        maskedUMIsNM01 += other.maskedUMIsNM01
    }
}

/// A barcode's counts by extra, over the extra's records, and by record, the records of each extra in turn.
public struct SingleCellNotHostTally: Sendable, Equatable {
    public var genome: [SingleCellNotHostCounts]
    public var records: [SingleCellNotHostCounts]
}
