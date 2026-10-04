// AssemblyReadSetArgvTests.swift - The assembler command line of every bundle layout in the read-pairing contract
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): paired
// reads that were not merged are used as pairs. A sample that holds pairs
// and single reads reaches SPAdes, MEGAHIT and SKESA as one run, with each
// file in its role. A sample of only single reads or only pairs keeps the
// command it always had. Each file in a command line is shown by the read
// names inside it, so the tests say which reads reached which flag.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class AssemblyReadSetArgvTests: XCTestCase {
    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assembly-read-set-argv")
        fixtures = try ReadSetFixtures(in: root)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Unchanged commands (captured at the base commit, 2f3cd27a8)

    func testASampleOfOnlySingleReadsKeepsItsCommand() async throws {
        // L1 root single-end, L4 chunked root (joined into one file), L6 virtual subset of single reads.
        for (label, bundle) in [("L1", fixtures.singleRoot), ("L4", fixtures.chunkedRoot), ("L6 single", fixtures.subsetOfSingle)] {
            let reads = label == "L1" ? "{s1 s2 s3}" : (label == "L4" ? "{c1 c2 c3}" : "{s1 s3}")
            try await assertCommands(for: bundle, label: label, [
                .spades: ["--isolate", "-s", reads, "-o", "<out>", "--threads", "2"],
                .megahit: ["-r", reads, "-o", "<out>", "--num-cpu-threads", "2"],
                .skesa: ["--reads", reads, "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
            ])
        }
    }

    func testASampleOfOnlyPairsKeepsItsCommand() async throws {
        // L2 interleaved root, L5b paired derivative, L6 virtual subset of a repair derivative (pairs only).
        try await assertCommands(for: fixtures.interleavedRoot, label: "L2", [
            .spades: ["--isolate", "--12", "{i1/1 i1/2 i2/1 i2/2}", "-o", "<out>", "--threads", "2"],
            .megahit: ["--12", "{i1/1 i1/2 i2/1 i2/2}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{i1/1 i1/2 i2/1 i2/2}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--use_paired_ends", "--min_count", "2"],
        ])
        try await assertCommands(for: fixtures.pairedDerivative, label: "L5b", [
            .spades: ["--isolate", "-1", "{p1/1 p2/1}", "-2", "{p1/2 p2/2}", "-o", "<out>", "--threads", "2"],
            .megahit: ["-1", "{p1/1 p2/1}", "-2", "{p1/2 p2/2}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{p1/1 p2/1},{p1/2 p2/2}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
        ])
        try await assertCommands(for: fixtures.subsetOfRepair, label: "L6 repair subset", [
            .spades: ["--isolate", "--12", "{r1/1 r1/2 r2/1 r2/2}", "-o", "<out>", "--threads", "2"],
            .megahit: ["--12", "{r1/1 r1/2 r2/1 r2/2}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{r1/1 r1/2 r2/1 r2/2}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--use_paired_ends", "--min_count", "2"],
        ])
    }

    // MARK: - Pairs and single reads in one run (decision 1)

    /// L3, a root file of merged reads then pairs. Before the change the whole
    /// file went to the assembler as single reads (SPAdes `-s`, MEGAHIT `-r`,
    /// SKESA a bare `--reads`), so the 2 pairs were assembled as 4 unrelated
    /// reads. Now the file is split by fragment name.
    func testAMixedRootFileIsSplitByNameAndEachPartTakesItsRole() async throws {
        try await assertCommands(for: fixtures.mixedRoot, label: "L3", [
            .spades: ["--isolate", "-1", "{p1/1 p2/1}", "-2", "{p1/2 p2/2}", "--merged", "{m1 m2 m3}", "-o", "<out>", "--threads", "2"],
            .megahit: ["-1", "{p1/1 p2/1}", "-2", "{p1/2 p2/2}", "-r", "{m1 m2 m3}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{p1/1 p2/1},{p1/2 p2/2}", "--reads", "{m1 m2 m3}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
        ])
    }

    /// L5c, a merge derivative. Before the change its three files were joined
    /// and assembled as 5 single reads.
    func testAMergeDerivativeGivesItsPairsAndItsMergedReadsTheirRoles() async throws {
        try await assertCommands(for: fixtures.mergeDerivative, label: "L5c", [
            .spades: ["--isolate", "-1", "{u1/1}", "-2", "{u1/2}", "--merged", "{x1 x2 x3}", "-o", "<out>", "--threads", "2"],
            .megahit: ["-1", "{u1/1}", "-2", "{u1/2}", "-r", "{x1 x2 x3}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{u1/1},{u1/2}", "--reads", "{x1 x2 x3}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
        ])
    }

    /// L5d, a repair derivative. The orphan is a single read, so SPAdes takes
    /// it as `-s`, MEGAHIT as `-r` and SKESA as its own `--reads`.
    func testARepairDerivativeGivesItsPairsAndItsOrphansTheirRoles() async throws {
        try await assertCommands(for: fixtures.repairDerivative, label: "L5d", [
            .spades: ["--isolate", "-1", "{r1/1 r2/1}", "-2", "{r1/2 r2/2}", "-s", "{o1}", "-o", "<out>", "--threads", "2"],
            .megahit: ["-1", "{r1/1 r2/1}", "-2", "{r1/2 r2/2}", "-r", "{o1}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{r1/1 r2/1},{r1/2 r2/2}", "--reads", "{o1}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
        ])
    }

    /// L6, a virtual subset of a merge derivative. Its materialized file holds
    /// the pair first and the merged read after it, and the lineage says the
    /// reads without a mate were merged.
    func testAVirtualSubsetOfAMergeDerivativeIsSplitByNameToo() async throws {
        try await assertCommands(for: fixtures.subsetOfMerge, label: "L6 merge subset", [
            .spades: ["--isolate", "-1", "{u1/1}", "-2", "{u1/2}", "--merged", "{x1}", "-o", "<out>", "--threads", "2"],
            .megahit: ["-1", "{u1/1}", "-2", "{u1/2}", "-r", "{x1}", "-o", "<out>", "--num-cpu-threads", "2"],
            .skesa: ["--reads", "{u1/1},{u1/2}", "--reads", "{x1}", "--contigs_out", "<out>/contigs.fasta", "--cores", "2", "--min_count", "2"],
        ])
    }

    // MARK: - Helpers

    private let host = AssemblyExecutionHost(operatingSystem: .other, architecture: "x86_64")

    private func assertCommands(
        for bundle: URL,
        label: String,
        _ expected: [AssemblyTool: [String]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for tool in [AssemblyTool.spades, .megahit, .skesa] {
            let request = try await assemblyRequest(for: bundle, tool: tool)
            let command = try ManagedAssemblyPipeline.buildCommand(for: request, host: host)
            XCTAssertEqual(
                try describe(command.arguments, outputDirectory: request.outputDirectory),
                expected[tool],
                "\(label) \(tool.rawValue)",
                file: file,
                line: line
            )
        }
    }

    /// The request `lungfish-cli assemble <bundle> --assembler <tool>` builds.
    private func assemblyRequest(for bundle: URL, tool: AssemblyTool) async throws -> AssemblyRunRequest {
        let outputDirectory = root.appendingPathComponent("out-\(tool.rawValue)-\(UUID().uuidString)", isDirectory: true)
        let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
            inputURLs: [bundle],
            materializationDirectory: outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
        let pairedEnd = resolved.resolvedAsMatePair
        let layout = AssemblyRunRequest.resolveInputLayout(
            tool: tool,
            readType: .illuminaShortReads,
            pairedEnd: pairedEnd,
            explicit: nil,
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs,
            pooled: resolved.pooledLayoutResolution
        )
        return AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: resolved.executionInputURLs,
            projectName: "fixture",
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: 2,
            inputLayout: layout?.layout
        )
    }

    /// Each file argument as the read names inside it, a comma list of files
    /// as the comma list of those, and the output folder as `<out>`.
    private func describe(_ arguments: [String], outputDirectory: URL) throws -> [String] {
        try arguments.map { argument in
            let parts = try argument.split(separator: ",", omittingEmptySubsequences: false).map { part -> String in
                let path = String(part)
                if FileManager.default.fileExists(atPath: path), !path.hasSuffix("/"),
                   try !isDirectory(path) {
                    return "{\(try ReadSetFixtures.readNames(in: URL(fileURLWithPath: path)).joined(separator: " "))}"
                }
                return path.replacingOccurrences(of: outputDirectory.path, with: "<out>")
            }
            return parts.joined(separator: ",")
        }
    }

    private func isDirectory(_ path: String) throws -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}
