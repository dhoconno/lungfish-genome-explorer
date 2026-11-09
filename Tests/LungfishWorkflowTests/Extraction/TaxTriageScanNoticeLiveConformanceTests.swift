// TaxTriageScanNoticeLiveConformanceTests.swift - Extract Reads says which BAM a name scan took for a TaxTriage sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane RIDERS-RESULT, row EXTRACT-SCAN-EXTENDED-ID (S1 by effect, BIO). A TaxTriage result that records no BAM
// path for sample S1 and holds neither of the two names the pipeline gives (`S1.bam`, `S1.S1.dwnld.references.bam`)
// has its `minimap2/` folder scanned for the one file whose name fits S1. A file such as `S1_2.bam`, which can belong
// to another sample, fits, and S1 read it with no word. The extraction now says which file the scan took, in the words
// of UX (`P4-R2-UX.md:66`), through the progress line that the CLI prints and the Operations Panel Log keeps, and in the
// extracted bundle's record.
//
// The BAM is `Tests/Fixtures/nvd/secondary-supplementary/S1.filtered.bam`, copied to `minimap2/S1_2.bam` as the only
// file of the folder. The live form uses the managed samtools (2.9 O5), and `LUNGFISH_REQUIRE_TOOLS=1` turns a missing
// samtools into a failure. The stand-in form is `TaxTriageScanNoticeTests`.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageScanNoticeLiveConformanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "TaxTriageScanNotice")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".lungfish", isDirectory: true), withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// Red at the base, where the extraction reads `S1_2.bam` and says nothing, so no progress line and no record
    /// parameter names the file.
    func testExtractReadsSaysWhichBAMTheScanTookAndRecordsIt() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let fixture = ConformanceFixtures.fixture("nvd/secondary-supplementary")
        let minimap2 = root.appendingPathComponent("minimap2", isDirectory: true)
        try FileManager.default.createDirectory(at: minimap2, withIntermediateDirectories: true)
        for (source, name) in [("S1.filtered.bam", "S1_2.bam"), ("S1.filtered.bam.bai", "S1_2.bam.bai")] {
            try FileManager.default.copyItem(
                at: fixture.appendingPathComponent(source), to: minimap2.appendingPathComponent(name)
            )
        }

        let lines = ProgressLines()
        let outcome = try await ClassifierReadResolver().resolveAndExtract(
            tool: .taxtriage, resultPath: root,
            selections: [ClassifierRowSelector(sampleId: "S1", accessions: ["SYN0001.1"])],
            options: ExtractionOptions(format: .fastq, includeUnmappedMates: false),
            destination: .bundle(
                projectRoot: root, displayName: "scan",
                metadata: ExtractionMetadata(sourceDescription: "scan", toolName: "TaxTriage", parameters: [:])
            ),
            progress: { _, message in lines.add(message) }
        )
        guard case .bundle(let bundleURL, let readCount) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertGreaterThan(readCount, 0, "the scan's BAM is read, as before")

        let sentence = "Sample S1's own BAM was not found, so Lungfish read S1_2.bam, the one file in the minimap2 folder "
            + "that fits its name. If that file belongs to another sample, put S1's own BAM back and try again."
        XCTAssertTrue(lines.all.contains(sentence), "the CLI line and the Operations Panel Log line: \(lines.all)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(
            ExtractionMetadata.self, from: Data(contentsOf: bundleURL.appendingPathComponent("extraction-metadata.json"))
        )
        XCTAssertEqual(record.parameters["classifierExtractionBAMScanNote"], sentence, "the record carries the words")
        XCTAssertTrue(
            record.sourceURLs.contains { $0.lastPathComponent == "S1_2.bam" },
            "the record's inputs name the file the scan took: \(record.sourceURLs.map(\.lastPathComponent))"
        )
    }
}

/// The progress lines of one extraction, which the resolver sends from its own task.
private final class ProgressLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func add(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
