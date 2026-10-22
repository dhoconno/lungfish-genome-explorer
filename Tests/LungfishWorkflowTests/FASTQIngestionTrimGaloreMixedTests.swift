// FASTQIngestionTrimGaloreMixedTests.swift - Trim Galore stores merged reads and pairs as clumpify stores them (CHTC lane C2-TRIMGALORE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A merging recipe ends with one file of merged reads followed by each R1 beside its R2. The bbtools storage step
// scans the mates by name, clumps the pairs and the unpaired reads apart and joins them. Trim Galore ran one paired or
// one single-end call and failed on such a file after the whole recipe had run (2026-10-20, owner direction O7).

import XCTest
import Synchronization
@testable import LungfishWorkflow
import LungfishCore
import LungfishIO
import LungfishTestSupport

final class FASTQIngestionTrimGaloreMixedTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrimGaloreMixed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    /// Skips, or under `LUNGFISH_REQUIRE_TOOLS=1` fails, unless the managed Trim Galore, the BBTools scripts the two
    /// routes use and a compressor are installed.
    private func requireTools() async throws {
        let runner = NativeToolRunner.shared
        for tool in [NativeTool.trimGalore, .clumpify, .reformat] {
            guard (try? await runner.toolPath(for: tool)) != nil else {
                try ToolAvailability.skipOrFail("Managed \(tool.rawValue) is not available")
            }
        }
        let hasBgzip = (try? await runner.toolPath(for: .bgzip)) != nil
        let hasPigz = (try? await runner.toolPath(for: .pigz)) != nil
        guard hasBgzip || hasPigz else {
            try ToolAvailability.skipOrFail("Neither managed bgzip nor pigz is available")
        }
    }

    private func store(
        _ input: URL, with tool: ClumpingTool, in root: URL, label: String
    ) async throws -> (result: FASTQIngestionResult, directory: URL) {
        let directory = root.appendingPathComponent("\(label)-out", isDirectory: true)
        let result = try await FASTQIngestionPipeline().run(
            config: FASTQIngestionConfig(
                inputFiles: [input],
                pairingMode: .interleaved,
                outputDirectory: directory,
                threads: 2,
                deleteOriginals: false,
                clumpingTool: tool
            ),
            progress: { _, _ in }
        )
        return (result, directory)
    }

    func testTrimGaloreStoresMergedReadsAndPairsAsClumpifyStoresThem() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 8, merged: 6)

        let clumpify = try await store(input, with: .bbtools, in: root, label: "bbtools")
        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let reference = try MixedStorageFASTQ.layout(of: clumpify.result.outputFile)
        let stored = try MixedStorageFASTQ.layout(of: trimGalore.result.outputFile)
        XCTAssertEqual(reference.pairs, 8, "the bbtools route is the reference layout")
        XCTAssertEqual(reference.unpaired, 6)
        XCTAssertTrue(reference.pairsBeforeUnpaired)
        XCTAssertEqual(stored.pairs, 8, "every pair stays with its mate")
        XCTAssertEqual(stored.unpaired, 6, "every merged read is kept")
        XCTAssertTrue(stored.pairsBeforeUnpaired, "pairs are stored interleaved ahead of the unpaired reads, as clumpify stores them")
        XCTAssertEqual(stored.names, reference.names, "the same reads are stored")
        XCTAssertEqual(
            try FASTQPairInterleaver.countRecords(in: trimGalore.result.outputFile),
            try FASTQPairInterleaver.countRecords(in: clumpify.result.outputFile)
        )
        XCTAssertTrue(trimGalore.result.wasClumpified)
        XCTAssertEqual(trimGalore.result.resolvedClumpingTool, .trimGalore)
        // Each half goes once it is processed and the scratch folder goes with the run.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: trimGalore.directory.path),
            [trimGalore.result.outputFile.lastPathComponent]
        )
    }

    func testEachTrimGaloreCallIsOneProvenanceStepWithItsArgv() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 5, merged: 4)

        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let calls = trimGalore.result.provenanceSteps.filter { $0.toolName == "trim_galore" }
        XCTAssertEqual(calls.count, 2, "one step for the pairs call and one for the unpaired call")
        let pairsCall = try XCTUnwrap(calls.first)
        let unpairedCall = try XCTUnwrap(calls.last)
        XCTAssertTrue(pairsCall.command.contains("--paired"))
        XCTAssertEqual(pairsCall.inputs.count, 2, "the pairs call read R1 and R2")
        XCTAssertFalse(unpairedCall.command.contains("--paired"))
        XCTAssertEqual(unpairedCall.inputs.count, 1)
        for call in calls {
            XCTAssertTrue(call.command.contains("--clumpify"))
            XCTAssertEqual(call.exitCode, 0)
        }
        let commandLine = try XCTUnwrap(trimGalore.result.processingCommandLine)
        XCTAssertEqual(commandLine.components(separatedBy: "trim_galore ").count - 1, 2, commandLine)
    }

    /// Trim Galore removes the reads its trim leaves under the length cutoff. Its trimming report counts them, so the
    /// stored file holds exactly the reads the reports say were written and the result names what was removed.
    func testAReadTrimGaloreFiltersOutIsNotMistakenForLoss() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 6, merged: 5, shortMerged: 1)

        let trimGalore = try await store(input, with: .trimGalore, in: root, label: "trim-galore")

        let stored = try MixedStorageFASTQ.layout(of: trimGalore.result.outputFile)
        XCTAssertEqual(stored.pairs, 6)
        XCTAssertEqual(stored.unpaired, 5, "only the 12-base merged read is filtered out")
        XCTAssertFalse(stored.names.contains("short1"))
        XCTAssertTrue(stored.pairsBeforeUnpaired)
        // Each call's step carries the effective parameters its trimming report names (review fix 1).
        let calls = trimGalore.result.provenanceSteps.filter { $0.toolName == "trim_galore" }
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertEqual(call.resolvedOptions?["length_cutoff"], .integer(20), "\(call.command)")
        }
        let removal = try XCTUnwrap(trimGalore.result.readsRemovedByStorage)
        XCTAssertEqual(removal.pairs, 0, "no pair falls under the cutoff")
        XCTAssertEqual(removal.unpairedReads, 1, "the 12-base merged read is counted as removed")
        XCTAssertEqual(removal.recordsStored, try FASTQPairInterleaver.countRecords(in: trimGalore.result.outputFile))
    }

    /// Review fix 1. A shortfall the report does not explain fails: an output that holds one record fewer than the
    /// report says were written, or a report that read fewer records than the input holds. The failed check removes
    /// the output, so the originals stay the only copy, and a call that left no readable report fails too.
    func testAShortfallTheReportDoesNotExplainFailsAndRemovesTheOutput() async throws {
        let report = TrimGaloreReport(paired: true, totalReads: 12, readsWritten: 11, version: "2.3.0", parameters: [:])
        XCTAssertNoThrow(try FASTQIngestionPipeline.verifyTrimGaloreAccounting(reported: report, scanned: 24, counted: 22))
        XCTAssertThrowsError(
            try FASTQIngestionPipeline.verifyTrimGaloreAccounting(reported: report, scanned: 24, counted: 21),
            "one record fewer than the report says were written"
        )
        XCTAssertThrowsError(
            try FASTQIngestionPipeline.verifyTrimGaloreAccounting(reported: report, scanned: 26, counted: 22),
            "the report read fewer records than the input holds"
        )

        let root = try makeRoot()
        let output = root.appendingPathComponent("stored.fastq")
        try MixedStorageFASTQ.writeMixed(to: output, pairs: 2, merged: 0)
        let single = TrimGaloreReport(paired: false, totalReads: 4, readsWritten: 4, version: nil, parameters: [:])
        do {
            try await FASTQIngestionPipeline.verifyTrimGaloreOutput(output, reported: single, scanned: 5)
            XCTFail("the input held a record the report did not read")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the failed check removed the output")
        XCTAssertThrowsError(try FASTQIngestionPipeline.readTrimGaloreReport(in: root), "no report fails closed")
    }

    /// Review fix 5. The mixed route launches `trim_galore`, `reformat.sh`, `trim_galore` and the compressor in turn
    /// over scratch folders in the output directory. A cancel at the first call's launch and a cancel after the pairs
    /// are interleaved must each end the run before the second Trim Galore call is launched, and leave the input as it
    /// was, no scratch folder and no process of the run. The pipeline's other cancel tests use bbtools only.
    func testACancelBetweenTheTwoTrimGaloreCallsLeavesNoScratchAndNoProcess() async throws {
        try await requireTools()
        let root = try makeRoot()
        let input = root.appendingPathComponent("mixed.fastq")
        try MixedStorageFASTQ.writeMixed(to: input, pairs: 6, merged: 5)
        let original = try Data(contentsOf: input)
        let secondCall = "Launching Trim Galore --clumpify on unpaired reads..."

        for (index, trigger) in ["Launching Trim Galore --clumpify on mate pairs...", "Interleaving complete"].enumerated() {
            let directory = root.appendingPathComponent("cancelled-\(index)-out", isDirectory: true)
            let config = FASTQIngestionConfig(
                inputFiles: [input],
                pairingMode: .interleaved,
                outputDirectory: directory,
                threads: 2,
                deleteOriginals: false,
                clumpingTool: .trimGalore
            )
            let messages = Mutex<[String]>([])

            let failure = await Task.detached { () -> (any Error)? in
                do {
                    _ = try await FASTQIngestionPipeline().run(config: config, progress: { _, message in
                        messages.withLock { $0.append(message) }
                        if message == trigger { withUnsafeCurrentTask { $0?.cancel() } }
                    })
                    return nil
                } catch {
                    return error
                }
            }.value

            let seen = messages.withLock { $0 }
            XCTAssertTrue(seen.contains(trigger), "the run reached '\(trigger)': \(seen)")
            XCTAssertNotNil(failure, "a run cancelled at '\(trigger)' does not store the file")
            XCTAssertFalse(seen.contains(secondCall), "the unpaired call is never launched after a cancel at '\(trigger)': \(seen)")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            XCTAssertEqual(
                entries.filter { $0.hasPrefix(".trim-galore-split") || $0.hasPrefix("trim-galore-") }, [],
                "no scratch folder is left after a cancel at '\(trigger)'"
            )
            XCTAssertEqual(entries, [], "nothing at all is left in the output directory after a cancel at '\(trigger)'")
            XCTAssertEqual(try Data(contentsOf: input), original, "the input is intact after a cancel at '\(trigger)'")
            let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
                await Self.pids(holding: directory.path).isEmpty
            }
            XCTAssertTrue(gone, "a process of the run outlived a cancel at '\(trigger)'")
        }
    }

    /// The pids of every process whose command line holds `fragment`, found with the real `pgrep`. Every launch of the
    /// run holds its output directory in its command line, and so does a child of a tool that a cancel killed.
    private static func pids(holding fragment: String) async -> [Int32] {
        let pattern = NSRegularExpression.escapedPattern(for: fragment)
        guard let result = try? await SystemToolProbe.run("pgrep", ["-f", pattern], stdout: .capture()) else {
            return []
        }
        return result.stdoutText.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }
}
