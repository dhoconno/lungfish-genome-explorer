// ReferenceBundleRecordTableTests.swift - The record table's sequence order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import XCTest
import LungfishCore
@testable import LungfishApp

/// SplitMix64, so the shuffled names of a failing run come back on any machine.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

@MainActor
final class ReferenceBundleRecordTableTests: XCTestCase {

    /// Sequence names in an order no sort produces. They mix chromosome, RefSeq,
    /// GenBank, scaffold and contig styles, numbers with and without leading zeros,
    /// names that differ only in case or punctuation, and two rows for `chr1` from
    /// different samples, which compare equal and so keep this input order.
    private static let input: [(name: String, sample: String?)] = [
        ("chr10", nil), ("HG374866.9.1343", nil), ("chr2", nil), ("NC_041754.1", nil),
        ("scaffold_10", nil), ("chrX", nil), ("contig.1", nil), ("HG374866.10.1", nil),
        ("chr1", "S2"), ("NC_041754.10", nil), ("Scaffold_3", nil), ("contig_1", nil),
        ("chrM", nil), ("10", nil), ("NW_021160018.1", nil), ("contig-1", nil),
        ("HG374866.9.200", nil), ("chr1", "S1"), ("2", nil), ("chr1_KI270706v1_random", nil),
        ("NC_041755.1", nil), ("contig1", nil), ("chrUn_GL000220v1", nil), ("01", nil),
        ("scaffold_2", nil), ("MT", nil), ("1", nil), ("NC_041754.2", nil), ("mt", nil), ("chrY", nil),
    ]

    private func makeTable() -> ReferenceBundleRecordTable {
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let rows = Self.input.enumerated().map { position, entry in
            ReferenceBundleRecordRow(
                summary: BundleBrowserSequenceSummary(
                    name: entry.name,
                    displayDescription: nil,
                    length: Int64(100 + position),
                    aliases: [],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                ),
                values: [:],
                sampleID: entry.sample
            )
        }
        table.configure(dynamicFields: [], rows: rows)
        return table
    }

    /// Each displayed row as its sequence name, with the sample after `@` when it has one.
    private func displayedLabels(_ table: ReferenceBundleRecordTable) -> [String] {
        table.displayedRows.map { row in
            row.sampleID.map { "\(row.summary.name)@\($0)" } ?? row.summary.name
        }
    }

