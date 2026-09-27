// AssembleReadLayoutTests.swift - lungfish-cli assemble resolves one file's read layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class AssembleReadLayoutTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("assemble-read-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Option parsing

    func testReadLayoutOptionParsesTheMapSpellings() throws {
        XCTAssertEqual(try AssembleCommand.parse(["reads.fastq"]).readLayout, .auto)
        XCTAssertEqual(try AssembleCommand.parse(["reads.fastq", "--read-layout", "interleaved"]).readLayout, .interleaved)
        XCTAssertEqual(try AssembleCommand.parse(["reads.fastq", "--read-layout", "single-end"]).readLayout, .singleEnd)
        XCTAssertEqual(try AssembleCommand.parse(["reads.fastq", "--read-layout", "mixed"]).readLayout, .mixed)
        XCTAssertThrowsError(try AssembleCommand.parse(["reads.fastq", "--read-layout", "paired"]))
        XCTAssertEqual(AssembleCommand.AssembleReadLayoutArgument.interleaved.explicitLayout, .strictlyInterleaved)
        XCTAssertNil(AssembleCommand.AssembleReadLayoutArgument.auto.explicitLayout)
    }

    func testReadLayoutOptionDescribesOneShortReadInput() {
        XCTAssertNil(AssembleCommand.validateReadLayoutOption(.auto, tool: .flye, pairedEnd: true, inputCount: 2))
        XCTAssertNil(AssembleCommand.validateReadLayoutOption(.interleaved, tool: .spades, pairedEnd: false, inputCount: 1))
        XCTAssertEqual(
            AssembleCommand.validateReadLayoutOption(.interleaved, tool: .spades, pairedEnd: true, inputCount: 2),
            "--read-layout describes one input file; use --paired for two R1/R2 files."
        )
        XCTAssertEqual(
            AssembleCommand.validateReadLayoutOption(.interleaved, tool: .megahit, pairedEnd: false, inputCount: 2),
            "--read-layout describes one input file; use --paired for two R1/R2 files."
        )
        XCTAssertEqual(
            AssembleCommand.validateReadLayoutOption(.interleaved, tool: .flye, pairedEnd: false, inputCount: 1),
            "--read-layout interleaved applies to the short-read assemblers (spades, megahit, skesa); Flye assembles every record as a single read."
        )
        XCTAssertNil(AssembleCommand.validateReadLayoutOption(.singleEnd, tool: .flye, pairedEnd: false, inputCount: 1))
    }

    // MARK: - Resolution

    func testInterleavedBundleResolvesToPairsFromItsRecords() throws {
        for naming in InterleavedFASTQFixture.MateNaming.allCases {
            let bundle = try InterleavedFASTQFixture.writeBundle(
                named: "hg002-\(naming.rawValue)", in: tempDir, pairCount: 6, naming: naming
            )
            let execution = try AssembleCommand.resolveExecutionInputURLs(for: [bundle.bundleURL])
            let resolution = try XCTUnwrap(AssembleCommand.resolveInputLayout(
                tool: .spades,
                readType: .illuminaShortReads,
                pairedEnd: false,
                explicit: nil,
                originalInputURLs: [bundle.bundleURL],
                executionInputURLs: execution
            ), naming.rawValue)
            XCTAssertEqual(resolution.layout, .strictlyInterleaved, naming.rawValue)

            let request = AssemblyRunRequest(
                tool: .spades,
                readType: .illuminaShortReads,
                inputURLs: execution,
                projectName: "hg002",
                outputDirectory: tempDir.appendingPathComponent("out"),
                threads: 2,
                inputLayout: resolution.layout
            )
            XCTAssertEqual(request.readPairing, .interleaved, naming.rawValue)
            XCTAssertEqual(AssembleCommand.readLayoutDescription(for: request, resolution: resolution), "interleaved pairs (content_scan)")
            XCTAssertNil(AssembleCommand.readLayoutWarning(for: request, resolution: resolution))
        }
    }

    func testMixedBundleResolvesToSingleReadsWithAWarning() throws {
        let bundle = try InterleavedFASTQFixture.writeMixedBundle(
            named: "vsp2", in: tempDir, pairCount: 5, mergedCount: 3, naming: .identical
        )
        let execution = try AssembleCommand.resolveExecutionInputURLs(for: [bundle.bundleURL])
        let resolution = try XCTUnwrap(AssembleCommand.resolveInputLayout(
            tool: .megahit,
            readType: .illuminaShortReads,
            pairedEnd: false,
            explicit: nil,
            originalInputURLs: [bundle.bundleURL],
            executionInputURLs: execution
        ))
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs)
        let request = AssemblyRunRequest(
            tool: .megahit,
            readType: .illuminaShortReads,
            inputURLs: execution,
            projectName: "vsp2",
            outputDirectory: tempDir.appendingPathComponent("out"),
            threads: 2,
            inputLayout: resolution.layout
        )
        XCTAssertEqual(request.readPairing, .single)
        let warning = try XCTUnwrap(AssembleCommand.readLayoutWarning(for: request, resolution: resolution))
        XCTAssertTrue(warning.hasPrefix("vsp2.fastq holds merged reads and pairs"), warning)
        XCTAssertTrue(warning.hasSuffix("assembled as a single read so that mates are not paired by position."), warning)
    }

    func testExplicitLayoutWinsAndMaterializedCopyUsesTheOriginalBundleAsHint() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "hg002", in: tempDir, pairCount: 4, naming: .identical)
        let explicit = try XCTUnwrap(AssembleCommand.resolveInputLayout(
            tool: .spades,
            readType: .illuminaShortReads,
            pairedEnd: false,
            explicit: .singleEnd,
            originalInputURLs: [bundle.bundleURL],
            executionInputURLs: [bundle.fastqURL]
        ))
        XCTAssertEqual(explicit.layout, .singleEnd)
        XCTAssertEqual(explicit.source, .explicit)

        // A scratch copy away from the bundle still scans as pairs, with the
        // bundle's metadata as hints.
        let scratch = tempDir.appendingPathComponent("materialized.fastq")
        try FileManager.default.copyItem(at: bundle.fastqURL, to: scratch)
        let hinted = try XCTUnwrap(AssembleCommand.resolveInputLayout(
            tool: .skesa,
            readType: .illuminaShortReads,
            pairedEnd: false,
            explicit: nil,
            originalInputURLs: [bundle.bundleURL],
            executionInputURLs: [scratch]
        ))
        XCTAssertEqual(hinted.layout, .strictlyInterleaved)
    }

    func testNothingIsResolvedForPairedFilesLongReadsOrPooledInputs() throws {
        let r1 = tempDir.appendingPathComponent("R1.fastq")
        let r2 = tempDir.appendingPathComponent("R2.fastq")
        try "@a\nACGT\n+\nIIII\n".write(to: r1, atomically: true, encoding: .utf8)
        try "@a\nACGT\n+\nIIII\n".write(to: r2, atomically: true, encoding: .utf8)
        XCTAssertNil(AssembleCommand.resolveInputLayout(
            tool: .spades, readType: .illuminaShortReads, pairedEnd: true, explicit: nil,
            originalInputURLs: [r1, r2], executionInputURLs: [r1, r2]
        ))
        XCTAssertNil(AssembleCommand.resolveInputLayout(
            tool: .spades, readType: .illuminaShortReads, pairedEnd: false, explicit: nil,
            originalInputURLs: [r1, r2], executionInputURLs: [r1, r2]
        ))
        XCTAssertNil(AssembleCommand.resolveInputLayout(
            tool: .flye, readType: .ontReads, pairedEnd: false, explicit: nil,
            originalInputURLs: [r1], executionInputURLs: [r1]
        ))
    }

    // MARK: - Provenance

    func testProvenanceRecordsInterleavedPairsAsPairedEnd() throws {
        let bundle = try InterleavedFASTQFixture.writeBundle(named: "hg002", in: tempDir, pairCount: 4, naming: .identical)
        let outputDir = tempDir.appendingPathComponent("assembly-hg002", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let contigsURL = outputDir.appendingPathComponent("contigs.fasta")
        try ">contig1\nACGTACGT\n".write(to: contigsURL, atomically: true, encoding: .utf8)
        let result = AssemblyResult(
            tool: .spades,
            readType: .illuminaShortReads,
            contigsPath: contigsURL,
            graphPath: nil,
            logPath: nil,
            assemblerVersion: "4.3.0",
            commandLine: "spades.py --isolate --12 hg002.fastq -o out",
            outputDirectory: outputDir,
            statistics: try AssemblyStatisticsCalculator.compute(from: contigsURL),
            wallTimeSeconds: 1.0
        )
        try result.save(to: outputDir)

        let resolution = try XCTUnwrap(AssembleCommand.resolveInputLayout(
            tool: .spades,
            readType: .illuminaShortReads,
            pairedEnd: false,
            explicit: nil,
            originalInputURLs: [bundle.bundleURL],
            executionInputURLs: [bundle.fastqURL]
        ))
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: [bundle.fastqURL],
            projectName: "hg002",
            outputDirectory: outputDir,
            threads: 2,
            selectedProfileID: "isolate",
            inputLayout: resolution.layout
        )
        let sidecarURL = try AssembleCommand.writeProvenance(
            request: request,
            result: result,
            originalInputURLs: [bundle.bundleURL],
            executionInputURLs: [bundle.fastqURL],
            argv: ["lungfish-cli", "assemble", bundle.bundleURL.path],
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            layoutResolution: resolution,
            writer: ProvenanceWriter(signingProvider: nil)
        )
        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: sidecarURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["pairedEnd"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["readPairing"], .string("interleaved"))
        XCTAssertEqual(envelope.options.resolvedDefaults["readLayout"], .string("strictly_interleaved"))
        XCTAssertEqual(envelope.options.resolvedDefaults["readLayoutSource"], .string("content_scan"))
        XCTAssertEqual(envelope.options.resolvedDefaults["readLayoutHandling"], .string("as_pairs"))
        XCTAssertEqual(envelope.options.resolvedDefaults["readLayoutReason"], .string(resolution.reason))
    }
}
