// ExtractReadsPlaceholderAlignmentRefusalTests.swift - extract reads refuses the alignment of placeholder reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane FLUIDIGM-3, review FLUIDIGM-BIO B1 (ruling BIO-FLUIDIGM-CHILDREN item 7). `lungfish extract reads` wraps the reads
// it pulls from a BAM in a plain bundle that no mark can sit on, and the mapping viewer's "Extract Reads... (original
// reads)" runs this command on the BAM of the mapping. Mapping keeps the FASTQ quality string, so the BAM of mapped
// Fluidigm reads holds `I` on every base and the bundle opened with Mean Q 40.0. Both BAM routes (`--by-region` and `--by-id
// --bam`) now end in the refusal of the read-ID extraction before any tool runs. The command builds its own extraction
// service with the shared tool runner, so the case plants no stand-in samtools: the refusal words and the empty output
// folder show that nothing past the refusal ran. The helper's own cases are in `ReadExtractionAlignmentProvenanceTests`.
//
// Lane FLUIDIGM-4, review FLUIDIGM-3 (BIO) B1. The app's argv, `AlignmentReadExtractionInvocation.arguments`, always carries
// `--index`, which sends the command down the evidence route, and that route had no refusal. The cases at the end run the
// app's own argv for both selections the app makes and for the original FASTQs of the run, and end in the same words.

import XCTest
import ArgumentParser
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
@testable import LungfishCLI

final class ExtractReadsPlaceholderAlignmentRefusalTests: XCTestCase {

    /// Red when the helper names no bundle, since the command then goes on to samtools with a BAM of two bytes.
    func testTheExtractReadsCommandRefusesAnAlignmentOfPlaceholderReads() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractPlaceholderBAM")
        defer { TestTempDirectory.cleanup(root) }
        let counted = try makeBundle(in: root, named: "counted")
        let bam = try makeAlignment(in: root, mappedFrom: counted)
        let ids = root.appendingPathComponent("ids.txt")
        try "r1\n".write(to: ids, atomically: true, encoding: .utf8)

