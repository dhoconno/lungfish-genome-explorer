// TaxTriageScanNoticeTests.swift - The words and the record of a BAM that a name scan took for a TaxTriage sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane RIDERS-RESULT, row EXTRACT-SCAN-EXTENDED-ID (S1 by effect, BIO). With no recorded path and neither
// pipeline name present, the scan of `minimap2/` fits one file such as `S1_2.bam` to sample `S1`, which can be another
// sample's file. The extraction says which file it took and records the words. This is the stand-in form, on files
// that hold no reads, of the live form `TaxTriageScanNoticeLiveConformanceTests`, which runs the managed samtools.

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageScanNoticeTests: XCTestCase {

    private static let sentence = "Sample S1's own BAM was not found, so Lungfish read S1_2.bam, the one file in the "
        + "minimap2 folder that fits its name. If that file belongs to another sample, put S1's own BAM back and try again."

    /// A result folder whose `minimap2/` holds only the named files.
    private func makeResult(placing names: [String]) throws -> URL {
        let root = try TestTempDirectory.make(prefix: "TaxTriageScanNotice")
        let minimap2 = root.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2, withIntermediateDirectories: true)
        for name in names {
            try Data("BAM".utf8).write(to: minimap2.appendingPathComponent(name))
        }
        return root
    }

    private func locate(sample: String, in root: URL) async throws -> URL {
        try await ClassifierReadResolver().testingResolveBAMURL(tool: .taxtriage, sampleId: sample, resultPath: root)
    }

    /// The scan fixture of the row, with only `S1_2.bam` present. Red at the base, which has no notice to ask for.
    func testTheScanSaysWhichFileItTookForASampleWithNoBAMOfItsOwn() async throws {
        let root = try makeResult(placing: ["S1_2.bam"])
        defer { TestTempDirectory.cleanup(root) }
        let bam = try await locate(sample: "S1", in: root)
        XCTAssertEqual(bam.lastPathComponent, "S1_2.bam", "the scan takes the one file that fits, as before")
        XCTAssertEqual(
            ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1", resultPath: root, bam: bam),
            Self.sentence
        )
        XCTAssertNil(
            ClassifierReadResolver.taxTriageScanNotice(tool: .esviritu, sampleId: "S1", resultPath: root, bam: bam),
            "only a TaxTriage lookup scans"
        )
        XCTAssertNil(
            ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: nil, resultPath: root, bam: bam),
            "a result with no sample id has no sample to name"
        )
    }

    /// A sample whose own BAM is there, under either name the pipeline gives, reads it and is told nothing.
    func testASampleThatHasABAMOfItsOwnGetsNoNotice() async throws {
        for names in [["S1.bam", "S1_2.bam"], ["S1.S1.dwnld.references.bam", "S1_2.bam"]] {
            let root = try makeResult(placing: names)
            defer { TestTempDirectory.cleanup(root) }
            let bam = try await locate(sample: "S1", in: root)
            XCTAssertNotEqual(bam.lastPathComponent, "S1_2.bam", "\(names): the sample's own BAM is read")
            XCTAssertNil(
                ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1", resultPath: root, bam: bam),
                "\(names)"
            )
        }
    }

    /// The words reach the record that the extraction writes, a bundle's parameters, and the other parameters stay.
    func testTheNoticeReachesTheRecordOfAnExtractedBundle() {
        let destination = ExtractionDestination.bundle(
            projectRoot: URL(fileURLWithPath: "/tmp/scan-project"), displayName: "scan",
            metadata: ExtractionMetadata(sourceDescription: "scan", toolName: "TaxTriage", parameters: ["sample": "S1"])
        )
        let recorded = ClassifierReadResolver.recordingBAMScanNotes(
            [Self.sentence], in: destination, options: ExtractionOptions()
        )
        guard case .bundle(_, _, let metadata) = recorded.destination else { return XCTFail("\(recorded.destination)") }
        XCTAssertEqual(metadata.parameters["classifierExtractionBAMScanNote"], Self.sentence)
        XCTAssertEqual(metadata.parameters["sample"], "S1", "the parameters the extraction already records stay")

        let plain = ClassifierReadResolver.recordingBAMScanNotes([], in: destination, options: ExtractionOptions())
        guard case .bundle(_, _, let unchanged) = plain.destination else { return XCTFail("\(plain.destination)") }
        XCTAssertNil(unchanged.parameters["classifierExtractionBAMScanNote"], "an extraction with no scan records no note")
    }
}
