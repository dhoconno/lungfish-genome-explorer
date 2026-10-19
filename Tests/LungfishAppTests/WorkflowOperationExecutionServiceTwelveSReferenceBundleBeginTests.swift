// WorkflowOperationExecutionServiceTwelveSReferenceBundleBeginTests.swift - The 12S reference bundle row's command parses to the build
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp
@testable import LungfishCLI
import XCTest

/// Phase 2.12 lane 12.21 (QR-b). `WorkflowOperationExecutionService.runTwelveSReferenceBundleBuild`
/// records the `lungfish-cli fastq 12s-reference-bundle` command on its
/// Operations panel row. These tests run the real site on a process runner that
/// records its argv, read the command off the row, and parse it with the real CLI
/// leaf (`FastqTwelveSReferenceBundleSubcommand`) the way the shipped binary
/// does. The parsed build must be the one the dialog asked for, and the command
/// must be the argv the site launched (docs/contracts/CLI-EQUIVALENCE.md).
@MainActor
final class WorkflowOperationExecutionServiceTwelveSReferenceBundleBeginTests: XCTestCase {

    private struct Fixture {
        let deduplicatedFASTA: URL
        let midoriMetadata: URL
        let sourceFile: URL
        let sourceDirectory: URL
        let outputURL: URL
    }

