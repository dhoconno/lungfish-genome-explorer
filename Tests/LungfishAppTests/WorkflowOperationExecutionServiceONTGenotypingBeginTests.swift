// WorkflowOperationExecutionServiceONTGenotypingBeginTests.swift - The amplicon genotyping row's command parses to the run
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

/// Phase 2.12 lane 12.21 (QR-b). `WorkflowOperationExecutionService.runONTGenotyping`,
/// which `run(.ontGenotyping(_))` reaches, records the `lungfish-cli fastq genotype`
/// or `fastq genotype-cohort` command on its Operations panel row. Before the row
/// begins it claims the output folder with a run record that holds the same
/// command. These tests run the real site on a process runner that records its
/// argv, read the command off the row, and parse it with the real CLI leaf the
/// way the shipped binary does. The parsed run must be the one the request
/// describes, with the output name the site chose when the folder was taken, and
/// the command must be the argv the site launched (docs/contracts/CLI-EQUIVALENCE.md).
@MainActor
final class WorkflowOperationExecutionServiceONTGenotypingBeginTests: XCTestCase {

    private struct Fixture {
        let root: URL
        let reads: [URL]
        let reference: URL
        let outputDirectory: URL
    }

    /// The path of a fixture URL as the request keeps it, since the request standardizes every URL it holds.
    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Every input sits in a scratch folder the test removes. The output bundle
    /// path is absent, as it is when the dialog starts a run, so the site creates
    /// the bundle together with its run record.
    private func makeFixture() throws -> Fixture {
        let root = try TestTempDirectory.make(prefix: "ont-genotyping-begin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let reads = ["NB13.lungfishfastq", "NB14.lungfishfastq"].map {
            root.appendingPathComponent($0, isDirectory: true)
        }
        let reference = root.appendingPathComponent("ref.lungfishref", isDirectory: true)
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        for directory in reads + [reference, analyses] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return Fixture(
            root: root,
            reads: reads,
            reference: reference,
            outputDirectory: analyses.appendingPathComponent("reads-ont.lungfishgenotype", isDirectory: true)
        )
    }

    private struct SiteRun {
        let outputs: [URL]
        let operationCenter: OperationCenter
        let refresher: RecordingBeginSiteResultRefresher
        let runner: RecordingBeginSiteCLIRunner
        let command: String
        /// The output folder's run record as the CLI would find it: whether it hides
        /// the bundle from the sidebar, and the command it holds.
        let claim: (hidden: Bool, command: String?)
    }

    private func runSite(_ request: ONTBarcodeDemuxGenotypingRunRequest) async throws -> SiteRun {
        let operationCenter = OperationCenter()
        let refresher = RecordingBeginSiteResultRefresher()
        var claim: (hidden: Bool, command: String?) = (false, nil)
        let runner = RecordingBeginSiteCLIRunner { arguments in
            guard let index = arguments.firstIndex(of: "--output-dir"), arguments.indices.contains(index + 1) else {
                return
            }
            let bundle = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            claim = (AnalysisRunRecord.isIncomplete(bundle), AnalysisRunRecord.load(from: bundle)?.command)
        }
        let service = BeginSiteTesting.makeService(
            operationCenter: operationCenter,
            runner: runner,
            refresher: refresher
        )

        let outputs = try await service.run(.ontGenotyping(request))

        return SiteRun(
            outputs: outputs,
            operationCenter: operationCenter,
            refresher: refresher,
            runner: runner,
            command: try BeginSiteTesting.recordedCommand(of: operationCenter, launchedBy: runner),
            claim: claim
        )
    }

    /// The row, the outputs, the refresh, the working directory and the run record of a clean run.
    private func assertCleanRun(
        _ run: SiteRun,
        bundle expectedBundle: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bundle = expectedBundle.standardizedFileURL
        let item = try XCTUnwrap(run.operationCenter.items.first, file: file, line: line)
        XCTAssertEqual(item.title, "MiSeq Amplicon MHC Genotyping", file: file, line: line)
        XCTAssertEqual(item.operationType, .workflow, file: file, line: line)
        XCTAssertEqual(item.targetBundleURL?.standardizedFileURL, bundle, file: file, line: line)
        XCTAssertEqual(item.state, .completed, file: file, line: line)
        XCTAssertEqual(item.displayStateLabel, "Completed", file: file, line: line)
        XCTAssertTrue(run.outputs.map(\.path).contains(bundle.path), "\(run.outputs)", file: file, line: line)
        XCTAssertEqual(run.refresher.invocations, [bundle], file: file, line: line)
        XCTAssertEqual(run.runner.invocations.first?.workingDirectory, bundle, file: file, line: line)
        // The bundle carried a run record while the CLI ran, which held the row's command,
        // and the completed run shows in the sidebar.
        XCTAssertTrue(run.claim.hidden, "a running genotyping bundle is hidden from the sidebar", file: file, line: line)
        XCTAssertEqual(run.claim.command, run.command, file: file, line: line)
        XCTAssertFalse(AnalysisRunRecord.isIncomplete(bundle), "a completed run is shown", file: file, line: line)
    }

