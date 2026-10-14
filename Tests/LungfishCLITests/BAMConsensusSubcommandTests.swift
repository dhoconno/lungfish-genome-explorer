// BAMConsensusSubcommandTests.swift - lungfish-cli bam consensus, its refusals, its record and its cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A51 M2. The viewer's Generate Consensus runs `bam consensus` (ruling-A51-consensus).
// The leaf refuses a consensus that is N at every position with exit 3 before it writes anything,
// unless it is given --allow-all-low-depth, which its record then names. It refuses a taken output,
// replaces the record a cancelled run left, and turns SIGTERM into a cancel while it hashes the
// evidence, recorded beside --output (SWIFT 3). The runs use samtools on the sarscov2 BAM, and the
// SIGTERM check runs the built CLI on `CLISIGTERMHarness` with a sparse 64 GiB index.

import ArgumentParser
import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class BAMConsensusSubcommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "bam-consensus")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private final class Lines: Sendable {
        private let state = Mutex<[String]>([])
        func append(_ line: String) { state.withLock { $0.append(line) } }
        var events: [CLIEvent] {
            let decoder = CLIEventLineDecoder()
            return state.withLock { $0 }.compactMap { try? decoder.decodeLine($0)?.event }
        }
    }

    private static let bam = ProvenanceCompatCorpus.repositoryRoot
        .appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
    private static let contigLength = 29829

    private func arguments(output: URL, minimumDepth: Int = 1, index: URL? = nil, region: String? = nil, extra: [String] = []) -> [String] {
        [
            "--alignment", Self.bam.path, "--index", (index ?? URL(fileURLWithPath: Self.bam.path + ".bai")).path,
            "--scope", "wholeContig", "--region", region ?? "MT192765.1:1-\(Self.contigLength)", "--min-depth", "\(minimumDepth)",
            "--name", "S1 MT192765.1 consensus", "--result-id", "run-1", "--output", output.path, "--format", "json",
        ] + extra
    }

    private func run(_ arguments: [String]) async throws -> (lines: Lines, exit: Int32?) {
        let command = try BAMConsensusSubcommand.parse(arguments)
        let lines = Lines()
        do {
            try await command.execute(eventsOn: true, quiet: false, emit: lines.append)
            return (lines, nil)
        } catch let exit as ExitCode {
            return (lines, exit.rawValue)
        }
    }

    func testAnAllLowDepthResultIsRefusedWithoutTheFlag() async throws {
        let output = root.appendingPathComponent("S1.fasta")

        let (lines, exit) = try await run(arguments(output: output, minimumDepth: 100_000))

        XCTAssertEqual(exit, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(lines.events.first, .start(message: BAMConsensusSubcommand.startMessage))
        XCTAssertEqual(lines.events.last, .failed(message: AlignmentConsensusPublicationService.allLowDepthRefusal, detail: nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "a refusal writes nothing")
    }

    /// The region guard `extract reads --index` shares (review A51, F2): a contig the header does not
    /// name and an end past the contig are refused with exit 3 before any consensus is called, and
    /// the run writes nothing.
    func testARegionOffTheEvidenceIsRefusedWithExit3AndWritesNothing() async throws {
        let output = root.appendingPathComponent("S1.fasta")
        let refusals = [
            ("NC_045512.2:1-3000", "The alignment has no contig named NC_045512.2. Name one of its contigs in --region."),
            ("MT192765.1:1-\(Self.contigLength + 1)", "The region ends at \(Self.contigLength + 1), past the end of MT192765.1 at \(Self.contigLength)."),
        ]
        for (region, message) in refusals {
            let (lines, exit) = try await run(arguments(output: output, region: region))

            XCTAssertEqual(exit, CLIExitCode.inputError.rawValue, region)
            XCTAssertEqual(lines.events, [.start(message: BAMConsensusSubcommand.startMessage), .failed(message: message, detail: nil)], region)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "a refusal writes nothing: \(region)")
        }
    }

    func testWithTheFlagTheAllNConsensusIsWrittenAndItsRecordNamesTheAnswer() async throws {
        let output = root.appendingPathComponent("S1.fasta")
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)

        let (lines, exit) = try await run(arguments(output: output, minimumDepth: 100_000, extra: ["--allow-all-low-depth"]))

        XCTAssertNil(exit)
        XCTAssertEqual(lines.events.last, .complete(outputs: [output.path, sidecar.path], message: "Consensus FASTA saved"))
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            ">S1 MT192765.1 consensus\n\(String(repeating: "N", count: Self.contigLength))\n"
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(envelope.status, .completed)
        XCTAssertEqual(envelope.workflowName, "lungfish bam consensus")
        XCTAssertEqual(envelope.options.explicit["allowAllLowDepth"], .boolean(true))
        XCTAssertEqual(envelope.options.explicit["minimumDepth"], .integer(100_000))
        XCTAssertEqual(envelope.options.resolvedDefaults["allLowDepth"], .boolean(true))
        // The record's argv is the command that replays the run, the answer included.
        XCTAssertEqual(Array(envelope.argv.prefix(3)), ["lungfish-cli", "bam", "consensus"])
        let replay = try BAMConsensusSubcommand.parse(Array(envelope.argv.dropFirst(3)))
        XCTAssertTrue(replay.allowAllLowDepth)
        XCTAssertEqual(replay.outputPath, output.path)
        XCTAssertEqual(replay.region, "MT192765.1:1-\(Self.contigLength)")
        XCTAssertEqual(replay.minimumDepth, 100_000)
    }

    func testABundleOutputIsAReferenceBundleWithItsRecordInside() async throws {
        let output = root.appendingPathComponent("S1.lungfishref", isDirectory: true)

        let (lines, exit) = try await run(arguments(output: output))

        XCTAssertNil(exit)
        XCTAssertEqual(lines.events.last, .complete(outputs: [output.path], message: "Consensus reference bundle created"))
        let manifest = try BundleManifest.load(from: output)
        XCTAssertEqual(manifest.name, "S1 MT192765.1 consensus")
        XCTAssertEqual(manifest.source.assembly, "run-1")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: output))
        XCTAssertEqual(envelope.argv, AlignmentConsensusPublicationService.replayArgv(.init(
            alignmentURL: Self.bam, indexURL: URL(fileURLWithPath: Self.bam.path + ".bai"), decodingReferenceURL: nil,
            region: .init(scope: .wholeContig, contig: "MT192765.1", start: 0, end: Self.contigLength),
            consensusRequest: .init(
                chromosome: "MT192765.1", start: 0, end: Self.contigLength,
                filters: .init(minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
                mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
            ),
            recordName: "S1 MT192765.1 consensus", resultID: "run-1", output: output.path
        )))
    }

    func testATakenOutputIsRefusedWithExit3AndKept() async throws {
        let output = root.appendingPathComponent("S1.fasta")
        try Data("kept".utf8).write(to: output)

        let (lines, exit) = try await run(arguments(output: output))

        XCTAssertEqual(exit, CLIExitCode.inputError.rawValue)
        XCTAssertEqual(lines.events, [.failed(message: "A file already exists at \(output.path).", detail: nil)])
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "kept")
    }

    func testTheRecordACancelledRunLeftIsReplacedByTheNextRun() async throws {
        let output = root.appendingPathComponent("S1.fasta")
        let command = try BAMConsensusSubcommand.parse(arguments(output: output))
        let sidecar = try AlignmentConsensusPublicationService.recordCancelledRun(
            .init(
                alignmentURL: Self.bam, indexURL: URL(fileURLWithPath: Self.bam.path + ".bai"), decodingReferenceURL: nil,
                region: .init(scope: .wholeContig, contig: "MT192765.1", start: 0, end: Self.contigLength),
                consensusRequest: .init(
                    chromosome: "MT192765.1", start: 0, end: Self.contigLength,
                    filters: .init(minimumDepth: 1, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
                    mode: .bayesian, useAmbiguity: false, insertionPolicy: .omit, deletionPolicy: .n
                ),
                recordName: "S1 MT192765.1 consensus", resultID: "run-1", output: output.path
            ),
            outputURL: output, startedAt: Date()
        )
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)?.status, .cancelled)

        try await command.execute(eventsOn: true, quiet: false) { _ in }

        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)?.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    }

    func testSIGTERMWhileTheRunHashesRecordsItCancelledBesideTheOutputAndWritesNothing() async throws {
        let index = root.appendingPathComponent("sample.bam.bai")
        XCTAssertTrue(FileManager.default.createFile(atPath: index.path, contents: nil))
        let handle = try FileHandle(forWritingTo: index)
        try handle.truncate(atOffset: 64 << 30)
        try handle.close()
        let output = root.appendingPathComponent("S1.fasta")
        let record = ProvenanceRecorder.fileSidecarURL(for: output)

        let cli = try CLISIGTERMHarness.launchCLI(["bam", "consensus"] + arguments(output: output, index: index), testClass: Self.self)
        defer { cli.stop() }

        let pid = cli.processIdentifier
        let atWork = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            OpenFileProbe.process(pid, holdsOpen: index.path)
        }
        guard atWork else {
            let stop = await CLISIGTERMHarness.cancel(cli)
            return XCTFail("The CLI never opened the index to hash it.\(stop.diagnostics)")
        }

        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(cli) {
            try ProvenanceEnvelopeReader.load(fromSidecar: record)?.status.rawValue
        }
        XCTAssertTrue(stop.standardOutput.contains("Consensus cancelled"), stop.diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel writes no consensus")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: record)?.argv.prefix(3), ["lungfish-cli", "bam", "consensus"])
    }
}
