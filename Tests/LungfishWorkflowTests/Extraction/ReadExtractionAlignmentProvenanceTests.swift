// ReadExtractionAlignmentProvenanceTests.swift - An alignment mapped from placeholder reads names the bundle of its reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane FLUIDIGM-3, review FLUIDIGM-BIO B1 (ruling BIO-FLUIDIGM-CHILDREN item 7). Mapping keeps the FASTQ quality string, so
// the BAM of mapped Fluidigm reads holds `I` on every base, and a bundle extracted from it opened with Mean Q 40.0 and no
// mark. `ReadExtractionService.placeholderScoreSourceName(ofAlignment:)` reads the mapping record beside the alignment and
// names the bundle of placeholder reads it was mapped from, which `lungfish extract reads` then refuses (the command's own
// case is `ExtractReadsPlaceholderAlignmentRefusalTests` in LungfishCLITests, since the command is in that module).

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ReadExtractionAlignmentProvenanceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "alignment-provenance")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// The record names the payload file of the bundle, which is what the mapper ran on for a bundle with one payload file.
    /// Controls: a bundle with no mark, and an alignment with no mapping record, both give nil.
    func testAnAlignmentMappedFromPlaceholderReadsNamesItsSourceBundle() throws {
        let counted = try makeBundle(named: "counted", placeholders: true)
        let measured = try makeBundle(named: "measured", placeholders: false)

        let fromCounted = try makeAlignment(
            named: "from-counted", mapperRanOn: [counted.appendingPathComponent("reads.fastq")], inputRecords: []
        )
        XCTAssertEqual(
            ReadExtractionService.placeholderScoreSourceName(ofAlignment: fromCounted),
            "counted.lungfishfastq",
            "the alignment names the bundle whose reads carry written scores"
        )

        let fromMeasured = try makeAlignment(
            named: "from-measured", mapperRanOn: [measured.appendingPathComponent("reads.fastq")], inputRecords: []
        )
        XCTAssertNil(
            ReadExtractionService.placeholderScoreSourceName(ofAlignment: fromMeasured),
            "an alignment of reads with measured scores names no bundle"
        )

        let unrecorded = root.appendingPathComponent("unrecorded", isDirectory: true)
        try FileManager.default.createDirectory(at: unrecorded, withIntermediateDirectories: true)
        let loneBAM = unrecorded.appendingPathComponent("x.bam")
        try Data([0x1F, 0x8B]).write(to: loneBAM)
        XCTAssertNil(
            ReadExtractionService.placeholderScoreSourceName(ofAlignment: loneBAM),
            "a folder with no mapping record gives nil, as every other alignment does"
        )
    }

    /// The mapper can run on a file written for the run, outside every bundle (a derived, chunked or concatenated bundle),
    /// and the record's input files then hold the bundle the reads came from. Control: the same staged file with the record
    /// of a bundle whose scores were measured gives nil.
    func testAnAlignmentMappedFromStagedReadsNamesTheBundleOfItsInputRecord() throws {
        let counted = try makeBundle(named: "counted", placeholders: true)
        let measured = try makeBundle(named: "measured", placeholders: false)
        let staged = root.appendingPathComponent("staged/materialized.fastq")
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(to: staged, atomically: true, encoding: .utf8)

        let fromCounted = try makeAlignment(named: "staged-counted", mapperRanOn: [staged], inputRecords: [counted])
        XCTAssertEqual(
            ReadExtractionService.placeholderScoreSourceName(ofAlignment: fromCounted),
            "counted.lungfishfastq",
            "the input record names the bundle behind the staged file"
        )

        let fromMeasured = try makeAlignment(named: "staged-measured", mapperRanOn: [staged], inputRecords: [measured])
        XCTAssertNil(
            ReadExtractionService.placeholderScoreSourceName(ofAlignment: fromMeasured),
            "a staged file whose input record is a bundle of measured scores names no bundle"
        )
    }

    // MARK: - Fixtures

    /// A `.lungfishfastq` bundle of one read. `placeholders` puts the mark on its derived manifest.
    private func makeBundle(named name: String, placeholders: Bool) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(
            to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8
        )
        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: 1)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: name, parentBundleRelativePath: ".", rootBundleRelativePath: ".",
                rootFASTQFilename: "reads.fastq", payload: .full(fastqFilename: "reads.fastq"),
                lineage: [operation], operation: operation, cachedStatistics: .empty, pairingMode: .singleEnd,
                qualityScoresArePlaceholders: placeholders ? true : nil
            ),
            in: bundle
        )
        return bundle
    }

    /// A folder as a mapping run leaves it: `x.bam` beside a `mapping-provenance.json` that records the files the mapper
    /// ran on (`mapperRanOn`) and the inputs as the run found them (`inputRecords`). Returns the BAM.
    private func makeAlignment(named name: String, mapperRanOn: [URL], inputRecords: [URL]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bam = folder.appendingPathComponent("x.bam")
        try Data([0x1F, 0x8B]).write(to: bam)
        try MappingProvenance(
            mapper: .minimap2,
            modeID: "short-read-default",
            sampleName: "Sample",
            pairedEnd: false,
            threads: 1,
            minimumMappingQuality: 0,
            includeSecondary: true,
            includeSupplementary: true,
            advancedArguments: [],
            inputFASTQURLs: mapperRanOn,
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: ["minimap2", "-a"]),
            normalizationInvocations: [],
            mapperVersion: "test",
            samtoolsVersion: "test",
            wallClockSeconds: 1,
            inputFiles: inputRecords.map { FileRecord(path: $0.path, role: .input) },
            exitStatus: 0
        ).save(to: folder)
        return bam
    }
}
