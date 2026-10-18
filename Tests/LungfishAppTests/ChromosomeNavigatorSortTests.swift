// ChromosomeNavigatorSortTests.swift - Natural chromosome order
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
@testable import LungfishApp

final class ChromosomeNavigatorSortTests: XCTestCase {

    /// Names in an order no sort produces. They cover numbered, sex and mitochondrial
    /// chromosomes under several prefixes, and unplaced scaffolds that sort by name.
    private let names = [
        "chr10", "scaffold_2", "chrM", "chr2", "Chromosome_X", "chrY", "MT", "chr1",
        "chrUn_KI270302v1", "3", "chr1_KI270706v1_random", "chrZ", "chrW", "NC_041754.1", "CHR4", "chrX",
    ]

    private func chromosomes() -> [ChromosomeInfo] {
        names.enumerated().map { position, name in
            ChromosomeInfo(name: name, length: Int64(1_000 + position), offset: 0, lineBases: 60, lineWidth: 61)
        }
    }

    /// Frozen at 65539ddcd, before the sort built each key once. Equal keys, such as
    /// `Chromosome_X` and `chrX`, keep their input order.
    func testNaturalSortOrderUnchanged() {
        XCTAssertEqual(naturalChromosomeSort(chromosomes()).map(\.name), [
            "chr1", "chr2", "3", "CHR4", "chr10", "Chromosome_X", "chrX", "chrY", "chrW", "chrZ",
            "chrM", "MT", "NC_041754.1", "chr1_KI270706v1_random", "chrUn_KI270302v1", "scaffold_2",
        ])
    }
}
