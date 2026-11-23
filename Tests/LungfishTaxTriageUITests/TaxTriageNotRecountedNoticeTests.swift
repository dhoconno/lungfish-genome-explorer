// TaxTriageNotRecountedNoticeTests.swift - What the viewer says about rows a rebuild did not recount
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane TT-m1b, Finding 1 of TT-m1. Since TT-m1, a rebuild of a result whose report for a sample is gone keeps
// that sample's rows from the earlier taxtriage.sqlite and names the sample in the metadata key
// `not_recounted_samples`, a JSON array (`BuildDbCommand.TaxTriageSubcommand.notRecountedSamplesMetadataKey`). Before
// TT-m1 the app showed no rows for such a result. Now it shows them as current, and a database built before 3.2
// TTREADS may have counted a segmented virus's Reads on its first reference only, so the strip above the table names
// the samples and says what to do.

import XCTest
import AppKit
@testable import LungfishTaxTriageUI
@testable import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

@MainActor
final class TaxTriageNotRecountedNoticeTests: XCTestCase {

    /// One carried sample: the strip says only this line, since the run's control ran.
    func testViewerNamesTheSampleARebuildDidNotRecount() throws {
        let fixture = try Fixture(notRecounted: "[\"SRR35517702\"]")
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing about rows it did not recount")
        XCTAssertEqual(
            words,
            "Lungfish could not recount SRR35517702 because its report is missing from this result. "
                + "Its counts are from an earlier build, which may have counted a segmented virus's Reads on its first reference only. "
                + "To recount it, import the original TaxTriage run folder again, if you still have it."
        )
    }

    /// Two carried samples, in a result whose import recorded no samples: the line comes first, then the import's words.
    func testViewerNamesEverySampleNotRecountedAboveTheImportWords() throws {
        let fixture = try Fixture(notRecounted: "[\"SRR1\",\"SRR2\"]", writesSidecar: false)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        let words = try XCTUnwrap(vc.testControlsNotRecordedNoticeWords, "the viewer said nothing")
        XCTAssertEqual(
            words,
            "Lungfish could not recount SRR1 and SRR2 because their reports are missing from this result. "
                + "Their counts are from an earlier build, which may have counted a segmented virus's Reads on its first reference only. "
                + "To recount them, import the original TaxTriage run folder again, if you still have it.\n"
                + TaxTriageNotRecordedNoticeView.words
        )
    }

    /// A build that carried nothing writes no key, and the strip stays shut.
    func testViewerSaysNothingWhenARebuildCarriedNoRows() throws {
        let fixture = try Fixture(notRecounted: nil)
        defer { fixture.cleanUp() }
        let vc = fixture.makeController()

        XCTAssertNil(vc.testControlsNotRecordedNoticeWords)
    }

    // MARK: - Helpers

    private struct Fixture {
        let root: URL
        let database: TaxTriageDatabase

        /// The database holds Alpha virus for sample-1 and SRR35517702. `notRecounted` is the value of the
        /// `not_recounted_samples` key, none when nil. The sidecar lists both samples and the control NTC1, which ran and
        /// holds nothing, so the control needs no words.
        init(notRecounted: String?, writesSidecar: Bool = true) throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory
                .appendingPathComponent("TaxTriageNotRecountedNotice-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            var metadata = ["tool": "taxtriage"]
            if let notRecounted { metadata["not_recounted_samples"] = notRecounted }
            database = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"),
                rows: ["sample-1", "SRR35517702"].map(Self.row(sample:)),
                metadata: metadata
            )
            guard writesSidecar else { return }
            let listed = [("sample-1", false), ("SRR35517702", false), ("NTC1", true)]
            let config = TaxTriageConfig(
                samples: listed.map {
                    TaxTriageSample(sampleId: $0.0, fastq1: root.appendingPathComponent("\($0.0).fastq.gz"), isNegativeControl: $0.1)
                },
                outputDirectory: root
            )
            try TaxTriageResult(config: config, runtime: 61, exitCode: 0, outputDirectory: root).save()
        }

        @MainActor
        func makeController() -> TaxTriageResultViewController {
            let vc = TaxTriageResultViewController()
            vc.layoutDefaults = TestDefaultsSuite(prefix: "TaxTriageNotRecountedNoticeTests").defaults
            _ = vc.view
            vc.configureFromDatabase(database, resultURL: root)
            return vc
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func row(sample: String) -> TaxTriageTaxonomyRow {
            TaxTriageTaxonomyRow(
                sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
                uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil, meanDepth: nil,
                confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
                mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil, k2DisparityScore: nil,
                siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil, isAnnotated: nil, annClass: nil,
                microbialCategory: nil, highConsequence: nil, isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
                bamPath: "\(sample)/minimap2/\(sample).bam", bamIndexPath: "\(sample)/minimap2/\(sample).bam.bai",
                primaryAccession: "NC_1001", accessionLength: 10_000
            )
        }
    }
}
