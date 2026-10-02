// ViralReconReferenceAnnotationStagingTests.swift - A reference bundle's genes.gff3 reaches viralrecon as a .gff path
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// nf-core/viralrecon 3.0.0 validates `--gff` against `^\S+\.gff(\.gz)?$`, so
/// a reference bundle that carries its annotation as `genome/genes.gff3`, or
/// a `.gff3` chosen with the wizard's Choose GFF button, made every
/// app-launched run fail parameter validation about 20 seconds in.
///
/// This drives the app's own launch path end to end. The service finds the
/// project's MN908947.3 bundle and builds the `lungfish-cli` arguments it
/// records, the CLI runs in process on exactly those arguments, and only the
/// final Nextflow launch is captured instead of executed.
@MainActor
final class ViralReconReferenceAnnotationStagingTests: XCTestCase {
    private static let gffPattern = #"^\S+\.gff(\.gz)?$"#

    private struct AppLaunch {
        let cliArguments: [String]
        let gff: String
        let gffBytes: Data?
        let runBundleURL: URL
        let state: OperationCenter.Item.State?
        let staging: [String: ParameterValue]?
    }

    func testReferenceBundleGFF3ReachesNextflowAsAGFFPathWithItsBytesUnchanged() async throws {
        // The CLI standardizes every path it records, and the provenance is
        // read back resolved, so compare from the resolved temp root.
        let root = try TestTempDirectory.make(prefix: "viralrecon-gff3-reference").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: root)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let referenceBundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        let bundleGFF3 = try XCTUnwrap(try writeReferenceBundle(at: referenceBundle, withGFF3: true))

        let launch = try await runThroughTheApp(request, project: project)

        // The app hands the CLI the bundle's annotation as it is on disk.
        XCTAssertTrue(launch.cliArguments.contains("gff=\(bundleGFF3.path)"), launch.cliArguments.joined(separator: " "))

        // Nextflow gets a name viralrecon's schema accepts, holding the same bytes.
        XCTAssertNotNil(
            launch.gff.range(of: Self.gffPattern, options: .regularExpression),
            "--gff \(launch.gff) fails viralrecon's pattern \(Self.gffPattern)"
        )
        XCTAssertEqual(launch.gffBytes, try Data(contentsOf: bundleGFF3), "only the name may change")

