// BundleDataProviderLookupTests.swift - Which chromosome a name finds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore
@testable import LungfishOperations

@MainActor
final class BundleDataProviderLookupTests: XCTestCase {

    private func provider(chromosomes: [ChromosomeInfo]?) -> BundleDataProvider {
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Lookup",
            identifier: "test.chromosome-lookup",
            source: SourceInfo(organism: "Test", assembly: "test"),
            genome: chromosomes.map {
                GenomeInfo(path: "s.fa.gz", indexPath: "s.fa.gz.fai", totalLength: 1_000, chromosomes: $0)
            },
            annotations: [],
            variants: []
        )
        return BundleDataProvider(bundleURL: URL(fileURLWithPath: "/nonexistent/lookup.lungfishref"), manifest: manifest)
    }

    /// Each chromosome's length is its position plus one, so a length names the match.
    private func chromosome(
        _ name: String,
        length: Int64,
        aliases: [String] = [],
        description: String? = nil
    ) -> ChromosomeInfo {
        ChromosomeInfo(
            name: name,
            length: length,
            offset: 0,
            lineBases: 60,
            lineWidth: 61,
            aliases: aliases,
            fastaDescription: description
        )
    }

    /// Frozen at 65539ddcd, before `chromosomeInfo(named:)` kept a name index. A name
    /// finds the first chromosome with that name or alias, so an earlier alias wins
    /// over a later name. Other names go through `mapVCFChromosomes`, whose answer is
    /// the first chromosome with the mapped name.
    func testChromosomeInfoNamedReturnsTheBaseResultForPresentAndMissingNames() {
        let lookup = provider(chromosomes: [
            chromosome("NC_000001.11", length: 1, aliases: ["chr1", "1"]),
            chromosome("seqA", length: 2, aliases: ["chrA"]),
            chromosome("chrA", length: 3),
            chromosome("dup", length: 4),
            chromosome("dup", length: 5),
            chromosome("MN908947", length: 6),
            chromosome("chr7", length: 7),
            chromosome("scaffold9", length: 8, aliases: ["chr9"]),
            chromosome("chr9", length: 9),
            chromosome("NC_041765.1", length: 10, description: "Macaca mulatta chromosome 12"),
        ])
        let expectations: [(name: String, length: Int64?)] = [
            ("NC_000001.11", 1), ("chr1", 1), ("1", 1),
            ("seqA", 2), ("chrA", 2),
            ("dup", 4),
            ("MN908947", 6), ("MN908947.3", 6),
            ("chr7", 7), ("7", 7),
            ("scaffold9", 8), ("chr9", 8), ("9", 9),
            ("NC_041765.1", 10), ("12", 10),
            ("chrZ", nil), ("CHR1", nil), ("chr12", nil), ("NC_000001", nil), ("", nil),
        ]
        for expectation in expectations {
            XCTAssertEqual(
                lookup.chromosomeInfo(named: expectation.name)?.length,
                expectation.length,
                "chromosomeInfo(named: \"\(expectation.name)\")"
            )
        }
        XCTAssertNil(provider(chromosomes: nil).chromosomeInfo(named: "chr1"))
        XCTAssertNil(provider(chromosomes: []).chromosomeInfo(named: "chr1"))
    }
}
