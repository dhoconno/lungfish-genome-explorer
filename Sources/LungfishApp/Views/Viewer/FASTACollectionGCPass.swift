// FASTACollectionGCPass.swift - Counts the FASTA list's GC off the main thread
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Counts each record's GC for the FASTA list off the main thread (W-34).
///
/// `configure` used to count every record on the main thread, which held the app for 12 s at 20,000 records in Debug.
/// The pass runs in a detached task instead. Each start takes a new generation, so a pass for an older list never
/// delivers into a newer one, and the older task stops at its next record.
@MainActor
final class FASTACollectionGCPass {
    private var generation = 0
    private var task: Task<Void, Never>?

    isolated deinit {
        task?.cancel()
    }

    /// Starts counting `sequences` and ends any pass still running. `deliver` runs on the main actor once every record
    /// is counted, and only while no newer pass has started.
    func start(
        _ sequences: [LungfishCore.Sequence],
        deliver: @escaping @MainActor @Sendable (FASTACollectionGC.Result) -> Void
    ) {
        task?.cancel()
        generation &+= 1
        let current = generation
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let result = FASTACollectionGC.count(sequences) else { return }
            await self?.finish(result, generation: current, deliver: deliver)
        }
    }

    private func finish(
        _ result: FASTACollectionGC.Result,
        generation finished: Int,
        deliver: @MainActor (FASTACollectionGC.Result) -> Void
    ) {
        guard finished == generation else { return }
        task = nil
        deliver(result)
    }
}

/// The list's GC counts. Free of any actor, so the pass runs them off the main thread.
///
/// Every base of every nucleotide record counts (W-8). A record keeps its G+C and its A+C+G+T, in either case, and N, U or
/// any other IUPAC nucleotide code counts in neither. The bar's GC Content is the sum of G+C over the sum of A+C+G+T, so
/// a long record weighs by its length, as a GC content of the whole file does.
///
/// A record that holds a letter no nucleotide code uses (E, F, I, L, P or Q, for example), or that is declared protein, is a
/// protein record (FASTA-PROTEIN-GC). It has no GC percent and adds nothing to the bar. Counting its A, C, G and T
/// letters made a peptide read as a GC percent of alanine, cysteine, glycine and threonine.
enum FASTACollectionGC {
    /// A record's base counts.
    struct Composition: Sendable, Equatable {
        var gc = 0
        var acgt = 0
        /// False for a protein record.
        var isNucleotide = true

        /// The counts of a protein record, which has none.
        static let protein = Composition(gc: 0, acgt: 0, isNucleotide: false)

        /// The GC percent, or nil for a protein record and for a record with no A, C, G or T.
        var percent: Double? {
            isNucleotide && acgt > 0 ? Double(gc) / Double(acgt) * 100 : nil
        }

        /// The words under a GC cell that reads a dash, or nil when the cell holds a number.
        var dashToolTip: String? {
            guard percent == nil else { return nil }
            return isNucleotide
                ? "This record has no A, C, G or T to count."
                : "This record has letters that are not nucleotide codes, so it is treated as a protein record and has no GC percent."
        }

        /// What a screen reader says for a GC cell that reads a dash, or nil when the cell holds a number.
        var dashSpokenValue: String? {
            guard percent == nil else { return nil }
            return isNucleotide ? "No GC percent, no A, C, G or T" : "No GC percent, protein record"
        }
    }

    /// What a finished pass delivers.
    struct Result: Sendable {
        /// Each record's counts, keyed by sequence ID.
        let compositions: [UUID: Composition]
        /// The bar's GC Content over the nucleotide records, nil when none of them has an A, C, G or T.
        let listPercent: Double?
        /// How many records are protein records, which the bar leaves out.
        let proteinRecordCount: Int
    }

    /// Bases read at a time, so a long record never builds one huge string and a cancel ends it within a chunk.
    static let chunkLength = 1 << 20

    /// How the pass reads one byte of a record.
    private enum ByteClass {
        /// A gap, a digit, a symbol or anything else, which counts in nothing.
        case other
        /// G or C, in either case.
        case strong
        /// A or T, in either case.
        case weak
        /// N, U or another IUPAC nucleotide code, in either case, which counts in neither total.
        case nucleotideCode
        /// A letter that no nucleotide code uses, which makes the record a protein record.
        case notNucleotide
    }

    private static let byteClasses: [ByteClass] = {
        var table = [ByteClass](repeating: .other, count: 256)
        for letter in UInt8(ascii: "A")...UInt8(ascii: "Z") {
            table[Int(letter)] = .notNucleotide
            table[Int(letter) + 32] = .notNucleotide
        }
        for letter in "NURYSWKMBDHV".utf8 {
            table[Int(letter)] = .nucleotideCode
            table[Int(letter) + 32] = .nucleotideCode
        }
        for letter in "GC".utf8 {
            table[Int(letter)] = .strong
            table[Int(letter) + 32] = .strong
        }
        for letter in "AT".utf8 {
            table[Int(letter)] = .weak
            table[Int(letter) + 32] = .weak
        }
        return table
    }()

    /// Counts every record, or answers nil when the task is cancelled first. The GC Content is over the nucleotide records only.
    static func count(_ sequences: [LungfishCore.Sequence]) -> Result? {
        var compositions = [UUID: Composition](minimumCapacity: sequences.count)
        var total = Composition()
        var proteinRecordCount = 0
        for sequence in sequences {
            guard let composition = composition(of: sequence) else { return nil }
            compositions[sequence.id] = composition
            if composition.isNucleotide {
                total.gc += composition.gc
                total.acgt += composition.acgt
            } else {
                proteinRecordCount += 1
            }
        }
        return Result(compositions: compositions, listPercent: total.percent, proteinRecordCount: proteinRecordCount)
    }

    /// Counts every base of one record, or answers nil when the task is cancelled first. A protein record stops at its
    /// first letter that no nucleotide code uses.
    static func composition(of sequence: LungfishCore.Sequence) -> Composition? {
        if sequence.alphabet == .protein { return .protein }
        var counts = Composition()
        var start = 0
        repeat {
            if Task.isCancelled { return nil }
            let end = min(start + chunkLength, sequence.length)
            for byte in sequence[start..<end].utf8 {
                switch byteClasses[Int(byte)] {
                case .strong:
                    counts.gc += 1
                    counts.acgt += 1
                case .weak:
                    counts.acgt += 1
                case .notNucleotide:
                    return .protein
                case .nucleotideCode, .other:
                    break
                }
            }
            start = end
        } while start < sequence.length
        return counts
    }

    /// Whether a record with GC percent `first` sorts before one with `second`. A record with no value, a protein record or
    /// one with no A, C, G or T, sorts after every counted one whichever way the column runs, and two such records keep
    /// their order.
    static func sorts(_ first: Double?, before second: Double?, ascending: Bool) -> Bool {
        switch (first, second) {
        case let (first?, second?): return ascending ? first < second : first > second
        case (_?, nil): return true
        case (nil, _): return false
        }
    }
}
