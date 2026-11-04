// TaxTriageNotRecordedNoticeTests.swift - The viewer's notice for an import that kept no negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane TTIMPORT, row IMPORT-TAXTRIAGE-BATCH-HIDDEN, BIO-IMPORT-BATCH item 5. A result whose record lists
// no samples names no negative control anywhere, so the Contamination column reads No for every organism whether
// or not a control held it. The viewer says so above the table. A result whose record lists its samples shows no
// notice, since it knows which samples were controls.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class TaxTriageNotRecordedNoticeTests: XCTestCase {

    func testNoticeIsShownWhenTheRecordListsNoSamples() throws {
        let fixture = try Fixture(sidecar: .listingNoSamples)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        try assertNoticeSaysTheControlsWereNotRecorded(vc)
    }

    func testNoticeIsShownWhenTheResultHasNoRecord() throws {
        let fixture = try Fixture(sidecar: .missing)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        try assertNoticeSaysTheControlsWereNotRecorded(vc)
    }

    func testNoticeIsHiddenWhenTheRecordListsTheSamples() throws {
        let fixture = try Fixture(sidecar: .listing(["sample-1", "sample-2"]))
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        XCTAssertNil(vc.testControlsNotRecordedNoticeWords, "a record that lists its samples knows its controls")
    }

    // MARK: - Helpers

    private func assertNoticeSaysTheControlsWereNotRecorded(
        _ vc: TaxTriageResultViewController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let words = try XCTUnwrap(
            vc.testControlsNotRecordedNoticeWords,
            "the viewer must say the negative controls were not recorded",
            file: file,
            line: line
        )
        XCTAssertTrue(words.contains("Not recorded by this import"), words, file: file, line: line)
        XCTAssertTrue(words.contains("negative controls"), words, file: file, line: line)
        XCTAssertTrue(words.contains("may also be in a control"), words, file: file, line: line)
        XCTAssertTrue(words.contains("import it again"), words, file: file, line: line)
    }

    private struct Fixture {
        enum Sidecar {
            case missing
            case listingNoSamples
            case listing([String])
        }

        let root: URL
        let database: TaxTriageDatabase

        init(sidecar: Sidecar) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("TaxTriageNotRecordedNotice-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: [
                    Self.row(sample: "sample-1", organism: "Alpha virus", taxId: 1001),
                    Self.row(sample: "sample-2", organism: "Beta virus", taxId: 1002),
                ],
                metadata: ["tool": "taxtriage"]
            )
            let listed: [String]?
            switch sidecar {
            case .missing: listed = nil
            case .listingNoSamples: listed = []
            case .listing(let ids): listed = ids
            }
            if let listed {
                let config = TaxTriageConfig(
                    samples: listed.map {
                        TaxTriageSample(sampleId: $0, fastq1: root.appendingPathComponent("\($0).fastq.gz"))
                    },
                    outputDirectory: root
                )
                let result = TaxTriageResult(
                    config: config,
                    runtime: 61,
                    exitCode: 0,
                    outputDirectory: root,
                    reportFiles: []
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(result).write(to: root.appendingPathComponent("taxtriage-result.json"))
            }
        }

        @MainActor
        func makeController() -> TaxTriageResultViewController {
            let vc = TaxTriageResultViewController()
            vc.layoutDefaults = TestDefaultsSuite(prefix: "TaxTriageNotRecordedNoticeTests").defaults
            _ = vc.view
            vc.configureFromDatabase(database, resultURL: root)
            return vc
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(sample: String, organism: String, taxId: Int) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample,
                organism: organism,
                taxId: taxId,
                status: nil,
                tassScore: 0.9,
                readsAligned: 40,
                uniqueReads: 20,
                pctReads: nil,
                pctAlignedReads: nil,
                coverageBreadth: 50,
                meanCoverage: nil,
                meanDepth: nil,
                confidence: "High",
                k2Reads: nil,
                parentK2Reads: nil,
                giniCoefficient: nil,
                meanBaseQ: nil,
                meanMapQ: nil,
                mapqScore: nil,
                disparityScore: nil,
                minhashScore: nil,
                diamondIdentity: nil,
                k2DisparityScore: nil,
                siblingsScore: nil,
                breadthWeightScore: nil,
                hhsPercentile: nil,
                isAnnotated: nil,
                annClass: nil,
                microbialCategory: nil,
                highConsequence: nil,
                isSpecies: nil,
                pathogenicSubstrains: nil,
                sampleType: nil,
                bamPath: "\(sample)/minimap2/\(sample).bam",
                bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
                primaryAccession: "NC_\(taxId)",
                accessionLength: 10_000
            )
        }
    }
}
