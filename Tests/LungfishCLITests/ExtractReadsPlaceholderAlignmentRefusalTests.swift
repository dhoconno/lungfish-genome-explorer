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

    // MARK: - Fixtures

    /// A `.lungfishfastq` bundle of one read whose derived manifest holds the placeholder mark.
    private func makeBundle(in root: URL, named name: String) throws -> URL {
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
                qualityScoresArePlaceholders: true
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
