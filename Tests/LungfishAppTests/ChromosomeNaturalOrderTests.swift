// ChromosomeNaturalOrderTests.swift - The first chromosome matches the natural sort without sorting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

/// Opening a bundle sorted all of its chromosomes to take the first one, 12
/// seconds for a reference of 905,628 sequences. The one-pass minimum must
/// pick the chromosome the natural sort puts first, ties included.
final class ChromosomeNaturalOrderTests: XCTestCase {
    private func chromosomes(_ names: [String]) -> [ChromosomeInfo] {
        names.map { ChromosomeInfo(name: $0, length: 10, offset: 0, lineBases: 10, lineWidth: 11) }
    }

    func testFirstChromosomeMatchesNaturalSortOrder() {
        let all = chromosomes([
            "scaffold_9", "chrM", "NC_041754.1", "chr10", "chrX", "chr2", "HG374866.9.1343",
            "MT", "chrY", "Chromosome_3", "chr1_random", "chr1", "1",
        ])
        for rotation in all.indices {
            let rotated = Array(all[rotation...] + all[..<rotation])
            XCTAssertEqual(
                firstChromosomeInNaturalOrder(rotated)?.name,
                naturalChromosomeSort(rotated).first?.name,
                "rotation \(rotation)"
            )
        }
        for names in [["contig_b", "chrX", "contig_a"], ["MT", "chrW", "Z"], ["NC_2", "NC_10", "HG1"]] {
            let unnumbered = chromosomes(names)
            XCTAssertEqual(
                firstChromosomeInNaturalOrder(unnumbered)?.name,
                naturalChromosomeSort(unnumbered).first?.name
            )
        }
        XCTAssertNil(firstChromosomeInNaturalOrder([]))
    }
}
