// WorkflowOperationExecutionServiceTwelveSAmpliconMatchingBeginTests.swift - The 12S amplicon matching row's command parses to the run
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

/// Phase 2.12 lane 12.21 (QR-b). `WorkflowOperationExecutionService.runTwelveSAmpliconMatching`,
/// which `run(.twelveSAmpliconMatching(_))` reaches, records the
/// `lungfish-cli fastq 12s-match` command on its Operations panel row. These
/// tests run the real site on a process runner that records its argv, read the
/// command off the row, and parse it with the real CLI leaf
/// (`FastqTwelveSMatchSubcommand`) the way the shipped binary does. The parsed
/// run must be the one the dialog asked for, and the command must be the argv
/// the site launched (docs/contracts/CLI-EQUIVALENCE.md).
@MainActor
final class WorkflowOperationExecutionServiceTwelveSAmpliconMatchingBeginTests: XCTestCase {

    private struct Fixture {
        let firstReads: URL
        let secondReads: URL
        let reference: URL
        let referenceMetadata: URL
        let sampleMetadata: URL
        let outputDirectory: URL
    }

    /// Every input sits in a scratch folder the test removes. The output folder
    /// has a space in its name, as the app's own `12S amplicon results` folder does.
    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "twelves-match-begin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let firstReads = root.appendingPathComponent("hilo-f09.lungfishfastq", isDirectory: true)
        let secondReads = root.appendingPathComponent("hilo-f10.lungfishfastq", isDirectory: true)
        let reference = root.appendingPathComponent("amplicons_12s.fa")
        let referenceMetadata = root.appendingPathComponent("12s-target-metadata.tsv")
        let sampleMetadata = root.appendingPathComponent("analysis-metadata.tsv")
        for directory in [firstReads, secondReads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data(">target\nACGT\n".utf8).write(to: reference)
        try Data("target_id\tscientific_name\n".utf8).write(to: referenceMetadata)
        try Data("sample_id\tsite\nhilo-f09\tHilo WWTP\n".utf8).write(to: sampleMetadata)
        return Fixture(
            firstReads: firstReads,
            secondReads: secondReads,
            reference: reference,
            referenceMetadata: referenceMetadata,
            sampleMetadata: sampleMetadata,
            outputDirectory: root.appendingPathComponent("Analyses/12S amplicon results", isDirectory: true)
        )
    }

    private struct SiteRun {
        let outputs: [URL]
        let operationCenter: OperationCenter
        let refresher: RecordingBeginSiteResultRefresher
        let runner: RecordingBeginSiteCLIRunner
        let command: String
    }

    private func bundleURL(for configuration: TwelveSAmpliconMatchingConfiguration) -> URL {
        configuration.outputDirectory
            .appendingPathComponent("\(configuration.outputName).lungfish12s", isDirectory: true)
            .standardizedFileURL
    }

    /// Runs the real site through `run(_:)`. The runner leaves the provenance the
    /// shipped command writes, so the row ends complete, the way a clean run ends.
    private func runSite(_ configuration: TwelveSAmpliconMatchingConfiguration) async throws -> SiteRun {
        let operationCenter = OperationCenter()
        let refresher = RecordingBeginSiteResultRefresher()
        let bundle = bundleURL(for: configuration)
        let runner = RecordingBeginSiteCLIRunner { arguments in
            try BeginSiteTesting.writeTwelveSProvenance(
                workflowName: "lungfish fastq 12s-match",
                launchedArguments: arguments,
                bundleURL: bundle
            )
        }
        let service = BeginSiteTesting.makeService(
            operationCenter: operationCenter,
            runner: runner,
            refresher: refresher
        )

        let outputs = try await service.run(.twelveSAmpliconMatching(configuration))

        return SiteRun(
            outputs: outputs,
            operationCenter: operationCenter,
            refresher: refresher,
            runner: runner,
            command: try BeginSiteTesting.recordedCommand(of: operationCenter, launchedBy: runner)
        )
    }