        // The staging is recorded in the run's provenance next to the original.
        let stagedURL = launch.runBundleURL
            .appendingPathComponent(ViralReconAnnotationStaging.stagingDirectoryPath, isDirectory: true)
            .appendingPathComponent("genes.gff")
        XCTAssertEqual(try Data(contentsOf: stagedURL), try Data(contentsOf: bundleGFF3))
        let staging = try XCTUnwrap(launch.staging, "no staged annotation in provenance")
        XCTAssertEqual(staging["staged"], .file(stagedURL))
        XCTAssertEqual(staging["source"], .file(bundleGFF3))
        XCTAssertEqual(staging["sourceBundle"], .file(referenceBundle))
        XCTAssertEqual(staging["sourceBundleRelativePath"], .string("genome/genes.gff3"))
        XCTAssertEqual(staging["sha256"], .string(try FileDigest.sha256(of: bundleGFF3)))
        XCTAssertEqual(launch.state, .completed)
    }

    func testGFF3ChosenInTheWizardReachesNextflowAsAGFFPath() async throws {
        let root = try TestTempDirectory.make(prefix: "viralrecon-gff3-override").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }
        let fixture = try ViralReconAppTestFixtures.illuminaRequest(root: root)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        // A fetched bundle keeps its annotation in annotations.db, so the
        // wizard's Choose GFF button is how a GFF3 reaches the run.
        XCTAssertNil(try writeReferenceBundle(at: ViralReconReferenceCatalog.bundleURL(inProject: project), withGFF3: false))
        let chosen = root.appendingPathComponent("Downloads/MN908947.3.gff3")
        try FileManager.default.createDirectory(at: chosen.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "##gff-version 3\nMN908947.3\tGenbank\tgene\t5\t40\t.\t+\t.\tID=gene-S;Name=S\n"
            .write(to: chosen, atomically: true, encoding: .utf8)
        let request = try ViralReconRunRequest(
            samples: fixture.samples,
            platform: fixture.platform,
            protocol: fixture.protocol,
            samplesheetURL: fixture.samplesheetURL,
            outputDirectory: fixture.outputDirectory,
            executor: fixture.executor,
            version: fixture.version,
            reference: fixture.reference,
            primer: fixture.primer,
            minimumMappedReads: fixture.minimumMappedReads,
            variantCaller: fixture.variantCaller,
            consensusCaller: fixture.consensusCaller,
            skipOptions: fixture.skipOptions,
            advancedParams: fixture.advancedParams,
            gffURL: chosen
        )

        let launch = try await runThroughTheApp(request, project: project)

        XCTAssertTrue(launch.cliArguments.contains("gff=\(chosen.path)"), launch.cliArguments.joined(separator: " "))
        XCTAssertNotNil(launch.gff.range(of: Self.gffPattern, options: .regularExpression), launch.gff)
        XCTAssertEqual(launch.gffBytes, try Data(contentsOf: chosen))
        let staging = try XCTUnwrap(launch.staging, "no staged annotation in provenance")
        XCTAssertEqual(staging["source"], .file(chosen))
        XCTAssertNil(staging["sourceBundleRelativePath"], "a chosen file lives outside any bundle")
        XCTAssertEqual(launch.state, .completed)
    }

    /// Runs `request` through the app's launch service and the in-process CLI,
    /// capturing the Nextflow launch.
    private func runThroughTheApp(_ request: ViralReconRunRequest, project: URL) async throws -> AppLaunch {
        let nextflow = CapturingNextflowRunner()
        let originalNextflowRunner = RunSubcommand.nfCoreWorkflowProcessRunner
        RunSubcommand.nfCoreWorkflowProcessRunner = nextflow
        defer { RunSubcommand.nfCoreWorkflowProcessRunner = originalNextflowRunner }

        let cli = InProcessLungfishCLIRunner()
        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: cli,
            referenceDownloader: { _, _ in XCTFail("the project already holds the reference bundle") },
            resultIngest: { _ in }
        )
        let result = try await service.run(
            request,
            bundleRoot: project.appendingPathComponent("Analyses", isDirectory: true),
            projectURL: project
        )

        let launch = try XCTUnwrap(nextflow.launches.first, "Nextflow was never launched")
        let gffIndex = try XCTUnwrap(launch.arguments.firstIndex(of: "--gff"), launch.arguments.joined(separator: " "))
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result.bundleURL))
        return AppLaunch(
            cliArguments: try XCTUnwrap(cli.invocations.first),
            gff: launch.arguments[gffIndex + 1],
            gffBytes: launch.gffBytes,
            runBundleURL: result.bundleURL,
            state: operationCenter.items.first { $0.id == result.operationID }?.state,
            staging: provenance.options.explicit[ViralReconAnnotationStaging.provenanceKey]?.dictionaryValue
        )
    }

    /// A `.lungfishref` of MN908947.3, with its annotation at
    /// `genome/genes.gff3` when `withGFF3` is set. Returns that annotation.
    private func writeReferenceBundle(at bundleURL: URL, withGFF3: Bool) throws -> URL? {
        let genome = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        let sequence = String(repeating: "ACGT", count: 20)
        try ">MN908947.3\n\(sequence)\n"
            .write(to: genome.appendingPathComponent("sequence.fa"), atomically: true, encoding: .utf8)
        try "MN908947.3\t80\t12\t80\t81\n"
            .write(to: genome.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(
            name: "MN908947.3",
            identifier: "org.lungfish.MN908947.3",
            source: SourceInfo(organism: "SARS-CoV-2", assembly: "MN908947.3"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 80,
                chromosomes: []
            )
        ).save(to: bundleURL)
        guard withGFF3 else { return nil }

        let gff3 = genome.appendingPathComponent("genes.gff3")
        try """
        ##gff-version 3
        ##sequence-region MN908947.3 1 80
        MN908947.3\tGenbank\tregion\t1\t80\t.\t+\t.\tID=MN908947.3:1..80
        MN908947.3\tGenbank\tgene\t5\t40\t.\t+\t.\tID=gene-S;Name=S;gene=S
        MN908947.3\tGenbank\tCDS\t5\t40\t.\t+\t0\tID=cds-S;Parent=gene-S;product=surface glycoprotein

        """.write(to: gff3, atomically: true, encoding: .utf8)
        return gff3
    }
}

/// Runs the arguments the app would hand `lungfish-cli` through the real CLI
/// command tree, in this process.
@MainActor
private final class InProcessLungfishCLIRunner: ViralReconWorkflowProcessRunning {
    private(set) var invocations: [[String]] = []

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        invocations.append(arguments)
        var command = try LungfishCLI.parseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        return ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    func cancel() {}
}

/// Records each Nextflow launch, with the `--gff` file's bytes read at launch
/// time, and creates the results directory a real run would have created.
private final class CapturingNextflowRunner: NFCoreWorkflowProcessRunning, @unchecked Sendable {
    struct Launch {
        let arguments: [String]
        let gffBytes: Data?
    }

    private(set) var launches: [Launch] = []

    func runNextflow(
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]
    ) async throws -> NFCoreWorkflowProcessResult {
        var gffBytes: Data?
        if let index = arguments.firstIndex(of: "--gff"), index + 1 < arguments.count {
            gffBytes = try? Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
        }
        launches.append(Launch(arguments: arguments, gffBytes: gffBytes))
        if let index = arguments.firstIndex(of: "--outdir"), index + 1 < arguments.count {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: arguments[index + 1]),
                withIntermediateDirectories: true
            )
        }
        return NFCoreWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
