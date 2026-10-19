// WorkflowOperationExecutionServiceFullLengthONTMHCBeginTests.swift - The full-length ONT MHC genotyping row's command parses to the run
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

/// Phase 2.12 lane 12.21 (QR-b). `WorkflowOperationExecutionService.runFullLengthONTMHCGenotyping`,
/// which `run(.fullLengthONTMHCGenotyping(_))` reaches, records the
/// `lungfish-cli fastq full-length-ont-mhc-genotype` command on its Operations
/// panel row. These tests run the real site on a process runner that records its
/// argv, read the command off the row, and parse it with the real CLI leaf
/// (`FastqFullLengthONTMHCGenotypingSubcommand`) the way the shipped binary does.
/// The parsed run must be the one the request describes, and the command must be
/// the argv the site launched (docs/contracts/CLI-EQUIVALENCE.md).
@MainActor
final class WorkflowOperationExecutionServiceFullLengthONTMHCBeginTests: XCTestCase {

    private struct Fixture {
        let root: URL
        let reads: [URL]
        let reference: URL
        let orientReference: URL
        let forwardPrimer: URL
        let reversePrimer: URL
        let outputDirectory: URL
    }

    /// Every input sits in a scratch folder the test removes. The output bundle
    /// path is absent, as it is when the dialog starts a run.
    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "full-length-ont-begin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let reads = ["NB13.lungfishfastq", "NB14.lungfishfastq"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        let reference = root.appendingPathComponent("Mamu-class-I.lungfishmhcref", isDirectory: true)
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        for directory in reads + [reference, analyses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let orientReference = root.appendingPathComponent("MHC_class_I_orient.fasta")
        let forwardPrimer = root.appendingPathComponent("MHC_class_I_F.fasta")
        let reversePrimer = root.appendingPathComponent("MHC_class_I_R.fasta")
        for url in [orientReference, forwardPrimer, reversePrimer] {
            try Data(">x\nACGT\n".utf8).write(to: url)
        }
        return Fixture(
            root: root,
            reads: reads,
            reference: reference,
            orientReference: orientReference,
            forwardPrimer: forwardPrimer,
            reversePrimer: reversePrimer,
            outputDirectory: analyses.appendingPathComponent("nb13-full-length.lungfishgenotype", isDirectory: true)
        )
    }

    private struct SiteRun {
        let outputs: [URL]
        let operationCenter: OperationCenter
        let refresher: RecordingBeginSiteResultRefresher
        let runner: RecordingBeginSiteCLIRunner
        let command: String
        /// Whether the bundle path existed when the CLI was launched.
        let bundleExistedAtLaunch: Bool?
    }

    /// Runs the real site. The runner publishes the bundle, as the shipped command
    /// does in one step, so the row ends complete.
    private func runSite(_ request: FullLengthONTMHCGenotypingRunRequest) async throws -> SiteRun {
        let operationCenter = OperationCenter()
        let refresher = RecordingBeginSiteResultRefresher()
        var bundleExistedAtLaunch: Bool?
        let runner = RecordingBeginSiteCLIRunner { _ in
            bundleExistedAtLaunch = FileManager.default.fileExists(atPath: request.outputDirectory.path)
            try FileManager.default.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        }
        let service = BeginSiteTesting.makeService(
            operationCenter: operationCenter,
            runner: runner,
            refresher: refresher
        )

        let outputs = try await service.run(.fullLengthONTMHCGenotyping(request))

        return SiteRun(
            outputs: outputs,
            operationCenter: operationCenter,
            refresher: refresher,
            runner: runner,
            command: try BeginSiteTesting.recordedCommand(of: operationCenter, launchedBy: runner),
            bundleExistedAtLaunch: bundleExistedAtLaunch
        )
    }

    /// The row, the outputs, the refresh and the working directory of a clean run.
    private func assertCleanRun(
        _ run: SiteRun,
        of request: FullLengthONTMHCGenotypingRunRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = request.outputDirectory.standardizedFileURL
        let item = try XCTUnwrap(run.operationCenter.items.first, file: file, line: line)
        XCTAssertEqual(item.title, "Full-Length ONT MHC Genotyping", file: file, line: line)
        XCTAssertEqual(item.operationType, .workflow, file: file, line: line)
        XCTAssertEqual(item.targetBundleURL?.standardizedFileURL, bundle, file: file, line: line)
        XCTAssertEqual(item.state, .completed, file: file, line: line)
        XCTAssertEqual(item.displayStateLabel, "Completed", file: file, line: line)
        XCTAssertTrue(run.outputs.map(\.path).contains(bundle.path), "\(run.outputs)", file: file, line: line)
        XCTAssertEqual(run.refresher.invocations, [bundle], file: file, line: line)
        XCTAssertEqual(
            run.runner.invocations.first?.workingDirectory,
            bundle.deletingLastPathComponent().standardizedFileURL,
            file: file,
            line: line
        )
        XCTAssertEqual(
            run.bundleExistedAtLaunch,
            false,
            "the app leaves the bundle path absent for the CLI to publish in one step",
            file: file,
            line: line
        )
    }