    /// The row, the outputs, the refresh and the working directory of a clean run.
    private func assertCleanRun(
        _ run: SiteRun,
        of configuration: TwelveSAmpliconMatchingConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = bundleURL(for: configuration)
        let item = try XCTUnwrap(run.operationCenter.items.first, file: file, line: line)
        XCTAssertEqual(item.title, "12S Amplicon Matching", file: file, line: line)
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
            configuration.outputDirectory.standardizedFileURL,
            file: file,
            line: line
        )
    }

    /// Every choice of the dialog is on the command, and the CLI reads each back.
    func testTheRowCommandOfARunWithEveryChoiceParsesToTheSameConfiguration() async throws {
        let fixture = try makeFixture()
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fixture.firstReads, fixture.secondReads],
            referenceFASTA: fixture.reference,
            referenceMetadata: fixture.referenceMetadata,
            sampleMetadata: fixture.sampleMetadata,
            outputDirectory: fixture.outputDirectory,
            outputName: "hilo-12s",
            minimumSoftClipBases: 2,
            maximumIndelBases: 5,
            matchingMode: .ontIndel,
            threads: 6,
            runChimeraReview: false,
            forceOverwrite: true,
            ambiguityResolution: .conservative(minFoldRatio: 2.0, absoluteFloor: 10)
        )

        let run = try await runSite(configuration)

        try assertCleanRun(run, of: configuration)
        let parsed = try RecordedCLICommand.parse(run.command, as: FastqTwelveSMatchSubcommand.self)
        let cli = try parsed.configurationForTesting()
        // Paths, not URL values, because a URL the dialog built carries a
        // directory flag the parsed path does not.
        XCTAssertEqual(cli.inputFASTQs.map(\.path), configuration.inputFASTQs.map(\.path), run.command)
        XCTAssertEqual(cli.referenceFASTA.path, configuration.referenceFASTA.path, run.command)
        XCTAssertEqual(cli.referenceMetadata?.path, configuration.referenceMetadata?.path, run.command)
        XCTAssertNil(cli.referenceBundleURL, run.command)
        XCTAssertEqual(cli.sampleMetadata?.path, configuration.sampleMetadata?.path, run.command)
        XCTAssertEqual(cli.outputDirectory.path, configuration.outputDirectory.path, run.command)
        XCTAssertEqual(cli.outputName, "hilo-12s", run.command)
        XCTAssertEqual(cli.minimumSoftClipBases, 2, run.command)
        XCTAssertEqual(cli.maximumIndelBases, 5, run.command)
        XCTAssertEqual(cli.matchingMode, .ontIndel, run.command)
        XCTAssertEqual(cli.threads, 6, run.command)
        XCTAssertFalse(cli.runChimeraReview, run.command)
        XCTAssertTrue(cli.forceOverwrite, run.command)
        XCTAssertEqual(cli.ambiguityResolution, .conservative(minFoldRatio: 2.0, absoluteFloor: 10), run.command)
        // The CLI's replay argv, which its provenance keeps, is the command the row shows.
        XCTAssertEqual(
            cli.argv,
            [CLICommandIdentity.executableName] + (run.runner.invocations.first?.arguments ?? []),
            run.command
        )
    }

    /// A run with no choices names the mode and the thread count, since the CLI's
    /// own thread default is every core, and leaves every other default out.
    func testTheRowCommandOfARunWithNoChoicesNamesTheModeAndThreadsAndParsesToTheDefaults() async throws {
        let fixture = try makeFixture()
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fixture.firstReads],
            referenceFASTA: fixture.reference,
            outputDirectory: fixture.outputDirectory,
            outputName: "hilo-12s",
            threads: 1
        )

        let run = try await runSite(configuration)

        try assertCleanRun(run, of: configuration)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), [
            "fastq", "12s-match", configuration.inputFASTQs[0].path,
            "--reference", configuration.referenceFASTA.path,
            "--output-dir", configuration.outputDirectory.path,
            "--output-name", "hilo-12s",
            "--matching-mode", "illumina-exact",
            "--threads", "1",
        ])
        let parsed = try RecordedCLICommand.parse(run.command, as: FastqTwelveSMatchSubcommand.self)
        let cli = try parsed.configurationForTesting()
        XCTAssertEqual(cli.inputFASTQs.map(\.path), configuration.inputFASTQs.map(\.path), run.command)
        XCTAssertNil(cli.referenceMetadata, run.command)
        XCTAssertNil(cli.sampleMetadata, run.command)
        XCTAssertEqual(cli.minimumSoftClipBases, 1, run.command)
        XCTAssertEqual(cli.maximumIndelBases, 3, run.command)
        XCTAssertEqual(cli.matchingMode, .illuminaExact, run.command)
        XCTAssertEqual(cli.threads, 1, run.command)
        XCTAssertTrue(cli.runChimeraReview, run.command)
        XCTAssertFalse(cli.forceOverwrite, run.command)
        XCTAssertEqual(cli.ambiguityResolution, .anyNonzeroLead, run.command)
    }

    /// A reference bundle goes on the command as the bundle. Its own target
    /// metadata is not named again, and the CLI finds the same reference FASTA and
    /// the same metadata inside the bundle that the dialog chose.
    func testTheRowCommandOfARunOnAReferenceBundleNamesTheBundleAndParsesToItsMembers() async throws {
        let fixture = try makeFixture()
        let bundle = fixture.reference.deletingLastPathComponent()
            .appendingPathComponent("MIDORI-12S.\(TwelveSReferenceBundle.directoryExtension)", isDirectory: true)
        try BeginSiteTesting.writeTwelveSReferenceBundleContents(at: bundle, name: "MIDORI 12S")
        let bundledFASTA = try XCTUnwrap(TwelveSReferenceBundle.referenceFASTAURL(in: bundle))
        let bundledMetadata = try XCTUnwrap(TwelveSReferenceBundle.targetMetadataURL(in: bundle))
        let configuration = TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fixture.firstReads],
            referenceFASTA: bundledFASTA,
            referenceMetadata: bundledMetadata,
            referenceBundleURL: bundle,
            outputDirectory: fixture.outputDirectory,
            outputName: "hilo-12s",
            threads: 2
        )

        let run = try await runSite(configuration)

        try assertCleanRun(run, of: configuration)
        let words = try RecordedCLICommand.arguments(of: run.command)
        XCTAssertEqual(words.firstIndex(of: "--reference").map { words[$0 + 1] }, bundle.standardizedFileURL.path)
        XCTAssertFalse(words.contains("--reference-metadata"), run.command)
        let parsed = try RecordedCLICommand.parse(run.command, as: FastqTwelveSMatchSubcommand.self)
        let cli = try parsed.configurationForTesting()
        XCTAssertEqual(cli.referenceBundleURL?.path, bundle.standardizedFileURL.path, run.command)
        XCTAssertEqual(cli.referenceFASTA.path, bundledFASTA.path, run.command)
        XCTAssertEqual(cli.referenceMetadata?.path, bundledMetadata.path, run.command)
        XCTAssertEqual(cli.threads, 2, run.command)
    }
}