    /// An ONT run on prepared sample bundles goes to the cohort command, and every
    /// choice of the request is on it, the haplotype thresholds in percent.
    func testTheRowCommandOfAnONTSampleBundleCohortParsesToTheSameRun() async throws {
        let fixture = try makeFixture()
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: fixture.reads,
            referenceSourceURL: fixture.reference,
            outputDirectory: fixture.outputDirectory,
            outputName: "reads-ont",
            analysisName: "ONT08",
            projectURL: fixture.root,
            threads: 4,
            sortThreads: 2,
            minSupport: 3,
            keepIntermediates: true,
            haplotypeDropoutSampleFraction: 0.05,
            haplotypeDropoutLocusFraction: 0.10,
            haplotypeDropoutLocusFractionOverrides: ["MHC-DQ": 0.25],
            haplotypeAssayID: "MHC-exon2-miSeq",
            haplotypeSpeciesCode: "MCM",
            haplotypeDefinitionScope: .project,
            haplotypeDefinitionSetID: "mcm-haplotypes-v1",
            extraArguments: ["-k", "15"],
            mode: .ontSampleBundles,
            readType: .ont
        )

        let run = try await runSite(request)

        try assertCleanRun(run, bundle: request.outputDirectory)
        // The exact argv, in the order the site launched it, with the fixture's paths. Every word is pinned,
        // so a flag the site adds or drops fails here (M874, H2).
        let expected: [String] = [
            "fastq", "genotype-cohort", Self.path(fixture.reads[0]), Self.path(fixture.reads[1]),
            "--mode", "ont-sample-bundles",
            "--read-type", "ont",
            "--output-dir", Self.path(fixture.outputDirectory),
            "--output-name", "reads-ont",
            "--threads", "4",
            "--sort-threads", "2",
            "--min-support", "3",
            "--analysis-name", "ONT08",
            "--reference", Self.path(fixture.reference),
            "--haplotype-min-sample-percent", "5",
            "--haplotype-min-locus-percent", "10",
            "--haplotype-min-locus-percent-override", "MHC-DQ=25",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-species", "MCM",
            "--haplotype-definition-scope", "project",
            "--haplotype-definition", "mcm-haplotypes-v1",
            "--project", Self.path(fixture.root),
            "--keep-intermediates",
            "--extra-args", "-k 15",
        ]
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), expected, run.command)
        // The request names no demux manifest, so the command does not either.
        XCTAssertFalse(try RecordedCLICommand.arguments(of: run.command).contains("--demux-manifest"), run.command)
        let cli = try RecordedCLICommand.parse(run.command, as: FastqGenotypingCohortSubcommand.self)
        XCTAssertEqual(cli.inputs, request.inputFASTQURLs.map(\.path), run.command)
        XCTAssertEqual(cli.mode, "ont-sample-bundles", run.command)
        XCTAssertEqual(cli.readType, "ont", run.command)
        XCTAssertEqual(cli.reference, request.referenceSourceURL.path, run.command)
        XCTAssertNil(cli.preset, run.command)
        XCTAssertNil(cli.barcodes, run.command)
        XCTAssertEqual(cli.outputDir, request.outputDirectory.path, run.command)
        XCTAssertEqual(cli.outputName, "reads-ont", run.command)
        XCTAssertEqual(cli.analysisName, "ONT08", run.command)
        XCTAssertEqual(cli.project, request.projectURL?.path, run.command)
        XCTAssertEqual(cli.threads, 4, run.command)
        XCTAssertEqual(cli.sortThreads, 2, run.command)
        XCTAssertEqual(cli.minSupport, 3, run.command)
        XCTAssertTrue(cli.keepIntermediates, run.command)
        XCTAssertEqual(cli.haplotypeMinSamplePercent, 5, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercent, 10, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercentOverrides, ["MHC-DQ=25"], run.command)
        XCTAssertEqual(cli.haplotypeAssay, "MHC-exon2-miSeq", run.command)
        XCTAssertEqual(cli.haplotypeSpecies, "MCM", run.command)
        XCTAssertEqual(cli.haplotypeDefinitionScope, "project", run.command)
        XCTAssertEqual(cli.haplotypeDefinition, "mcm-haplotypes-v1", run.command)
        XCTAssertFalse(cli.genotypeOnly, run.command)
        XCTAssertEqual(cli.extraArgs, "-k 15", run.command)
    }

    /// A MiSeq run on the locked preset goes to the single-run command. The preset
    /// stands in for the reference, and a run without a haplotype definition says
    /// so with `--genotype-only`, so the CLI does not pick a default definition.
    func testTheRowCommandOfAMiSeqPresetRunParsesToTheSameRun() async throws {
        let fixture = try makeFixture()
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [fixture.reads[0]],
            referenceSourceURL: fixture.reference,
            outputDirectory: fixture.outputDirectory,
            outputName: "miseq-run",
            analysisName: "LF2823",
            threads: 8,
            presetID: "mcm-mhc-miseq",
            presetVersion: "1",
            mode: .illuminaPaired,
            readType: .illumina
        )

        let run = try await runSite(request)

        try assertCleanRun(run, bundle: request.outputDirectory)
        let expected: [String] = [
            "fastq", "genotype", Self.path(fixture.reads[0]),
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--output-dir", Self.path(fixture.outputDirectory),
            "--output-name", "miseq-run",
            "--threads", "8",
            "--sort-threads", "4",
            "--min-support", "1",
            "--analysis-name", "LF2823",
            "--preset", "mcm-mhc-miseq",
            "--genotype-only",
        ]
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), expected, run.command)
        let cli = try RecordedCLICommand.parse(run.command, as: FastqGenotypingSubcommand.self)
        XCTAssertEqual(cli.inputs, request.inputFASTQURLs.map(\.path), run.command)
        XCTAssertEqual(cli.mode, "illumina-paired", run.command)
        XCTAssertEqual(cli.readType, "illumina", run.command)
        XCTAssertEqual(cli.preset, "mcm-mhc-miseq", run.command)
        XCTAssertNil(cli.reference, run.command)
        XCTAssertEqual(cli.outputDir, request.outputDirectory.path, run.command)
        XCTAssertEqual(cli.outputName, "miseq-run", run.command)
        XCTAssertEqual(cli.analysisName, "LF2823", run.command)
        XCTAssertEqual(cli.threads, 8, run.command)
        XCTAssertEqual(cli.sortThreads, 4, run.command)
        XCTAssertEqual(cli.minSupport, 1, run.command)
        XCTAssertFalse(cli.keepIntermediates, run.command)
        XCTAssertEqual(cli.haplotypeMinSamplePercent, 0, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercent, 0, accuracy: 1e-9, run.command)
        XCTAssertEqual(cli.haplotypeMinLocusPercentOverrides, [], run.command)
        XCTAssertNil(cli.haplotypeDefinition, run.command)
        XCTAssertTrue(cli.genotypeOnly, run.command)
        XCTAssertEqual(cli.extraArgs, "", run.command)
    }

    /// The command carries the output the site chose, not the one the request named.
    /// A folder that already holds a result is left alone, and the run goes to the
    /// next free name, in the folder, the output name and the analysis name.
    func testTheRowCommandOfARunOnATakenFolderParsesToTheNextFreeName() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.outputDirectory, withIntermediateDirectories: true)
        let earlierResult = fixture.outputDirectory.appendingPathComponent("reads-ont.xlsx")
        try Data("earlier run".utf8).write(to: earlierResult)
        let request = ONTBarcodeDemuxGenotypingRunRequest(
            inputFASTQURLs: [fixture.reads[0]],
            referenceSourceURL: fixture.reference,
            outputDirectory: fixture.outputDirectory,
            outputName: "reads-ont",
            analysisName: "ONT08",
            threads: 2,
            mode: .ontSampleBundles,
            readType: .ont
        )
        let nextFree = fixture.outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("reads-ont_1.lungfishgenotype", isDirectory: true)

        let run = try await runSite(request)

        try assertCleanRun(run, bundle: nextFree)
        // The whole argv, with the next free name in the output folder, the output name and the analysis name.
        let expected: [String] = [
            "fastq", "genotype-cohort", Self.path(fixture.reads[0]),
            "--mode", "ont-sample-bundles",
            "--read-type", "ont",
            "--output-dir", nextFree.standardizedFileURL.path,
            "--output-name", "reads-ont_1",
            "--threads", "2",
            "--sort-threads", "4",
            "--min-support", "1",
            "--analysis-name", "ONT08_1",
            "--reference", Self.path(fixture.reference),
            "--genotype-only",
        ]
        XCTAssertEqual(try RecordedCLICommand.arguments(of: run.command), expected, run.command)
        let cli = try RecordedCLICommand.parse(run.command, as: FastqGenotypingCohortSubcommand.self)
        XCTAssertEqual(cli.outputDir, nextFree.standardizedFileURL.path, run.command)
        XCTAssertEqual(cli.outputName, "reads-ont_1", run.command)
        XCTAssertEqual(cli.analysisName, "ONT08_1", run.command)
        XCTAssertEqual(try Data(contentsOf: earlierResult), Data("earlier run".utf8))
    }
}