    /// Frozen at 65539ddcd, before the sequence column gained presort keys. The
    /// column sorts with `localizedStandardCompare`, so these orders are the ones the
    /// table showed then, ascending, descending and after a filter.
    func testSequenceSortOrderUnchanged() {
        let table = makeTable()
        XCTAssertEqual(displayedLabels(table), [
            "1", "01", "2", "10", "chr1@S2", "chr1@S1", "chr1_KI270706v1_random", "chr2", "chr10",
            "chrM", "chrUn_GL000220v1", "chrX", "chrY", "contig_1", "contig-1", "contig.1", "contig1",
            "HG374866.9.200", "HG374866.9.1343", "HG374866.10.1", "mt", "MT", "NC_041754.1",
            "NC_041754.2", "NC_041754.10", "NC_041755.1", "NW_021160018.1", "scaffold_2", "Scaffold_3",
            "scaffold_10",
        ])

        table.tableView.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
        XCTAssertEqual(displayedLabels(table), [
            "scaffold_10", "Scaffold_3", "scaffold_2", "NW_021160018.1", "NC_041755.1", "NC_041754.10",
            "NC_041754.2", "NC_041754.1", "MT", "mt", "HG374866.10.1", "HG374866.9.1343",
            "HG374866.9.200", "contig1", "contig.1", "contig-1", "contig_1", "chrY", "chrX",
            "chrUn_GL000220v1", "chrM", "chr10", "chr2", "chr1_KI270706v1_random", "chr1@S2", "chr1@S1",
            "10", "2", "01", "1",
        ])

        table.tableView.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: true)]
        table.setFilterText("NC_")
        XCTAssertEqual(displayedLabels(table), ["NC_041754.1", "NC_041754.2", "NC_041754.10", "NC_041755.1"])
    }

    /// The sequence column's presort keys order distinct reference names as the
    /// comparator does, so a large table needs about one comparator call per row.
    /// Names that differ only in case or leading zeros are left out, the keys tie
    /// them, and the frozen test above shows the comparator still orders them.
    func testPresortKeysOrderReferenceNamesAsTheComparatorDoes() {
        let names = [
            "chr10", "HG374866.9.1343", "chr2", "NC_041754.1", "scaffold_10", "chrX", "contig.1",
            "HG374866.10.1", "chr1", "NC_041754.10", "Scaffold_3", "contig_1", "chrM", "10",
            "NW_021160018.1", "contig-1", "HG374866.9.200", "2", "chr1_KI270706v1_random", "NC_041755.1",
            "contig1", "chrUn_GL000220v1", "scaffold_2", "MT", "1", "NC_041754.2", "chrY",
            "seq|gi|1234|ref", "chr3:1-200", "contig 7", "Contig~2", "U00096.3",
        ]
        let keys = ReferenceSequenceSortKey.keys(for: names)
        let byKey = names.indices.sorted { keys[$0] < keys[$1] }.map { names[$0] }
        XCTAssertEqual(byKey, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(keys).count, names.count, "Distinct names get distinct keys")
    }

    /// Five alphabets that stress the keys: letters with digits and common punctuation, upper and
    /// lower case with digit runs, chromosome-like names, spaces with heavy ASCII punctuation, and
    /// a non-ASCII letter. Names drawn from them tie on case, on leading zeros and on repeats.
    private static let alphabets: [[Character]] = [
        Array("abcXYZ019_.-"),
        Array("aAbB0123456789"),
        Array("chrCHR0123_.|:-"),
        Array("ab0 1/!$~`^+=<>{}[]()'\"@*\\&#%?;,"),
        Array("ab01\u{E9}"),
    ]

    private static func randomName(from alphabet: [Character], using generator: inout SplitMix64) -> String {
        let length = 1 + Int(generator.next() % 8)
        return String((0..<length).map { _ in alphabet[Int(generator.next() % UInt64(alphabet.count))] })
    }

    /// One row per name, with the sample `S<position>` so rows of equal name stay apart.
    private func makeRows(names: [String]) -> [ReferenceBundleRecordRow] {
        names.enumerated().map { position, name in
            ReferenceBundleRecordRow(
                summary: BundleBrowserSequenceSummary(
                    name: name,
                    displayDescription: nil,
                    length: Int64(100 + position),
                    aliases: [],
                    isPrimary: true,
                    isMitochondrial: false,
                    metrics: nil
                ),
                values: [:],
                sampleID: "S\(position)"
            )
        }
    }

    /// The pairs `(summary.name, sampleID)` of `rows`, in order, as one string each.
    private func pairs(_ rows: [ReferenceBundleRecordRow]) -> [String] {
        rows.map { "\($0.summary.name)@\($0.sampleID ?? "")" }
    }

    /// The order the table shows, ascending and descending, is the order the plain stable sort by
    /// the table's own comparator gives, on shuffled names with repeats. The expected rows come from
    /// the comparator, so the test holds on any locale and pins no order by hand.
    func testSequenceSortMatchesTheComparatorOnSeededNames() {
        var generator = SplitMix64(seed: 42)

        for (alphabetIndex, alphabet) in Self.alphabets.enumerated() {
            for round in 0..<10 {
                let count = 50 + Int(generator.next() % 151)
                var names = (0..<count).map { _ in Self.randomName(from: alphabet, using: &generator) }
                for _ in 0..<(count / 10) {
                    names.append(names[Int(generator.next() % UInt64(names.count))])
                }
                names.shuffle(using: &generator)

                let rows = makeRows(names: names)
                let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
                table.configure(dynamicFields: [], rows: rows)
                let ascendingRows = table.displayedRows
                table.tableView.sortDescriptors = [NSSortDescriptor(key: "sequence", ascending: false)]
                let descendingRows = table.displayedRows

                for (ascending, displayed) in [(true, ascendingRows), (false, descendingRows)] {
                    let expected = rows.sorted { table.compareRows($0, $1, by: "sequence", ascending: ascending) }
                    XCTAssertEqual(
                        pairs(displayed),
                        pairs(expected),
                        "alphabet \(alphabetIndex) round \(round) \(ascending ? "ascending" : "descending")"
                    )
                }
            }
        }
    }
}