    /// Every input sits in a scratch folder the test removes. A name and a source
    /// file with a space make the recorded command quote them.
    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "twelves-reference-begin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let deduplicatedFASTA = root.appendingPathComponent("amplicons_12s_deduplicated.fa")
        let midoriMetadata = root.appendingPathComponent("12s_reference.tsv")
        let sourceFile = root.appendingPathComponent("midori notes.txt")
        let sourceDirectory = root.appendingPathComponent("midori-source", isDirectory: true)
        try Data(">target\nACGT\n".utf8).write(to: deduplicatedFASTA)
        try Data("seq_id\tlatin_name\tgroup\ttaxid\tcommon_name\n".utf8).write(to: midoriMetadata)
        try Data("notes\n".utf8).write(to: sourceFile)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        return Fixture(
            deduplicatedFASTA: deduplicatedFASTA,
            midoriMetadata: midoriMetadata,
            sourceFile: sourceFile,
            sourceDirectory: sourceDirectory,
            outputURL: root.appendingPathComponent(
                "Reference Sequences/MIDORI-12S.lungfish12sref",
                isDirectory: true
            )
        )
    }

    private struct SiteRun {
        let outputs: [URL]
        let operationCenter: OperationCenter
        let refresher: RecordingBeginSiteResultRefresher
        let runner: RecordingBeginSiteCLIRunner
        let command: String
    }

    /// Runs the real site. The runner leaves the bundle and the provenance the
    /// shipped command writes, so the row ends complete, the way a clean build ends.
    private func runSite(_ configuration: TwelveSReferenceBundleBuildConfiguration) async throws -> SiteRun {
        let operationCenter = OperationCenter()
        let refresher = RecordingBeginSiteResultRefresher()
        let runner = RecordingBeginSiteCLIRunner { arguments in
            try BeginSiteTesting.writeTwelveSReferenceBundle(
                launchedArguments: arguments,
                bundleURL: configuration.outputURL,
                name: "MIDORI 12S"
            )
        }
        let service = BeginSiteTesting.makeService(
            operationCenter: operationCenter,
            runner: runner,
            refresher: refresher
        )

        let outputs = try await service.runTwelveSReferenceBundleBuild(configuration)

        return SiteRun(
            outputs: outputs,
            operationCenter: operationCenter,
            refresher: refresher,
            runner: runner,
            command: try BeginSiteTesting.recordedCommand(of: operationCenter, launchedBy: runner)
        )
    }

    /// The row, the outputs, the refresh and the working directory of a clean build.
    private func assertCleanBuild(
        _ run: SiteRun,
        of configuration: TwelveSReferenceBundleBuildConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = configuration.outputURL.standardizedFileURL
        let item = try XCTUnwrap(run.operationCenter.items.first, file: file, line: line)
        XCTAssertEqual(item.title, "12S Reference Bundle", file: file, line: line)
        XCTAssertEqual(item.operationType, .workflow, file: file, line: line)
        XCTAssertEqual(item.targetBundleURL?.standardizedFileURL, bundle, file: file, line: line)
        XCTAssertEqual(item.state, .completed, file: file, line: line)
        XCTAssertEqual(item.displayStateLabel, "Completed", file: file, line: line)
        XCTAssertEqual(run.outputs.first?.path, bundle.path, file: file, line: line)
        XCTAssertTrue(
            run.outputs.map(\.path).contains(bundle.appendingPathComponent(".lungfish-provenance.json").path),
            "\(run.outputs)",
            file: file,
            line: line
        )
        XCTAssertEqual(run.refresher.invocations, [bundle], file: file, line: line)
        XCTAssertEqual(
            run.runner.invocations.first?.workingDirectory,
            bundle.deletingLastPathComponent().standardizedFileURL,
            file: file,
            line: line
        )
    }

    /// Every choice of the dialog is on the command, and the CLI reads each back.
    func testTheRowCommandOfABuildWithEveryChoiceParsesToTheSameBuild() async throws {
        let fixture = try makeFixture()
        let configuration = TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: fixture.deduplicatedFASTA,
            midoriMetadataTSV: fixture.midoriMetadata,
            outputURL: fixture.outputURL,
            name: "MIDORI 12S",
            sourceFiles: [fixture.sourceFile],
            sourceDirectories: [fixture.sourceDirectory],
            forceOverwrite: true
        )

        let run = try await runSite(configuration)

        try assertCleanBuild(run, of: configuration)
        let parsed = try RecordedCLICommand.parse(run.command, as: FastqTwelveSReferenceBundleSubcommand.self)
        let cli = parsed.configurationForTesting()
        XCTAssertEqual(cli.deduplicatedFASTA.path, configuration.deduplicatedFASTA.path, run.command)
        XCTAssertEqual(cli.midoriMetadataTSV.path, configuration.midoriMetadataTSV.path, run.command)
        XCTAssertEqual(cli.outputURL.path, configuration.outputURL.path, run.command)
        XCTAssertEqual(cli.name, "MIDORI 12S", run.command)
        XCTAssertEqual(cli.sourceFiles.map(\.path), configuration.sourceFiles.map(\.path), run.command)
        XCTAssertEqual(cli.sourceDirectories.map(\.path), configuration.sourceDirectories.map(\.path), run.command)
        XCTAssertTrue(cli.forceOverwrite, run.command)
        // The CLI's replay argv, which its provenance keeps, is the command the row shows.
        XCTAssertEqual(
            cli.argv,
            [CLICommandIdentity.executableName] + (run.runner.invocations.first?.arguments ?? []),
            run.command
        )
    }

    /// A build with no choices records no optional flag, and a name of blanks is
    /// not a name, so the CLI reads the defaults back.
    func testTheRowCommandOfABuildWithNoChoicesNamesOnlyTheThreeInputsAndParsesToTheDefaults() async throws {
        let fixture = try makeFixture()
        let configuration = TwelveSReferenceBundleBuildConfiguration(
            deduplicatedFASTA: fixture.deduplicatedFASTA,
            midoriMetadataTSV: fixture.midoriMetadata,
            outputURL: fixture.outputURL,
            name: "   "
        )

        let run = try await runSite(configuration)

        try assertCleanBuild(run, of: configuration)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), [
            "fastq", "12s-reference-bundle",
            "--dedup-fasta", configuration.deduplicatedFASTA.path,
            "--midori-metadata", configuration.midoriMetadataTSV.path,
            "--output", configuration.outputURL.path,
        ])
        let parsed = try RecordedCLICommand.parse(run.command, as: FastqTwelveSReferenceBundleSubcommand.self)
        let cli = parsed.configurationForTesting()
        XCTAssertEqual(cli.deduplicatedFASTA.path, configuration.deduplicatedFASTA.path, run.command)
        XCTAssertEqual(cli.outputURL.path, configuration.outputURL.path, run.command)
        XCTAssertNil(cli.name, run.command)
        XCTAssertEqual(cli.sourceFiles, [], run.command)
        XCTAssertEqual(cli.sourceDirectories, [], run.command)
        XCTAssertFalse(cli.forceOverwrite, run.command)
    }
}
