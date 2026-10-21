// WorkflowOperationExecutionServiceCancelTests.swift - A cancel of a begin site's row ends the row and leaves no process
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
import XCTest

/// Phase 2.13 lane 13.46 (M868, QR-b-CANCEL). No begin test of lane 12.21 cancels a run. Each test here runs one
/// begin site of `WorkflowOperationExecutionService` on the real process runner against a shell stand-in for
/// `lungfish-cli`, with one busy thread for every core. The stand-in starts a child that sleeps, writes the child's
/// process ID and its own, and waits. The test cancels the row through `OperationCenter.cancel(id:)`, as the
/// Operations panel's Cancel button does. It then asserts the end the site's own code sets for a cancelled row,
/// that the site left no output bundle, and that neither process of the stand-in outlives the cancel.
@MainActor
final class WorkflowOperationExecutionServiceCancelTests: XCTestCase {

    // MARK: - The stand-in lungfish-cli

    /// The scratch folder, the stand-in `lungfish-cli` and the files it writes its process IDs to.
    private struct StandIn {
        let root: URL
        let cli: URL
        let pidFile: URL
        let childPIDFile: URL
    }

    /// A shell script in place of `lungfish-cli`. It starts a child that sleeps, writes the child's process ID and
    /// then its own, and waits for the child. SIGTERM ends the script with its default action, so only a cancel
    /// that reaches the child's process group ends the child as well.
    private func makeStandIn() throws -> StandIn {
        let root = try TestTempDirectory.make(prefix: "workflow-service-cancel")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let folder = root.appendingPathComponent("stand-in", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pidFile = folder.appendingPathComponent("cli.pid")
        let childPIDFile = folder.appendingPathComponent("child.pid")
        let cli = folder.appendingPathComponent("lungfish-cli")
        let script = """
        #!/bin/sh
        sleep 120 &
        echo $! > "\(childPIDFile.path)"
        echo $$ > "\(pidFile.path)"
        wait

        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return StandIn(root: root, cli: cli, pidFile: pidFile, childPIDFile: childPIDFile)
    }

    // MARK: - The site under test

    /// The service on a fresh operation center and the real process runner, which launches the stand-in.
    private struct Site {
        let standIn: StandIn
        let operationCenter: OperationCenter
        let refresher: RecordingBeginSiteResultRefresher
        let service: WorkflowOperationExecutionService
    }

    private func makeSite() throws -> Site {
        let standIn = try makeStandIn()
        let operationCenter = OperationCenter()
        operationCenter.failureReportStore = .temporaryForTesting()
        let refresher = RecordingBeginSiteResultRefresher()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: ProcessLocalWorkflowCLIProcessRunner(executableURL: standIn.cli),
            resultRefresher: refresher
        )
        return Site(standIn: standIn, operationCenter: operationCenter, refresher: refresher, service: service)
    }

    /// What the site's task returned, set when the task ends.
    @MainActor
    private final class Ended {
        var result: Result<[URL], Error>?
    }

    // MARK: - The cancel

    /// Runs `start` with every core busy, cancels the row once the stand-in runs, and asserts the whole cancel.
    /// - Parameters:
    ///   - rowTitle: The title the site gives its Operations panel row.
    ///   - absent: Output bundles the site makes none of, which must not exist after the cancel.
    ///   - start: The call that reaches the site.
    private func assertCancelEndsTheRowAndLeavesNoProcess(
        _ site: Site,
        rowTitle: String,
        absent bundles: [URL],
        start: @escaping @MainActor () async throws -> [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let load = BusyCores()
        load.start()
        defer { load.stop() }
        let busy = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(10)) {
            load.spinningCount == load.threadCount
        }
        XCTAssertTrue(busy, "\(load.spinningCount) of \(load.threadCount) busy threads spin", file: file, line: line)
        XCTAssertEqual(
            load.threadCount, ProcessInfo.processInfo.activeProcessorCount, "one busy thread for every core",
            file: file, line: line
        )

        let ended = Ended()
        let run = Task { @MainActor in
            do {
                ended.result = .success(try await start())
            } catch {
                ended.result = .failure(error)
            }
        }

        let recordedPID = await CLISIGTERMHarness.waitForProcessID(in: site.standIn.pidFile)
        let recordedChildPID = await CLISIGTERMHarness.waitForProcessID(in: site.standIn.childPIDFile)
        guard let pid = recordedPID, let childPID = recordedChildPID else {
            XCTFail("the site never launched the stand-in lungfish-cli: \(String(describing: ended.result))", file: file, line: line)
            _ = await run.result
            return
        }
        let tree = CLISIGTERMHarness.processTree(of: pid)
        XCTAssertTrue(tree.contains(childPID), "the child \(childPID) runs under the stand-in, tree \(tree)", file: file, line: line)
        let processes = Array(Set([pid, childPID] + tree))

        XCTAssertEqual(site.operationCenter.items.count, 1, "one begin makes one row", file: file, line: line)
        let item = try XCTUnwrap(site.operationCenter.items.first, "the site began a row", file: file, line: line)
        XCTAssertEqual(item.title, rowTitle, file: file, line: line)
        XCTAssertEqual(item.state, .running, "the row runs while the stand-in runs", file: file, line: line)

        site.operationCenter.cancel(id: item.id)

        let returned = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
            ended.result != nil
        }
        if !returned {
            XCTFail("the site did not return within \(CLISIGTERMHarness.processWait) of the cancel", file: file, line: line)
            for process in processes { kill(process, SIGKILL) }
        }
        _ = await run.result

        // Neither process of the stand-in is alive, 30 seconds after the cancel at the latest.
        await CLISIGTERMHarness.assertNoProcessLeft(processes, file: file, line: line)

        // The end the site's own code sets for a cancelled row. It acknowledges the cancel and throws
        // CancellationError, and the 10 second fallback of `OperationCenter.cancel(id:)` did not close the row.
        if case .failure(let error)? = ended.result {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        } else {
            XCTFail("a cancelled site must throw CancellationError, it ended with \(String(describing: ended.result))", file: file, line: line)
        }
        let cancelled = try XCTUnwrap(site.operationCenter.items.first, file: file, line: line)
        XCTAssertEqual(cancelled.state, .cancelled, file: file, line: line)
        XCTAssertEqual(cancelled.displayStateLabel, "Cancelled", file: file, line: line)
        XCTAssertEqual(cancelled.detail, "Cancelled by user", file: file, line: line)
        XCTAssertNil(cancelled.errorMessage, "a cancel is not a failure", file: file, line: line)
        XCTAssertFalse(
            cancelled.logEntries.contains { $0.message.contains("did not respond to cancellation") },
            "the site acknowledged the cancel, the fallback did not close the row",
            file: file, line: line
        )
        XCTAssertEqual(site.refresher.invocations, [], "a cancelled run refreshes nothing", file: file, line: line)
        for bundle in bundles {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundle.path),
                "a cancelled run leaves no bundle at \(bundle.path)",
                file: file, line: line
            )
        }
    }

    // MARK: - Cases

    /// `runTwelveSReferenceBundleBuild` is internal. The CLI makes the bundle, so a cancelled build leaves none.
    func testCancelOfTheTwelveSReferenceBundleBuildEndsTheRowAndLeavesNoProcessWithEveryCoreBusy() async throws {
        let site = try makeSite()
        let root = site.standIn.root
        let deduplicatedFASTA = root.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let midoriMetadata = root.appendingPathComponent("12s_reference.tsv")
        try Data(">target\nACGT\n".utf8).write(to: deduplicatedFASTA)
        try Data("seq_id\tlatin_name\tgroup\ttaxid\tcommon_name\n".utf8).write(to: midoriMetadata)
        let configuration = TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: deduplicatedFASTA,
            midoriMetadataTSV: midoriMetadata,
            outputURL: root.appendingPathComponent("Reference Sequences/MIDORI-12S.lungfish12sref", isDirectory: true),
            name: "MIDORI 12S"
        )
        let service = site.service

        try await assertCancelEndsTheRowAndLeavesNoProcess(
            site, rowTitle: "12S Reference Bundle", absent: [configuration.outputURL]
        ) {
            try await service.runTwelveSReferenceBundleBuild(configuration)
        }
    }

    /// `runTwelveSAmpliconMatching` is private and reached through `run(_:)`. The site makes the output folder and
    /// the CLI makes the bundle inside it, so a cancelled run leaves the folder and no bundle.
    func testCancelOfTheTwelveSAmpliconMatchingEndsTheRowAndLeavesNoProcessWithEveryCoreBusy() async throws {
        let site = try makeSite()
        let root = site.standIn.root
        let reads = root.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let reference = root.appendingPathComponent("amplicons_12s.fa")
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: reference)
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [reads],
            referenceFASTA: reference,
            outputDirectory: root.appendingPathComponent("Analyses/12S amplicon results", isDirectory: true),
            outputName: "hilo-12s",
            threads: 1
        )
        let bundle = configuration.outputDirectory
            .appendingPathComponent("\(configuration.outputName).lungfish12s", isDirectory: true)
        let service = site.service

        try await assertCancelEndsTheRowAndLeavesNoProcess(
            site, rowTitle: "12S Amplicon Matching", absent: [bundle]
        ) {
            try await service.run(.twelveSAmpliconMatching(configuration))
        }
    }

    /// `runFullLengthONTMHCGenotyping` is private and reached through `run(_:)`. The CLI publishes the bundle in one
    /// step, so the app leaves the bundle path absent and a cancelled run leaves none.
    func testCancelOfTheFullLengthONTMHCGenotypingEndsTheRowAndLeavesNoProcessWithEveryCoreBusy() async throws {
        let site = try makeSite()
        let root = site.standIn.root
        let reads = root.appendingPathComponent("NB13.lungfishfastq", isDirectory: true)
        let reference = root.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true)
        for directory in [reads, reference] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [reads],
            referenceSourceURL: reference,
            outputDirectory: root.appendingPathComponent("Analyses/nb13-full-length.lungfishgenotype", isDirectory: true),
            outputName: "nb13-full-length",
            threads: 4
        )
        let service = site.service

        try await assertCancelEndsTheRowAndLeavesNoProcess(
            site, rowTitle: "Full-Length ONT MHC Genotyping", absent: [request.outputDirectory]
        ) {
            try await service.run(.fullLengthONTMHCGenotyping(request))
        }
    }
}
