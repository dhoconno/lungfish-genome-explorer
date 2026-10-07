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
}

/// `lungfish-cli fastq 12s-match` run in this process as the shipped CLI runs
/// it. The app's arguments are parsed by the CLI's parser, the workflow runs
/// with the command's configuration and writes the CLI's progress lines, and
/// a failure ends with the text `lungfish-cli` prints for its error and exit
/// status 1. When the run starts writing its bundle, the reference is removed,
/// so writing fails, and a folder that cannot be emptied is left in the new
/// bundle, so the earlier result cannot take its place again.
private final class InProcessTwelveSMatchCLI: LocalWorkflowCLIProcessRunning {
    private let reference: URL
    private let locked: URL

    init(reference: URL, locked: URL) {
        self.reference = reference
        self.locked = locked
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        XCTAssertEqual(Array(arguments.prefix(2)), ["fastq", "12s-match"])
        let command = try FastqTwelveSMatchSubcommand.parse(Array(arguments.dropFirst(2)))
        let standardError = OSAllocatedUnfairLock(initialState: "")
        let reference = self.reference
        let locked = self.locked
        do {
            let result = try await TwelveSAmpliconMatchingWorkflow().run(try command.configurationForTesting()) { fraction, message in
                standardError.withLock { $0 += FastqTwelveSMatchSubcommand.progressLine(fraction: fraction, message: message) }
                guard message == "Writing 12S result bundle tables." else { return }
                try? FileManager.default.removeItem(at: reference)
                try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
                try? Data("held\n".utf8).write(to: locked.appendingPathComponent("held.txt"))
                try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            }
            standardError.withLock { $0 += "12S amplicon result bundle written to \(result.bundleURL.path)\n" }
            return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: "", standardError: standardError.withLock { $0 })
        } catch {
            standardError.withLock { $0 += LungfishCLI.fullMessage(for: error) + "\n" }
            return LocalWorkflowCLIProcessResult(exitCode: 1, standardOutput: "", standardError: standardError.withLock { $0 })
        }
    }

    func cancel() {}
}
