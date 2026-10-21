// ViralReconReferenceAnnotationRealRunTests.swift - Opt-in real Viral Recon run on a reference bundle that carries genes.gff3
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Runs nf-core/viralrecon for real through the app's launch service.
///
/// The service records and spawns the same `lungfish-cli workflow run`
/// command the Viral Recon wizard does, and that command runs the managed
/// Nextflow with Docker. It is opt-in because it needs Docker Desktop, the
/// managed Nextflow and a few minutes. Set
///
/// - `LUNGFISH_VIRALRECON_REAL_RUN_PROJECT` to a project directory whose
///   `Downloads/MN908947.3.lungfishref` carries `genome/genes.gff3`
/// - `LUNGFISH_CLI_PATH` to the `lungfish-cli` binary to spawn
///
/// The reads are Tests/Fixtures/sarscov2 test_1/test_2 as one paired sample
/// and the scheme is the bundled ARTIC nCoV-2019 V3, staged as the wizard
/// stages it. The request's version is the lock's pin, the full commit, as the
/// wizard sends it (`ViralReconWizardSheet`), so the record names that commit
/// and the engine's own log names its first ten characters (Phase 2.10, V3-BIO
/// 2.5). The run goes through the shell's environment, and a coding agent's
/// shell sets `CLAUDECODE`, which made Nextflow print an agent log with no
/// banner and no `Launching` line (V3-BIO 2.4), so a green run from such a
/// shell also shows that the launch drops that switch.
///
/// Every precondition goes through `ToolAvailability` (Phase 2.13, lane 13.20). A Mac without the two variables, the
/// managed Nextflow or a Docker that answers `docker info` skips, and `LUNGFISH_REQUIRE_TOOLS=1` turns each of those
/// skips into a failure, so a regression cannot hide behind a bare skip. The probe never starts Docker Desktop.
@MainActor
final class ViralReconReferenceAnnotationRealRunTests: XCTestCase {
    func testAppLaunchPathCompletesOnAReferenceBundleThatCarriesGFF3() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let projectPath = environment["LUNGFISH_VIRALRECON_REAL_RUN_PROJECT"],
              environment["LUNGFISH_CLI_PATH"] != nil else {
            try ToolAvailability.skipOrFail("Set LUNGFISH_VIRALRECON_REAL_RUN_PROJECT and LUNGFISH_CLI_PATH to run Viral Recon for real")
        }
        _ = try await ToolAvailability.require("nextflow", environment: "nextflow")
        guard let dockerExecutable = LiveNextflowDocker.locateExecutable() else {
            try ToolAvailability.skipOrFail("docker is not installed on this Mac.")
        }
        if let problem = LiveNextflowDocker.system(executable: dockerExecutable).probe().problem {
            try ToolAvailability.skipOrFail(problem)
        }
        let project = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let referenceBundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        let bundleGFF3 = referenceBundle.appendingPathComponent("genome/genes.gff3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleGFF3.path), "the reference bundle must carry genome/genes.gff3")

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let staging = analyses.appendingPathComponent(".viralrecon-inputs-\(token)", isDirectory: true)
        let reads = repository.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        let sample = ViralReconSample(
            sampleName: "SMOKE1",
            sourceBundleURL: reads,
            fastqURLs: [
                reads.appendingPathComponent("test_1.fastq.gz"),
                reads.appendingPathComponent("test_2.fastq.gz"),
            ],
            barcode: nil,
            sequencingSummaryURL: nil
        )
        let pin = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let request = try ViralReconRunRequest(
            samples: [sample],
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: [sample], in: staging),
            outputDirectory: analyses.appendingPathComponent("viralrecon-results-\(token)", isDirectory: true),
            executor: .docker,
            version: pin.revision,
            reference: .genome(ViralReconReferenceCatalog.canonicalAccession),
            primer: try ViralReconWizardPrimerStaging.stageForCanonicalReference(
                primerBundleURL: repository.appendingPathComponent(
                    "Sources/LungfishApp/Resources/PrimerSchemes/ARTIC-nCoV-2019-V3.lungfishprimers",
                    isDirectory: true
                ),
                projectURL: project,
                destinationDirectory: staging
            ),
            minimumMappedReads: 1,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: Array(ViralReconSkipOption.defaultSelection).sorted { $0.rawValue < $1.rawValue },
            advancedParams: ["max_cpus": "4", "max_memory": "8.GB"]
        )

        // The folders `Analyses` holds before the run, so the viewer pick below never binds an earlier run's bundle.
        let foldersBeforeRun = Set((try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? [])

        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: ProcessViralReconWorkflowProcessRunner(),
            referenceDownloader: { _, _ in XCTFail("the project already holds the reference bundle") }
        )
        let result = try await service.run(request, bundleRoot: analyses, projectURL: project)