    /// Every choice of the request is on the command, and the CLI reads each back.
    func testTheRowCommandOfARunWithEveryChoiceParsesToTheSameRun() async throws {
        let fixture = try makeFixture()
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: fixture.reads,
            referenceSourceURL: fixture.reference,
            orientReferenceURL: fixture.orientReference,
            forwardPrimerURL: fixture.forwardPrimer,
            reversePrimerURL: fixture.reversePrimer,
            outputDirectory: fixture.outputDirectory,
            outputName: "nb13-full-length",
            projectURL: fixture.root,
            threads: 8,
            minimumLength: 2_100,
            maximumLength: 3_900,
            savontQualityValueCutoff: 92,
            savontMinimumClusterSize: 4,
            minUnmatchedReads: 6,
            cdnaThreshold: 1_800,
            sampleJobs: 2,
            savontThreadsPerSample: 3,
            keepIntermediates: true,
            reuseCompatibleCheckpoints: true,
            haplotypeDropoutSampleFraction: 0.05,
            haplotypeDropoutLocusFraction: 0.10,
            haplotypeDropoutLocusFractionOverrides: ["MHC-A": 0.2],
            haplotypeAssayID: "MHC-full-length-ONT",
            haplotypeSpeciesCode: "MAMU",
            haplotypeDefinitionScope: .project,
            haplotypeDefinitionSetID: "mamu-class-i-v1"
        )

        let run = try await runSite(request)

        try assertCleanRun(run, of: request)
        let cli = try RecordedCLICommand.parse(run.command, as: FastqFullLengthONTMHCGenotypingSubcommand.self)
        XCTAssertEqual(cli.inputs, request.inputFASTQURLs.map(\.path), run.command)
        XCTAssertEqual(cli.reference, request.referenceSourceURL.path, run.command)
        XCTAssertEqual(cli.orientReference, request.orientReferenceURL?.path, run.command)
        XCTAssertEqual(cli.forwardPrimer, request.forwardPrimerURL?.path, run.command)
        XCTAssertEqual(cli.reversePrimer, request.reversePrimerURL?.path, run.command)
        XCTAssertEqual(cli.outputDir, request.outputDirectory.path, run.command)
        XCTAssertEqual(cli.outputName, "nb13-full-length", run.command)
        XCTAssertEqual(cli.project, request.projectURL?.path, run.command)
        XCTAssertEqual(cli.threads, 8, run.command)
        XCTAssertEqual(cli.sampleJobs, 2, run.command)
        XCTAssertEqual(cli.savontThreadsPerSample, 3, run.command)
        XCTAssertEqual(cli.minLength, 2_100, run.command)
        XCTAssertEqual(cli.maxLength, 3_900, run.command)
        XCTAssertEqual(cli.savontQualityValueCutoff, 92, run.command)
        XCTAssertEqual(cli.savontMinimumClusterSize, 4, run.command)
        XCTAssertEqual(cli.minUnmatchedReads, 6, run.command)
        XCTAssertEqual(cli.cdnaThreshold, 1_800, run.command)
        XCTAssertTrue(cli.keepIntermediates, run.command)
        XCTAssertTrue(cli.reuseCompatibleCheckpoints, run.command)
        XCTAssertEqual(cli.haplotypeMinSamplePercent, 5, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercent, 10, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercentOverrides, ["MHC-A=20"], run.command)
        XCTAssertEqual(cli.haplotypeAssay, "MHC-full-length-ONT", run.command)
        XCTAssertEqual(cli.haplotypeSpecies, "MAMU", run.command)
        XCTAssertEqual(cli.haplotypeDefinitionScope, "project", run.command)
        XCTAssertEqual(cli.haplotypeDefinition, "mamu-class-i-v1", run.command)
    }

    /// A run with no choices names the nine settings the app always names, and no
    /// optional flag, so the CLI reads back its own defaults.
    func testTheRowCommandOfARunWithNoChoicesNamesOnlyTheAlwaysSettingsAndParsesToTheDefaults() async throws {
        let fixture = try makeFixture()
        let request = FullLengthONTMHCGenotypingRunRequest(
            inputFASTQURLs: [fixture.reads[0]],
            referenceSourceURL: fixture.reference,
            outputDirectory: fixture.outputDirectory,
            outputName: "nb13-full-length",
            threads: 4
        )

        let run = try await runSite(request)

        try assertCleanRun(run, of: request)
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), [
            "fastq", "full-length-ont-mhc-genotype", request.inputFASTQURLs[0].path,
            "--reference", request.referenceSourceURL.path,
            "--output-dir", request.outputDirectory.path,
            "--output-name", "nb13-full-length",
            "--threads", "4",
            "--min-length", "2000",
            "--max-length", "4000",
            "--savont-quality-value-cutoff", "90",
            "--savont-min-cluster-size", "3",
            "--min-unmatched-reads", "5",
            "--cdna-threshold", "2000",
        ])
        let cli = try RecordedCLICommand.parse(run.command, as: FastqFullLengthONTMHCGenotypingSubcommand.self)
        XCTAssertEqual(cli.inputs, request.inputFASTQURLs.map(\.path), run.command)
        XCTAssertNil(cli.orientReference, run.command)
        XCTAssertNil(cli.forwardPrimer, run.command)
        XCTAssertNil(cli.reversePrimer, run.command)
        XCTAssertNil(cli.project, run.command)
        XCTAssertNil(cli.sampleJobs, run.command)
        XCTAssertNil(cli.savontThreadsPerSample, run.command)
        XCTAssertEqual(cli.threads, 4, run.command)
        XCTAssertEqual(cli.minLength, 2_000, run.command)
        XCTAssertEqual(cli.maxLength, 4_000, run.command)
        XCTAssertEqual(cli.savontQualityValueCutoff, 90, run.command)
        XCTAssertEqual(cli.savontMinimumClusterSize, 3, run.command)
        XCTAssertEqual(cli.minUnmatchedReads, 5, run.command)
        XCTAssertEqual(cli.cdnaThreshold, 2_000, run.command)
        XCTAssertFalse(cli.keepIntermediates, run.command)
        XCTAssertFalse(cli.reuseCompatibleCheckpoints, run.command)
        XCTAssertNil(cli.haplotypeDefinition, run.command)
    }
}
