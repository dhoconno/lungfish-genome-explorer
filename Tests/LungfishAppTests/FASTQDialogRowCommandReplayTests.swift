// FASTQDialogRowCommandReplayTests.swift - The command a dialog row shows after its run replays to the same payload
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md, "Tests that enforce it". Each test copies
// one source bundle into two sibling roots, A and B. It runs a derivative on
// root A through the FASTQ operations dialog's execution service and importer,
// with the real `lungfish-cli` subcommand in this process, registers the row
// with `beginFASTQLaunchRequestOperation` and applies
// `FASTQOperationRowCommand` after the run. It then rebases the row's command
// onto root B, runs it in this process and compares the payload each root
// holds. The pasted command writes the payload file, not the `.lungfishfastq`
// wrapper around it, so only the payload is compared. The class name ends in
// ReplayTests, which sends it to the integration tier
// (scripts/full-suite-gate.sh, REPLAY_SUITES).

import Darwin
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQDialogRowCommandReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        // The physical path (/private/var, not /var), which the input
        // resolvers hand the CLI, so the paths the test rebases agree.
        let made = try TestTempDirectory.make(prefix: "fastq-dialog-row-replay")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        scratch = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(scratch)
    }

    /// Two sibling roots that hold the same source bundle with identical bytes.
    private func makeRoots() throws -> (rootA: URL, rootB: URL, sourceA: URL, sourceB: URL) {
        let staging = scratch.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let bundle = try FASTQOperationTestHelper.makeBundle(named: "Sample 1", in: staging)
        try FASTQOperationTestHelper.writeSyntheticFASTQ(to: bundle.fastqURL, readCount: 6, readLength: 24)

        var sources: [URL] = []
        var roots: [URL] = []
        for name in ["A", "B"] {
            let root = scratch.appendingPathComponent(name, isDirectory: true)
            let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
            let copy = imports.appendingPathComponent(bundle.bundleURL.lastPathComponent, isDirectory: true)
            try FileManager.default.copyItem(at: bundle.bundleURL, to: copy)
            roots.append(root)
            sources.append(copy)
        }
        return (roots[0], roots[1], sources[0], sources[1])
    }

    private func assertTheRowReplaysToTheSamePayload(
        of request: FASTQDerivativeRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        // 1. Two sibling roots with identical bytes.
        let (rootA, rootB, sourceA, sourceB) = try makeRoots()
        OutputEquivalence.assertSame(sourceA, sourceB, kind: .bundle, file: file, line: line)

        // 2. The GUI path on root A. The row is registered before the run,
        // and the refinement is applied after it, as the launch site does.
        let launch = FASTQOperationLaunchRequest.derivative(
            request: request, inputURLs: [sourceA], outputMode: .perInput
        )
        let destination = rootA.appendingPathComponent("Project.lungfish/Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let writer = AppFASTQOutputBundleWriter(
            ingestor: DialogRowCopyingIngestor(),
            statisticsCalculator: AppFASTQOutputBundleWriter.swiftReaderStatisticsCalculator
        )
        let service = FASTQOperationExecutionService(
            commandRunner: DialogRowInProcessCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destination, fastqBundleWriter: writer)
        )
        let reporter = RecordingOperationReporter()
        let id = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: service,
            routeContext: nil,
            reporter: reporter
        ) { _ in }.requireStarted()
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand, file: file, line: line)
        XCTAssertTrue(begun.contains("<derived>"), "the row records the placeholder at begin", file: file, line: line)

        let result = try await service.execute(
            request: launch,
            workingDirectory: rootA.appendingPathComponent("work", isDirectory: true)
        )
        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        let bundleA = try XCTUnwrap(result.importedURLs.first, file: file, line: line)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: bundleA), file: file, line: line)
        let payloadA = bundleA.appendingPathComponent(manifest.rootFASTQFilename)
        let recorded = try XCTUnwrap(reporter.items.first?.cliCommand, file: file, line: line)
        XCTAssertEqual(recorded, manifest.operation.toolCommand, "the row holds the manifest's command", file: file, line: line)
        XCTAssertFalse(recorded.contains("<derived>"), recorded, file: file, line: line)
        XCTAssertEqual(try RecordedCLICommand.parseScript(recorded).count, 1, file: file, line: line)

        // 3. The recorded command on root B, in this process.
        let rebased = try RecordedCLICommand.rebased(recorded, from: rootA, to: rootB)
        let payloadB = URL(fileURLWithPath: payloadA.path.replacingOccurrences(of: rootA.path, with: rootB.path))
        try FileManager.default.createDirectory(at: payloadB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await RecordedCLICommand.runInProcess(rebased)

        // 4. The two payloads are the same file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: payloadB.path), "the pasted command wrote \(payloadB.path)", file: file, line: line)
        OutputEquivalence.assertSame(payloadA, payloadB, kind: .files, file: file, line: line)
    }

    func testAReverseComplementRowReplaysToTheSamePayload() async throws {
        try await assertTheRowReplaysToTheSamePayload(of: .reverseComplement)
    }

    func testALengthFilterRowReplaysToTheSamePayload() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            try ToolAvailability.skipOrFail("managed seqkit is not installed")
        }
        try await assertTheRowReplaysToTheSamePayload(of: .lengthFilter(min: 10, max: 40))
    }
}