        let routes: [(name: String, output: String, arguments: [String])] = [
            ("by region", "region-out.fastq", ["--by-region", "--bam", bam.path, "--region", "chr1:1-100"]),
            ("by read ID", "ids-out.fastq", ["--by-id", "--ids", ids.path, "--bam", bam.path]),
        ]
        for route in routes {
            let output = root.appendingPathComponent(route.output).standardizedFileURL
            let argv = route.arguments + ["-o", output.path]
            var cmd = try ExtractReadsSubcommand.parse(argv)
            cmd.testingRawArgs = argv
            try cmd.validate()
            do {
                try await cmd.run()
                XCTFail("\(route.name): the extraction of an alignment of placeholder reads ran")
            } catch {
                let words = ExtractReadsSubcommand.message(for: error)
                XCTAssertTrue(words.contains("counted.lungfishfastq"), "\(route.name): the words name the bundle: \(words)")
                XCTAssertTrue(
                    words.contains("built from sequence counts"),
                    "\(route.name): the words say where the reads come from: \(words)"
                )
                XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "\(route.name): a refusal exits nonzero")
            }
            let written = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(output.deletingPathExtension().lastPathComponent) }
            XCTAssertEqual(written, [], "\(route.name): a refusal writes no output")
        }
    }

    // MARK: - The app's own argv (FLUIDIGM-4)

    /// "Extract Reads... (original reads)" and "Extract Reads in Selected Region" run the argv of `AlignmentReadExtractionInvocation`
    /// with `--index`. Both selections over the alignment of placeholder reads end in the refusal of the read-ID extraction,
    /// before the evidence is hashed or a tool runs, and no bundle is written. Red when the evidence route has no check: the
    /// run goes on to hash and to samtools and ends in other words.
    func testTheEvidenceRouteRefusesTheAlignmentOfPlaceholderReadsThatTheAppExtracts() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractEvidencePlaceholderBAM")
        defer { TestTempDirectory.cleanup(root) }
        let counted = try makeBundle(in: root, named: "counted")
        let bam = try makeAlignment(in: root, mappedFrom: counted)
        let index = try makeIndex(for: bam)
        let ids = try makeReadNames(in: root)

        for (name, selection) in appSelections(ids: ids) {
            let failure = try await runTheAppsArgv(selection, bam: bam, index: index, root: root)
            guard let error = failure else {
                XCTFail("\(name): the extraction of an alignment of placeholder reads ran")
                continue
            }
            let words = ExtractReadsSubcommand.message(for: error)
            XCTAssertTrue(words.contains("counted.lungfishfastq"), "\(name): the words name the bundle: \(words)")
            XCTAssertTrue(words.contains("built from sequence counts"), "\(name): the words say where the reads come from: \(words)")
            XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "\(name): a refusal exits nonzero")
            XCTAssertEqual(try outputs(in: root), [], "\(name): a refusal writes no bundle")
        }
    }

    /// Reads named from the original FASTQs of the run (`--source`): a FASTQ of placeholder reads is refused whatever record the
    /// alignment holds, and this BAM has none.
    func testTheEvidenceRouteRefusesSourceFASTQsOfPlaceholderReads() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractEvidencePlaceholderSource")
        defer { TestTempDirectory.cleanup(root) }
        let counted = try makeBundle(in: root, named: "counted")
        let bam = try makeAlignmentWithoutRecord(in: root)
        let index = try makeIndex(for: bam)
        let ids = try makeReadNames(in: root)
        let selection = AlignmentReadExtractionInvocation.Selection.readNames(.init(
            file: ids, sourceFASTQs: [counted.appendingPathComponent("reads.fastq")], keepReadPairs: true, recordsWithoutSequence: 0
        ))

        let failure = try await runTheAppsArgv(selection, bam: bam, index: index, root: root)
        guard let error = failure else { return XCTFail("the extraction of source FASTQs of placeholder reads ran") }
        let words = ExtractReadsSubcommand.message(for: error)
        XCTAssertTrue(words.contains("counted.lungfishfastq"), "the words name the bundle: \(words)")
        XCTAssertTrue(words.contains("built from sequence counts"), "the words say where the reads come from: \(words)")
        XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "a refusal exits nonzero")
        XCTAssertEqual(try outputs(in: root), [], "a refusal writes no bundle")
    }

    /// Control (BIO 3): the same two selections over the alignment of reads whose scores were measured are not refused. The BAM
    /// has two bytes, so each run ends in the tool's own words, never in the refusal's.
    func testTheEvidenceRouteDoesNotRefuseTheAlignmentOfMeasuredReads() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractEvidenceMeasuredBAM")
        defer { TestTempDirectory.cleanup(root) }
        let measured = try makeBundle(in: root, named: "measured", marked: false)
        let bam = try makeAlignment(in: root, mappedFrom: measured)
        let index = try makeIndex(for: bam)
        let ids = try makeReadNames(in: root)

        for (name, selection) in appSelections(ids: ids) {
            let failure = try await runTheAppsArgv(selection, bam: bam, index: index, root: root)
            if let error = failure {
                let words = ExtractReadsSubcommand.message(for: error)
                XCTAssertFalse(words.contains("built from sequence counts"), "\(name): reads with measured scores are not refused: \(words)")
            }
        }
    }

    // MARK: - A source file written for the run (FLUIDIGM-4 BIO review B1)

    /// "Extract Reads... (original reads)" passes the mapping record's input files as `--source`. A mapping that ran on a file
    /// written for its run (a subsample, a trim, a chunk or a concatenation of counted reads) names that file, which sits in no
    /// bundle and so reads as measured. The record of the run beside the alignment names the bundle of placeholder reads, so the
    /// refusal stands. Red when the evidence route reads the source files only: the run goes on to samtools and ends in other words.
    func testTheEvidenceRouteRefusesALooseSourceFileWhenTheRunRecordNamesPlaceholderReads() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractEvidencePlaceholderLooseSource")
        defer { TestTempDirectory.cleanup(root) }
        let counted = try makeBundle(in: root, named: "counted")
        let bam = try makeAlignment(in: root, mappedFrom: counted)
        let index = try makeIndex(for: bam)
        let ids = try makeReadNames(in: root)
        let staged = try makeStagedFile(in: root)
        let selection = AlignmentReadExtractionInvocation.Selection.readNames(.init(
            file: ids, sourceFASTQs: [staged], keepReadPairs: true, recordsWithoutSequence: 0
        ))

        let failure = try await runTheAppsArgv(selection, bam: bam, index: index, root: root)
        guard let error = failure else { return XCTFail("the extraction of a loose source file of placeholder reads ran") }
        let words = ExtractReadsSubcommand.message(for: error)
        XCTAssertTrue(words.contains("counted.lungfishfastq"), "the words name the bundle: \(words)")
        XCTAssertTrue(words.contains("built from sequence counts"), "the words say where the reads come from: \(words)")
        XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "a refusal exits nonzero")
        XCTAssertEqual(try outputs(in: root), [], "a refusal writes no bundle")
    }

    /// Control (BIO 3): the same loose source file over the alignment of a mapping of reads whose scores were measured is not
    /// refused. The BAM has two bytes, so the run ends in the tool's own words, never in the refusal's.
    func testTheEvidenceRouteDoesNotRefuseALooseSourceFileOfMeasuredReads() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractEvidenceMeasuredLooseSource")
        defer { TestTempDirectory.cleanup(root) }
        let measured = try makeBundle(in: root, named: "measured", marked: false)
        let bam = try makeAlignment(in: root, mappedFrom: measured)
        let index = try makeIndex(for: bam)
        let ids = try makeReadNames(in: root)
        let staged = try makeStagedFile(in: root)
        let selection = AlignmentReadExtractionInvocation.Selection.readNames(.init(
            file: ids, sourceFASTQs: [staged], keepReadPairs: true, recordsWithoutSequence: 0
        ))

        let failure = try await runTheAppsArgv(selection, bam: bam, index: index, root: root)
        if let error = failure {
            let words = ExtractReadsSubcommand.message(for: error)
            XCTAssertFalse(words.contains("built from sequence counts"), "reads with measured scores are not refused: \(words)")
        }
    }

    // MARK: - Fixtures

    /// A file the mapping wrote for its run, `staged/materialized.fastq`, in no bundle.
    private func makeStagedFile(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("materialized.fastq")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The two selections the mapping viewer makes over its alignment: the reads of a region, and the reads of named records.
    private func appSelections(ids: URL) -> [(name: String, selection: AlignmentReadExtractionInvocation.Selection)] {
        [
            ("by region", .regions(["chr1:1-100"], minimumMapQ: nil, excludedFlags: nil, readGroups: [])),
            ("by read name", .readNames(.init(file: ids, sourceFASTQs: [], keepReadPairs: true, recordsWithoutSequence: 0))),
        ]
    }

    /// Runs the argv the app runs for `selection`, `invocation.arguments` after `extract reads`, and returns the error it ends in,
    /// or nil when it ends without one.
    private func runTheAppsArgv(
        _ selection: AlignmentReadExtractionInvocation.Selection, bam: URL, index: URL, root: URL
    ) async throws -> Error? {
        let invocation = AlignmentReadExtractionInvocation(
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil, selection: selection,
            readsName: "out", outputURL: root.appendingPathComponent("out.lungfishfastq")
        )
        let argv = Array(invocation.arguments.dropFirst(2))
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        do {
            try await cmd.run()
            return nil
        } catch {
            return error
        }
    }

    /// What the runs wrote under `root` with the output's name.
    private func outputs(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("out") }
    }

    /// A two-byte index beside the BAM, `mapped.bam.bai`, which the app's argv names with `--index`.
    private func makeIndex(for bam: URL) throws -> URL {
        let index = bam.appendingPathExtension("bai")
        try Data([0x1F, 0x8B]).write(to: index)
        return index
    }

    /// A file of one read name, which the app writes beside the bundle before the run.
    private func makeReadNames(in root: URL) throws -> URL {
        let ids = root.appendingPathComponent("ids.txt")
        try "r1\n".write(to: ids, atomically: true, encoding: .utf8)
        return ids
    }

    /// A BAM of two bytes in a folder with no mapping record.
    private func makeAlignmentWithoutRecord(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bam = folder.appendingPathComponent("mapped.bam")
        try Data([0x1F, 0x8B]).write(to: bam)
        return bam
    }

    /// A `.lungfishfastq` bundle of one read. `marked` puts the placeholder mark on its derived manifest.
    private func makeBundle(in root: URL, named name: String, marked: Bool = true) throws -> URL {
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
                qualityScoresArePlaceholders: marked ? true : nil
            ),
            in: bundle
        )
        return bundle
    }

    /// A folder as a mapping run leaves it: `mapped.bam` of two bytes beside a `mapping-provenance.json` whose mapper ran on
    /// the payload of `bundle`.
    private func makeAlignment(in root: URL, mappedFrom bundle: URL) throws -> URL {
        let folder = root.appendingPathComponent("mapping", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bam = folder.appendingPathComponent("mapped.bam")
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
            inputFASTQURLs: [bundle.appendingPathComponent("reads.fastq")],
            referenceFASTAURL: root.appendingPathComponent("reference.fa"),
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: ["minimap2", "-a"]),
            normalizationInvocations: [],
            mapperVersion: "test",
            samtoolsVersion: "test",
            wallClockSeconds: 1,
            exitStatus: 0
        ).save(to: folder)
        return bam
    }
}
