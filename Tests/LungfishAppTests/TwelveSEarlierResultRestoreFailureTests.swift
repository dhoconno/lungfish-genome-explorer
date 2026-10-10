// TwelveSEarlierResultRestoreFailureTests.swift - The app's 12S error says where an earlier result waits
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow
import os
@testable import LungfishApp
@testable import LungfishCLI
import XCTest

/// Re-review 2, N6. The app runs `lungfish-cli fastq 12s-match`. When a forced
/// run fails while it writes its bundle and the earlier result cannot be moved
/// back either, the error the Operations panel shows carries the line of the
/// CLI's error that says where the earlier result waits.
@MainActor
final class TwelveSEarlierResultRestoreFailureTests: XCTestCase {

    func testTheOperationsPanelErrorSaysWhereTheEarlierResultWaits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSEarlierResultRestoreFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("reference.fa")
        try ">human (Homo sapiens)|locus=12S|len=8\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let reads = root.appendingPathComponent("sampleA.fastq")
        try "@read1\nTTACGTACGTGG\n+\nIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let outputDirectory = root.appendingPathComponent("results", isDirectory: true)
        func configuration(force: Bool) -> TwelveSAmpliconMatchingConfiguration {
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [reads],
                referenceFASTA: reference,
                outputDirectory: outputDirectory,
                outputName: "sampleA-12s",
                minimumSoftClipBases: 2,
                threads: 1,
                runChimeraReview: false,
                forceOverwrite: force
            )
        }
        _ = try await TwelveSAmpliconMatchingWorkflow().run(configuration(force: false))
        let locked = outputDirectory.appendingPathComponent("sampleA-12s.lungfish12s/locked", isDirectory: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let operationCenter = OperationCenter()
        operationCenter.failureReportStore = .temporaryForTesting()
        let service = WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: InProcessTwelveSMatchCLI(reference: reference, locked: locked)
        )
        do {
            _ = try await service.run(.twelveSAmpliconMatching(configuration(force: true)))
            XCTFail("a bundle that cannot be written must fail the run")
        } catch LocalWorkflowExecutionError.nonZeroExit(let status) {
            XCTAssertEqual(status, 1)
        }

        let aside = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
                .first { $0.hasPrefix(".sampleA-12s.lungfish12s.replaced-") }
        )
        let asidePath = outputDirectory.standardizedFileURL.appendingPathComponent(aside, isDirectory: true).path
        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.errorMessage, "12S amplicon matching failed")
        let detail = try XCTUnwrap(item.errorDetail)
        XCTAssertTrue(
            detail.components(separatedBy: "\n").contains(
                "The earlier 12S result could not be moved back to sampleA-12s.lungfish12s, and it waits at \(asidePath)."
            ),
            detail
        )
    }

    // MARK: Walk F7, a clean run beside or over an earlier result

    private struct Fixtures {
        let root: URL
        let reference: URL
        let reads: URL
        let outputDirectory: URL

        func configuration(name: String = "sampleA-12s", force: Bool = false) -> TwelveSAmpliconMatchingConfiguration {
            TwelveSAmpliconMatchingConfiguration(
                inputFASTQs: [reads],
                referenceFASTA: reference,
                outputDirectory: outputDirectory,
                outputName: name,
                minimumSoftClipBases: 2,
                threads: 1,
                runChimeraReview: false,
                forceOverwrite: force
            )
        }

        func bundle(_ name: String) -> URL {
            outputDirectory.appendingPathComponent("\(name).lungfish12s", isDirectory: true).standardizedFileURL
        }
    }

    private func makeFixtures() throws -> Fixtures {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwelveSEarlierResultRestoreFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let reference = root.appendingPathComponent("reference.fa")
        try ">human (Homo sapiens)|locus=12S|len=8\nACGTACGT\n".write(to: reference, atomically: true, encoding: .utf8)
        let reads = root.appendingPathComponent("sampleA.fastq")
        try "@read1\nTTACGTACGTGG\n+\nIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        return Fixtures(
            root: root,
            reference: reference,
            reads: reads,
            outputDirectory: root.appendingPathComponent("results", isDirectory: true)
        )
    }

    /// The app's own refresher reaches for the running app, which a test has none of.
    private final class RecordingResultRefresher: WorkflowOperationResultRefreshing, @unchecked Sendable {
        private(set) var invocations: [URL] = []

        @MainActor
        func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) async {
            invocations.append(preferredSelectionURL.standardizedFileURL)
        }
    }

    private func makeService(
        _ operationCenter: OperationCenter,
        resultRefresher: RecordingResultRefresher
    ) -> WorkflowOperationExecutionService {
        operationCenter.failureReportStore = .temporaryForTesting()
        return WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: InProcessTwelveSMatchCLI(),
            resultRefresher: resultRefresher
        )
    }

    func testACleanForcedRerunOverAnEarlierResultReadsCompletedAndAdoptsTheBundleItWrote() async throws {
        let fixtures = try makeFixtures()
        _ = try await TwelveSAmpliconMatchingWorkflow().run(fixtures.configuration())
        let bundle = fixtures.bundle("sampleA-12s")
        let earlierRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertFalse(earlierRecord.argv.contains("--force"))

        let operationCenter = OperationCenter()
        let refresher = RecordingResultRefresher()
        let outputs = try await makeService(operationCenter, resultRefresher: refresher)
            .run(.twelveSAmpliconMatching(fixtures.configuration(force: true)))

        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertEqual(item.logEntries.filter { $0.level == .warning }.map(\.message), [])
        XCTAssertEqual(outputs.first?.path, bundle.path)
        XCTAssertEqual(refresher.invocations.map(\.path), [bundle.path])
        // The record in the bundle is the forced run's, so the bundle is the one the CLI wrote.
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundle))
        XCTAssertTrue(record.argv.contains("--force"), "\(record.argv)")
        XCTAssertNotEqual(record.id, earlierRecord.id)
        // The earlier result is gone, with no set-aside folder left in the output directory.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixtures.outputDirectory.path).sorted(),
            ["sampleA-12s.lungfish12s"]
        )
    }

    func testACleanRunBesideAnEarlierResultReadsCompletedAndAdoptsTheBundleItWrote() async throws {
        let fixtures = try makeFixtures()
        _ = try await TwelveSAmpliconMatchingWorkflow().run(fixtures.configuration(name: "sampleA-12s"))
        let earlierBundle = fixtures.bundle("sampleA-12s")
        let earlierRecord = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: earlierBundle))

        let operationCenter = OperationCenter()
        let refresher = RecordingResultRefresher()
        let outputs = try await makeService(operationCenter, resultRefresher: refresher).run(
            .twelveSAmpliconMatching(fixtures.configuration(name: "sampleB-12s"))
        )

        let newBundle = fixtures.bundle("sampleB-12s")
        let item = try XCTUnwrap(operationCenter.items.first)
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertEqual(outputs.first?.path, newBundle.path)
        XCTAssertEqual(refresher.invocations.map(\.path), [newBundle.path])
        XCTAssertTrue(outputs.allSatisfy { !$0.path.hasPrefix(earlierBundle.path) }, "\(outputs)")
        XCTAssertEqual(item.targetBundleURL?.standardizedFileURL.path, newBundle.path)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: newBundle))
        XCTAssertTrue(record.argv.contains("sampleB-12s"), "\(record.argv)")
        XCTAssertEqual(try XCTUnwrap(ProvenanceEnvelopeReader.load(from: earlierBundle)).id, earlierRecord.id)
    }
}

