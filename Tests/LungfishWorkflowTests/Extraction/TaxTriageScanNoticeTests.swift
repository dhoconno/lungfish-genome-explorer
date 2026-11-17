// TaxTriageScanNoticeTests.swift - The words and the record of a BAM that a name scan took for a TaxTriage sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 4 lane RIDERS-RESULT, row EXTRACT-SCAN-EXTENDED-ID (S1 by effect, BIO). With no recorded path and neither
// pipeline name present, the scan of `minimap2/` fits one file such as `S1_2.bam` to sample `S1`, which can be another
// sample's file. The extraction says which file it took and records the words. This is the stand-in form, on files
// that hold no reads, of the live form `TaxTriageScanNoticeLiveConformanceTests`, which runs the managed samtools.
//
// S1 sweep 2026-11-17, lane EXTRACT-SAMPLELIST (BIO-THREE-ROWS items 5 to 7 and section 2). A result that lists its
// samples, in its database, its `samplesheet.csv` or its run's `taxtriage-result.json`, gives no sample a file whose name
// also fits a longer sample id of that list, so S1 never reads S1_2's or S1.5's reads. A result with no list keeps the
// scan's take and words.

import XCTest
import LungfishIO
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

    // MARK: - A result that lists its samples (EXTRACT-SAMPLELIST)

    /// BIO-THREE-ROWS item 6. A result that names S1 beside S1_2, with only `minimap2/S1_2.bam`, gives S1 no BAM, so the
    /// extraction ends in the missing-BAM refusal and no notice names the file. Each of the three lists is enough alone.
    /// Red at the base, where the scan takes `S1_2.bam` for S1.
    func testS1TakesNoFileOfS1_2WhenTheResultListsBoth() async throws {
        try await assertS1TakesNoFile(of: "S1_2", named: "S1_2.bam")
    }

    /// The same for S1 beside S1.5, with only `minimap2/S1.5.dedup.bam`. Red at the base, where the scan takes it for S1.
    func testS1TakesNoFileOfS1_5WhenTheResultListsBoth() async throws {
        try await assertS1TakesNoFile(of: "S1.5", named: "S1.5.dedup.bam")
    }

    /// For each list, a result that names S1 and `other`, with only `file` in `minimap2/`, gives S1 no BAM.
    private func assertS1TakesNoFile(of other: String, named file: String) async throws {
        for source in SampleList.allCases {
            let root = try makeResult(placing: [file])
            defer { TestTempDirectory.cleanup(root) }
            try list(["S1", other], as: source, in: root)
            try await assertNoBAM(forS1In: root, theirs: file, "\(file), \(source)")
        }
    }

    /// The samplesheet and the run's sidecar keep the name a person typed, such as `S1 2`, and the pipeline writes its
    /// files as `S1_2` (``TaxTriageSample/pipelineName(of:)``), so the list counts both. Red at the base.
    func testATypedNameOfTheListCountsAsTheNameThePipelineGivesIt() async throws {
        for source in [SampleList.samplesheet, .runSidecar] {
            let root = try makeResult(placing: ["S1_2.bam"])
            defer { TestTempDirectory.cleanup(root) }
            try list(["S1", "S1 2"], as: source, in: root)
            try await assertNoBAM(forS1In: root, theirs: "S1_2.bam", "\(source)")
        }
    }

    /// The green pin of item 6. The longer samples of the list keep their files. S1_2 reads `S1_2.bam` by its own name
    /// with no notice, and S1.5, whose own two names are missing, reads `S1.5.dedup.bam` by the scan, which says so as
    /// before. S1, whose two fits both belong to longer samples, has none.
    func testTheLongerSamplesOfTheListKeepTheirOwnFiles() async throws {
        for source in SampleList.allCases {
            let root = try makeResult(placing: ["S1_2.bam", "S1.5.dedup.bam"])
            defer { TestTempDirectory.cleanup(root) }
            try list(["S1", "S1_2", "S1.5"], as: source, in: root)
            let own = try await locate(sample: "S1_2", in: root)
            XCTAssertEqual(own.lastPathComponent, "S1_2.bam", "\(source)")
            XCTAssertNil(
                ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1_2", resultPath: root, bam: own),
                "\(source)"
            )
            let scanned = try await locate(sample: "S1.5", in: root)
            XCTAssertEqual(scanned.lastPathComponent, "S1.5.dedup.bam", "\(source)")
            XCTAssertEqual(
                ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1.5", resultPath: root, bam: scanned),
                "Sample S1.5's own BAM was not found, so Lungfish read S1.5.dedup.bam, the one file in the minimap2 folder "
                    + "that fits its name. If that file belongs to another sample, put S1.5's own BAM back and try again.",
                "\(source)"
            )
        }
    }

    /// Where a result lists its samples (BIO-THREE-ROWS item 5).
    private enum SampleList: CaseIterable {
        /// The samples of `taxtriage.sqlite`, here a database whose build recorded no BAM for any sample.
        case database
        /// The `samplesheet.csv` that LGE writes into a run's folder.
        case samplesheet
        /// The samples of the run's `taxtriage-result.json`.
        case runSidecar
    }

    /// Writes `samples` into the result `root` as `source` lists them, each by the writer LGE uses for it.
    private func list(_ samples: [String], as source: SampleList, in root: URL) throws {
        let typed = samples.map {
            TaxTriageSample(sampleId: $0, fastq1: URL(fileURLWithPath: "/reads/\($0)_R1.fastq.gz"))
        }
        switch source {
        case .database:
            _ = try TaxTriageDatabase.create(
                at: root.appendingPathComponent("taxtriage.sqlite"), rows: samples.map(Self.row(sample:)),
                metadata: ["tool": "TaxTriage", TaxTriageDatabase.fittedBAMSamplesMetadataKey: "[]"]
            )
        case .samplesheet:
            try TaxTriageSamplesheetBuilder().write(typed, to: root.appendingPathComponent("samplesheet.csv"))
        case .runSidecar:
            let config = TaxTriageConfig(samples: typed, outputDirectory: root)
            try TaxTriageResult(config: config, runtime: 1, exitCode: 0, outputDirectory: root).save()
        }
    }

    /// Sample S1 of `root` has no BAM, by the candidates, the lookup and both notices, and `theirs` is not read.
    private func assertNoBAM(forS1In root: URL, theirs: String, _ label: String) async throws {
        let candidates = try ClassifierReadResolver.taxTriageBAMCandidates(sampleId: "S1", resultDir: root)
        XCTAssertEqual(
            candidates.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent), [],
            "\(label): no file of S1's candidates exists"
        )
        do {
            let bam = try await locate(sample: "S1", in: root)
            XCTFail("\(label): S1 has no BAM of its own, but \(bam.lastPathComponent) was read")
        } catch ClassifierExtractionError.bamNotFound(let sample) {
            XCTAssertEqual(sample, "S1", label)
        }
        let file = root.appendingPathComponent("minimap2/\(theirs)")
        XCTAssertNil(
            ClassifierReadResolver.taxTriageScanNotice(tool: .taxtriage, sampleId: "S1", resultPath: root, bam: file), label
        )
        XCTAssertNil(ClassifierReadResolver.taxTriageRecordedBAMNotice(sampleId: "S1", resultPath: root, bam: file), label)
    }

    /// One row of `sample` that records no BAM.
    private static func row(sample: String) -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: sample, organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: nil, bamIndexPath: nil, primaryAccession: "NC_1001", accessionLength: 10_000
        )
    }
}