        let item = try XCTUnwrap(operationCenter.items.first { $0.id == result.operationID })
        print("REAL RUN cliCommand \(item.cliCommand ?? "nil")")
        for entry in item.logEntries {
            print("REAL RUN log [\(entry.level)] \(entry.message)")
        }
        XCTAssertEqual(item.state, .completed, item.errorDetail ?? item.detail)
        XCTAssertTrue(item.cliCommand?.contains("gff=\(bundleGFF3.path)") == true, "the recorded command names the bundle's genes.gff3")
        XCTAssertTrue(item.cliCommand?.contains("--version \(pin.revision)") == true, "the run sends the lock's pin as the wizard does")

        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        print("REAL RUN manifest executionStatus=\(manifest.executionStatus) exitCode=\(manifest.exitCode.map(String.init) ?? "nil")")
        XCTAssertEqual(manifest.executionStatus, .completed)

        // What Nextflow itself received, from the pipeline's own record.
        let pipelineInfo = request.outputDirectory.appendingPathComponent("pipeline_info", isDirectory: true)
        let paramsFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(atPath: pipelineInfo.path)
                .first { $0.hasPrefix("params_") && $0.hasSuffix(".json") }
        )
        let pipelineParams = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: pipelineInfo.appendingPathComponent(paramsFile))) as? [String: Any]
        )
        let launchedGFF = try XCTUnwrap(pipelineParams["gff"] as? String)
        print("REAL RUN pipeline_info/\(paramsFile) gff=\(launchedGFF)")
        XCTAssertNotNil(launchedGFF.range(of: #"^\S+\.gff(\.gz)?$"#, options: .regularExpression), launchedGFF)
        XCTAssertEqual(URL(fileURLWithPath: launchedGFF).lastPathComponent, "genes.gff")

        // The copy kept with the run holds the bundle's bytes. The launched
        // path can be a whitespace-free scratch copy that is gone by now.
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result.bundleURL))

        // B31 check 1 on the GUI route (V3-BIO 2.5). The step's tool version is the full commit the wizard sent, and the
        // engine's own words in logs/stdout.log name its first ten characters on the `Launching` line, after the banner.
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolVersion, pin.revision, "the record names the commit that was sent")
        XCTAssertNotNil(step.toolVersion.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression), step.toolVersion)
        let stdoutData = try Data(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log"))
        let stdoutLog = try XCTUnwrap(String(data: stdoutData, encoding: .utf8), "logs/stdout.log is not UTF-8")
        XCTAssertTrue(stdoutLog.contains("N E X T F L O W"), "logs/stdout.log holds no Nextflow banner, as in agent mode")
        XCTAssertTrue(
            stdoutLog.contains("revision: \(step.toolVersion.prefix(10))"),
            "logs/stdout.log names no Launching revision \(step.toolVersion.prefix(10))"
        )

        guard case .dictionary(let staging)? = provenance.options.explicit[ViralReconAnnotationStaging.provenanceKey] else {
            return XCTFail("no staged annotation in provenance")
        }
        for key in staging.keys.sorted() {
            print("REAL RUN provenance stagedAnnotation.\(key)=\(staging[key].map { String(describing: $0) } ?? "nil")")
        }
        XCTAssertEqual(staging["sourceBundleRelativePath"], .string("genome/genes.gff3"))
        let stagedCopy = try XCTUnwrap(staging["staged"]?.fileValue)
        XCTAssertEqual(try Data(contentsOf: stagedCopy), try Data(contentsOf: bundleGFF3))

        // The viewer binds a .lungfishref whose manifest registers the BAM. Only a folder this run made counts, so a
        // project that holds an earlier run's viewer bundle never binds that one. When more than one is new, the
        // latest name comes first, since the ingest names its folder by timestamp.
        let viewerBundles = try FileManager.default.contentsOfDirectory(at: analyses, includingPropertiesForKeys: nil)
            .filter { !foldersBeforeRun.contains($0.lastPathComponent) }
            .filter { $0.lastPathComponent.hasPrefix("viralrecon-") && !$0.lastPathComponent.hasPrefix("viralrecon-results-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent(ViralReconReferenceCatalog.bundleFilename, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        let viewerBundle = try XCTUnwrap(viewerBundles.first, "no viewer bundle was ingested")
        let viewerManifest = try BundleManifest.load(from: viewerBundle)
        print("REAL RUN viewer \(viewerBundle.path) alignments=\(viewerManifest.alignments.count) variants=\(viewerManifest.variants.count)")
        XCTAssertEqual(viewerManifest.alignments.count, 1)
    }
}