/// `lungfish-cli fastq 12s-match` run in this process as the shipped CLI runs
/// it. The app's arguments are parsed by the CLI's parser, the workflow runs
/// with the command's configuration and writes the CLI's progress lines to
/// standard error, a success ends with the command's last line on standard
/// output, and a failure ends with the text `lungfish-cli` prints for its
/// error and exit status 1. When the run starts writing its bundle, the reference is removed,
/// so writing fails, and a folder that cannot be emptied is left in the new
/// bundle, so the earlier result cannot take its place again.
private final class InProcessTwelveSMatchCLI: LocalWorkflowCLIProcessRunning {
    private let sabotage: (reference: URL, locked: URL)?

    init(reference: URL, locked: URL) {
        sabotage = (reference, locked)
    }

    /// A run that nothing disturbs.
    init() {
        sabotage = nil
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        XCTAssertEqual(Array(arguments.prefix(2)), ["fastq", "12s-match"])
        let command = try FastqTwelveSMatchSubcommand.parse(Array(arguments.dropFirst(2)))
        let standardError = OSAllocatedUnfairLock(initialState: "")
        let sabotage = self.sabotage
        do {
            let result = try await TwelveSAmpliconMatchingWorkflow().run(try command.configurationForTesting()) { fraction, message in
                standardError.withLock { $0 += FastqTwelveSMatchSubcommand.progressLine(fraction: fraction, message: message) }
                guard message == "Writing 12S result bundle tables.", let sabotage else { return }
                try? FileManager.default.removeItem(at: sabotage.reference)
                try? FileManager.default.createDirectory(at: sabotage.locked, withIntermediateDirectories: true)
                try? Data("held\n".utf8).write(to: sabotage.locked.appendingPathComponent("held.txt"))
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sabotage.locked.path)
            }
            // The command's last line, built as the command builds it, on standard output.
            return LocalWorkflowCLIProcessResult(
                exitCode: 0,
                standardOutput: TwelveSCLISuccessLine.matchResult(result.bundleURL).text + "\n",
                standardError: standardError.withLock { $0 }
            )
        } catch {
            standardError.withLock { $0 += LungfishCLI.fullMessage(for: error) + "\n" }
            return LocalWorkflowCLIProcessResult(exitCode: 1, standardOutput: "", standardError: standardError.withLock { $0 })
        }
    }

    func cancel() {}
}
