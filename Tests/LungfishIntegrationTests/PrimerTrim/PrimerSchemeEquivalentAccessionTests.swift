// PrimerSchemeEquivalentAccessionTests.swift - End-to-end equivalent-accession BED rewrite
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// Uses the shipped QIASeqDIRECT-SARS2 bundle (canonical MN908947.3,
/// equivalent NC_045512.2) to exercise the resolver's equivalent-accession
/// BED rewrite at full integration scale.
///
/// Complements the narrower `PrimerSchemeResolverTests` coverage, which
/// exercises a hand-rolled miniature bundle, by confirming the rewrite works
/// against the real ~560-row shipped BED. The pipeline-driven version
/// of this test — which would synthesize a BAM anchored to NC_045512.2 — is
/// omitted per the plan's allowance; the resolver contract is the load-bearing
/// piece and the pipeline already consumes the rewritten BED through the same
/// API exercised here.
final class PrimerSchemeEquivalentAccessionTests: XCTestCase {
    func testResolverRewritesCanonicalToEquivalentAgainstShippedBundle() throws {
        let scheme = try PrimerSchemeBundle.load(from: TestFixtures.qiaseqDirectSARS2.bundleURL)

        let resolved = try PrimerSchemeResolver.resolve(
            bundle: scheme,
            targetReferenceName: "NC_045512.2"
        )
        XCTAssertTrue(resolved.isRewritten, "resolver must produce a rewritten BED when the target is an equivalent accession")
        addTeardownBlock {
            if resolved.isRewritten {
                try? FileManager.default.removeItem(at: resolved.bedURL)
            }
        }

        // Every non-empty row's first column must be the new name, not the canonical.
        let content = try String(contentsOf: resolved.bedURL, encoding: .utf8)
        var rowsChecked = 0
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let col1 = String(line[..<tab])
            XCTAssertEqual(col1, "NC_045512.2",
                           "rewritten BED must anchor to NC_045512.2 (found \(col1) on line \(rowsChecked + 1))")
            rowsChecked += 1
        }
        // Sanity: we actually processed the shipped BED, not a trivially empty one.
        XCTAssertGreaterThan(rowsChecked, 500,
                             "shipped QIASeq BED should carry >500 primers; rewrite produced \(rowsChecked) rows")
    }

    func testResolverOriginalBEDStillHasCanonicalAccession() throws {
        // The rewrite must not mutate the shipped BED on disk; it emits a temp file.
        let scheme = try PrimerSchemeBundle.load(from: TestFixtures.qiaseqDirectSARS2.bundleURL)
        let originalContent = try String(contentsOf: scheme.bedURL, encoding: .utf8)
        let firstRow = originalContent.split(separator: "\n").first ?? ""
        let col1 = firstRow.split(separator: "\t").first.map(String.init) ?? ""
        XCTAssertEqual(col1, "MN908947.3")
    }
}
