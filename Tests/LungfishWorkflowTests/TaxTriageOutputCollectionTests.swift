// TaxTriageOutputCollectionTests.swift - Output file classification after a TaxTriage run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class TaxTriageOutputCollectionTests: XCTestCase {

    /// The retained output layout of a TaxTriage v3.3.8 sample folder.
    func testCollectorRecognizesODRAsTheOrganismReport() {
        let root = URL(fileURLWithPath: "/results/SRR12486983", isDirectory: true)
        let files = [
            "report/SRR12486983.odr.txt",
            "report/SRR12486983.odr.xlsx",
            "report/SRR12486983.odr.pdf",
            "report/all.odr.txt",
            "report/all.odr.json",
            "report/all.odr.html",
            "report/all.odr.xlsx",
            "report/multiqc_report.html",
            "report/combined_krona_kreports.html",
            "kraken2/SRR12486983.kraken2.report.txt",
            "kreport/SRR12486983.krakenreport.krona.txt",
            "top/SRR12486983.top_report.tsv",
            "combine/SRR12486983.combined.gcfmap.tsv",
            "alignment/SRR12486983.paths.json",
            "trace.txt",
        ].map { root.appendingPathComponent($0) }

        let categorized = TaxTriagePipeline.categorizeOutputFiles(files)

        XCTAssertEqual(
            categorized.reportFiles.map(\.lastPathComponent),
            ["SRR12486983.odr.txt"],
            "the per-sample ODR is the organism report; Kraken2/top/combined files are not"
        )
        XCTAssertEqual(
            categorized.kronaFiles.map(\.lastPathComponent),
            ["combined_krona_kreports.html"]
        )
        XCTAssertEqual(
            categorized.metricsFiles.map(\.lastPathComponent),
            ["SRR12486983.combined.gcfmap.tsv"]
        )
    }

    func testCollectorKeepsOlderOrganismReportName() {
        let root = URL(fileURLWithPath: "/results/S1", isDirectory: true)
        let files = [
            "report/S1.organisms.report.txt",
            "report/multiqc_data/multiqc_confidences.txt",
        ].map { root.appendingPathComponent($0) }

        let categorized = TaxTriagePipeline.categorizeOutputFiles(files)
        XCTAssertEqual(categorized.reportFiles.map(\.lastPathComponent), ["S1.organisms.report.txt"])
        XCTAssertEqual(categorized.metricsFiles.map(\.lastPathComponent), ["multiqc_confidences.txt"])
    }
}
