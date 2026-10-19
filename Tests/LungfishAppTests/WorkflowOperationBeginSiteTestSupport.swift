// WorkflowOperationBeginSiteTestSupport.swift - Stand-ins for the parse tests of the WorkflowOperationExecutionService begin sites
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.21 (QR-b). Four begin sites of WorkflowOperationExecutionService
// (the 12S reference bundle build, 12S amplicon matching, MiSeq amplicon
// genotyping and full-length ONT MHC genotyping) record the lungfish-cli command
// they launch on their Operations panel row. Each parse test runs the real site on
// these stand-ins, reads the command off the row, and parses it with the real
// CLI parser (RecordedCLICommand.parse in the test file itself).

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow
@testable import LungfishApp
import XCTest

/// The process a begin site launches, as a test sees it. It records the
/// arguments and the working directory the site hands to `runLungfishCLI`, lets
/// a test write what the shipped command leaves behind, and returns at once
/// with an empty output, so no tool runs.
@MainActor
final class RecordingBeginSiteCLIRunner: LocalWorkflowCLIProcessRunning {
    struct Invocation: Equatable {
        let arguments: [String]
        let workingDirectory: URL
    }

    typealias Produce = @MainActor ([String]) throws -> Void

    private(set) var invocations: [Invocation] = []
    private(set) var cancelCount = 0
    private let exitCode: Int32
    private let produce: Produce?

    init(exitCode: Int32 = 0, produce: Produce? = nil) {
        self.exitCode = exitCode
        self.produce = produce
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        invocations.append(Invocation(
            arguments: arguments,
            workingDirectory: workingDirectory.standardizedFileURL
        ))
        try produce?(arguments)
        return LocalWorkflowCLIProcessResult(exitCode: exitCode, standardOutput: "", standardError: "")
    }

    func cancel() {
        cancelCount += 1
    }
}

/// The app's own refresher reaches for the running app, which a test has none of.
@MainActor
final class RecordingBeginSiteResultRefresher: WorkflowOperationResultRefreshing {
    private(set) var invocations: [URL] = []

    func refresh(routeContext: OperationRouteContext?, preferredSelectionURL: URL) async {
        invocations.append(preferredSelectionURL.standardizedFileURL)
    }
}

enum BeginSiteTesting {
    /// The service on a fresh operation center, the recording runner and the recording refresher.
    @MainActor
    static func makeService(
        operationCenter: OperationCenter,
        runner: RecordingBeginSiteCLIRunner,
        refresher: RecordingBeginSiteResultRefresher
    ) -> WorkflowOperationExecutionService {
        operationCenter.failureReportStore = .temporaryForTesting()
        return WorkflowOperationExecutionService(
            operationCenter: operationCenter,
            processRunner: runner,
            resultRefresher: refresher
        )
    }

    /// The command the only row of `operationCenter` recorded, after the three checks
    /// every begin site shares. The site launched the CLI once. The row's log shows
    /// the recorded command. The command's words are the argv the CLI was launched
    /// with (docs/contracts/CLI-EQUIVALENCE.md).
    @MainActor
    static func recordedCommand(
        of operationCenter: OperationCenter,
        launchedBy runner: RecordingBeginSiteCLIRunner,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        XCTAssertEqual(operationCenter.items.count, 1, "one begin makes one row", file: file, line: line)
        let item = try XCTUnwrap(operationCenter.items.first, file: file, line: line)
        let command = try XCTUnwrap(item.cliCommand, "the row records a command", file: file, line: line)
        XCTAssertEqual(runner.invocations.count, 1, "the site launches the CLI once", file: file, line: line)
        let launched = try XCTUnwrap(runner.invocations.first, file: file, line: line)
        XCTAssertEqual(
            try RecordedCLICommand.arguments(of: command),
            launched.arguments,
            "the row's command is the argv the CLI was launched with",
            file: file,
            line: line
        )
        XCTAssertTrue(
            item.logEntries.contains { $0.message == command },
            "the row's log shows the recorded command",
            file: file,
            line: line
        )
        return command
    }

    /// What a shipped 12S command leaves in the bundle it wrote, which the app
    /// checks before it reports the row complete. The envelope names the workflow,
    /// exits 0, holds the argv the CLI got, and lists the bundle among its outputs.
    @MainActor
    static func writeTwelveSProvenance(
        workflowName: String,
        launchedArguments: [String],
        bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let argv = [CLICommandIdentity.executableName] + launchedArguments
        let envelope = ProvenanceEnvelope(
            workflowName: workflowName,
            workflowVersion: "1",
            toolName: CLICommandIdentity.executableName,
            toolVersion: "1",
            argv: argv,
            durableReplayArgv: argv,
            runtimeIdentity: ProvenanceRuntimeIdentity(user: "tests"),
            outputs: [
                ProvenanceFileDescriptor(path: bundleURL.path, role: .output),
            ],
            exitStatus: 0
        )
        try ProvenanceJSON.encoder.encode(envelope).write(
            to: bundleURL.appendingPathComponent(".lungfish-provenance.json")
        )
    }

    /// The files of a `.lungfish12sref` bundle that the app reads back, which are the
    /// reference FASTA, the target metadata and the manifest that names both.
    static func writeTwelveSReferenceBundleContents(at bundleURL: URL, name: String) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(">target\nACGT\n".utf8).write(to: bundleURL.appendingPathComponent("reference.fa"))
        try Data("target_id\tscientific_name\n".utf8).write(to: bundleURL.appendingPathComponent("target-metadata.tsv"))
        try TwelveSReferenceBundle.writeManifest(
            TwelveSReferenceBundleManifest(
                name: name,
                referenceFastaPath: "reference.fa",
                targetMetadataPath: "target-metadata.tsv",
                sourceFiles: [],
                metrics: TwelveSReferenceBundleMetrics(
                    referenceCount: 1,
                    metadataRowCount: 1,
                    taxidCount: 1,
                    taxonGroupCount: 1,
                    taxonomyCount: 1,
                    alternateMatchCount: 0
                ),
                provenancePath: ".lungfish-provenance.json",
                createdAt: "2026-05-30T00:00:00Z"
            ),
            to: bundleURL
        )
    }

    /// What the shipped `fastq 12s-reference-bundle` leaves behind, which is the
    /// bundle contents and the provenance that records the command.
    @MainActor
    static func writeTwelveSReferenceBundle(launchedArguments: [String], bundleURL: URL, name: String) throws {
        try writeTwelveSReferenceBundleContents(at: bundleURL, name: name)
        try writeTwelveSProvenance(
            workflowName: "lungfish fastq 12s-reference-bundle",
            launchedArguments: launchedArguments,
            bundleURL: bundleURL
        )
    }
}
