// MetagenomicsImportRecordFactsTests.swift - The sample names a classifier result import records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04, finding 4 of its review (BIO 4 and 5). A record names the samples a result holds and no
// name that is not a sample, so the combined multi-sample TaxTriage report is no sample and a result whose files
// carry no sample id has no `sampleNames` at all, which the record then reads as Not recorded.

import Foundation
import XCTest
@testable import LungfishWorkflow

final class MetagenomicsImportRecordFactsTests: XCTestCase {
    private func inputs(_ paths: [String]) -> [ProvenanceFileDescriptor] {
        paths.map { ProvenanceFileDescriptor(path: $0, format: .unknown, role: .input) }
    }

    func testTaxTriageSampleNamesSkipTheCombinedReport() {
        let files = inputs([
            "/s/report/all.odr.txt",
            "/s/report/S1.2024.odr.txt",
            "/s/top/S1.2024.top_report.tsv",
            "/s/combine/SRR35517702.combined.gcfmap.tsv",
        ])
        XCTAssertEqual(
            MetagenomicsImportRecordFacts.sampleNames(kind: .taxtriage, source: URL(fileURLWithPath: "/s"), inputs: files),
            ["S1.2024", "SRR35517702"],
            "the combined report all.odr.txt names no sample"
        )
    }

    func testAnEsVirituFileWithNoSampleIdRecordsNoSampleNames() {
        let facts = MetagenomicsImportRecordFacts.resolvedDefaults(
            kind: .esviritu,
            sourceURLs: [URL(fileURLWithPath: "/s")],
            inputs: inputs(["/s/detected_virus.info.tsv"])
        )
        XCTAssertNil(facts["sampleNames"], "no sample id in a file name reads Not recorded, not an empty list")
    }
}
