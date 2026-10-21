// ReferenceImportParityReplayTests.swift - The reference imports on the helper route against import fasta
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane A48 M3, ruling A48 F2 pin P8, plan decisions C4 and C5 of 2.10, on lane Q30's
// harness. Each case runs on three sides that start as copies of one project with its inputs.
//
// - Side A is the oracle of the helper route, which A48 M4 deleted. `ReferenceBundleImportService`
//   is called as `ReferenceImportHelper` called it (`ReferenceImportHelperRoutePinTests` pins that
//   call), given the workflow name and the argv side C records, then the app's steps after the
//   helper exited run in process: the annotation attach and the extraction record of the annotated
//   site, and the rehydrate of the Import Center's flag.
// - Side C is the CLI route, the begin helper the site calls and `CLIBundleBuildRunner`, which
//   launches the built `lungfish-cli import fasta` on `AppDelegate.referenceImportArguments`.
// - Side C' is the harness's replay of the command side C recorded.
//
// The cases are the argument shapes of the callers: no name, a name with durable inputs, the
// annotated selection, and the rehydrate, and the FASTQ operation wrapper, which builds in a folder
// as given. A against C declares only the identity paths of R2 (MD62), where side A passes the argv side C records, and C against C' declares nothing (C4). The wrapper case reads the shared
// FASTA, because the harness copies a fixture to each root and the operation's record names the
// folder it was written in, so the rehydrate refuses a copy. `FASTQReferenceWrapperRouteReplayTests`
// runs the FASTA inside the project, and no byte equality is claimed for that shape.
//
// Every side imports from one inputs folder outside the three roots, as a user imports a file from
// outside the project, and each root starts as an empty project. A record names a path under the
// temporary folder as `<workspace>/`, which the harness's root mask does not read, so an input
// copied into each root would read as a difference in its path on every side. The manifest's
// `source_url` names the source that way even inside the project, so the inputs cannot sit there.
// The rehydrate source is the FASTA a FASTQ operation wrote beside its record (pin P3's fixture),
// in the inputs folder's own project, so its record names `@/` paths and no side's root.
//
// It launches the built lungfish-cli and runs the managed bgzip and samtools faidx, so its name
// ends in ReplayTests, which sends it to the integration tier, and it skips without the tools
// unless `LUNGFISH_REQUIRE_TOOLS=1`.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ReferenceImportParityReplayTests: XCTestCase {
    enum Case: String, Sendable, CaseIterable {
        case noName, nameAndInputs, annotations, rehydrate
        /// The FASTQ operation wrapper (A48 M4), with the bundle built in the project's Analyses
        /// folder as given.
        case fastqWrapper
    }

    private static let project = "Project.lungfish"
    private static let inputs = "Project.lungfish/inputs"
    private static let annotationsByRecord: [String: [SequenceAnnotation]] = [
        "seqA": [SequenceAnnotation(
            type: .gene, name: "geneA", chromosome: "seqA", intervals: [AnnotationInterval(start: 1, end: 6)],
            strand: .forward, qualifiers: ["product": AnnotationQualifier("a;b=c,d")], note: "kept note"
        )],
    ]

    private var scratch: URL!
    private var harness: RouteParityHarness!
    /// The inputs every side reads, in a project of their own beside the case roots.
    private var sharedInputs: URL!

    override func setUp() async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)")
        }
        // Resolved, so every path a side records rebases onto its root, as the leaf resolves the project.
        scratch = try TestTempDirectory.make(prefix: "reference-import-parity").resolvingSymlinksInPath()
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDown() async throws {
        if let scratch { TestTempDirectory.cleanup(scratch) }
    }

    func testEveryCallerShapeBuildsWhatTheHelperRouteBuilt() async throws {
        let shared = scratch.appendingPathComponent("shared", isDirectory: true)
        try await Self.writeInputs(shared)
        sharedInputs = shared.appendingPathComponent(Self.inputs, isDirectory: true)
        for parityCase in Case.allCases {
            let result = try await harness.assertParity(
                parityCase,
                declared: [RouteParityHarness.appIdentityDifference([Case.annotations: 7])],
                in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
                fixture: { root in
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent(Self.project, isDirectory: true), withIntermediateDirectories: true
                    )
                },
                sideA: { root in await self.sideA(root, parityCase) },
                sideC: { root in await self.sideC(root, parityCase) }
            )
            for run in result.runs.all {
                XCTAssertEqual(run.outcome.end, .completed, "\(parityCase) \(run.side): \(run.outcome.detail)")
            }
            if parityCase == .rehydrate || parityCase == .fastqWrapper {
                // Parity alone would hold if neither side rehydrated, so C's record must lead with the
                // operation's step.
                let folder = parityCase == .fastqWrapper ? "Analyses" : "Reference Sequences"
                let bundles = try FileManager.default.contentsOfDirectory(
                    at: result.runs.c.root.appendingPathComponent("\(Self.project)/\(folder)", isDirectory: true),
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "lungfishref" }
                let bundle = try XCTUnwrap(bundles.first, "side C published no bundle")
                let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundle))
                XCTAssertEqual(envelope.steps.first?.toolName, "fixture-tool")
                XCTAssertGreaterThan(envelope.steps.count, 1, "the import's own step follows the operation's")
            }
        }
    }

    // MARK: - The sides

    private struct Shape {
        let source: URL
        let project: URL
        let name: String?
        let inputs: [URL]
        let annotations: (bed: URL, selection: URL, alignment: URL)?
        let rehydrate: Bool
        /// The folder the FASTQ operation wrapper builds in, as given.
        var bundleDir: URL?

        var arguments: [String] {
            if let bundleDir {
                return CLIReferenceBundleWrapper.arguments(sourceURL: source, outputDirectory: bundleDir, preferredBundleName: name)
            }
            return AppDelegate.referenceImportArguments(
                sourceURL: source, projectURL: project, preferredBundleName: name, provenanceInputFiles: inputs,
                annotationsURL: annotations?.bed, annotationSelectionURL: annotations?.selection,
                sourceAlignmentBundleURL: annotations?.alignment, rehydrateSourceProvenance: rehydrate
            )
        }
    }

    private static func shape(_ root: URL, _ parityCase: Case, inputs: URL) -> Shape {
        let project = root.appendingPathComponent(Self.project, isDirectory: true)
        let export = inputs.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let alignment = inputs.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        let fasta = inputs.appendingPathComponent("selection.fasta")
        switch parityCase {
        case .noName:
            return Shape(source: fasta, project: project, name: nil, inputs: [], annotations: nil, rehydrate: false)
        case .nameAndInputs:
            return Shape(source: fasta, project: project, name: "-Ref 1", inputs: [export, fasta], annotations: nil, rehydrate: false)
        case .annotations:
            return Shape(
                source: fasta, project: project, name: "Annotated Selection", inputs: [alignment, export],
                annotations: (
                    inputs.appendingPathComponent("selected-annotations.bed"),
                    inputs.appendingPathComponent("selected-annotations.json"),
                    alignment
                ),
                rehydrate: false
            )
        case .rehydrate:
            return Shape(
                source: operationOutput(in: inputs), project: project, name: "Plain", inputs: [export],
                annotations: nil, rehydrate: true
            )
        case .fastqWrapper:
            // The FASTA stays in the shared inputs, since the rehydrate refuses a record copied to
            // another folder. `FASTQReferenceWrapperRouteReplayTests` runs the FASTA inside the project.
            return Shape(
                source: operationOutput(in: inputs), project: project,
                name: "source-deacon-ribo-rrna", inputs: [], annotations: nil, rehydrate: true,
                bundleDir: project.appendingPathComponent("Analyses", isDirectory: true)
            )
        }
    }

    /// The FASTA the fixture's FASTQ operation wrote, in the folder the normalizer named.
    private static func operationOutput(in inputs: URL) -> URL {
        let execution = inputs.appendingPathComponent("execution", isDirectory: true)
        let folder = (try? FileManager.default.contentsOfDirectory(atPath: execution.path))?
            .first { $0.hasPrefix("sequence-normalized-") } ?? "sequence-normalized-missing"
        return execution.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("output.fasta")
    }

    /// Side A. The service as the helper calls it, with C's workflow name and argv, then the steps the
    /// sites ran in the app after the helper exited.
    private func sideA(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let shape = Self.shape(root, parityCase, inputs: sharedInputs)
        do {
            let outputDirectory = try shape.bundleDir ?? ReferenceSequenceFolder.ensureFolder(in: shape.project)
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let result = try await ReferenceBundleImportService.shared.importAsReferenceBundle(
                sourceURL: shape.source,
                outputDirectory: outputDirectory,
                preferredBundleName: shape.name,
                provenanceWorkflowName: "lungfish import fasta",
                provenanceCommand: [harness.cliBinary.path] + shape.arguments,
                provenanceInputFiles: shape.inputs.isEmpty ? nil : shape.inputs
            )
            if let annotations = shape.annotations {
                let clock = ProvenanceRunClock()
                let attached = try await ReferenceBundleAnnotationImportService(toolName: LungfishAppIdentity.recordedToolName, toolKind: LungfishAppIdentity.recordedToolKind)
                    .attachAnnotationTrack(
                        sourceURL: annotations.bed, bundleURL: result.bundleURL,
                        invocationArgv: [harness.cliBinary.path] + shape.arguments
                    )
                try MSAExtractionAnnotationProvenance.write(
                    bundleURL: result.bundleURL,
                    sourceAlignmentBundleURL: annotations.alignment,
                    sourceFASTAURL: shape.source,
                    sourceAnnotationURL: annotations.bed,
                    durableSourceURLs: shape.inputs,
                    selectedSequenceIDs: FASTAOperationCatalog.selectedIdentifiers(
                        in: try String(contentsOf: shape.source, encoding: .utf8)
                    ),
                    selectedAnnotationsByRecord: Self.annotationsByRecord,
                    annotationResult: attached,
                    runClock: clock
                )
            }
            if shape.rehydrate {
                try FASTQOperationProvenanceRehydrator().rehydrateReferenceBundleProvenance(
                    sourceURL: shape.source, referenceBundleURL: result.bundleURL
                )
            }
            return RouteParitySideOutcome(end: .completed, detail: "Imported \(result.bundleURL.lastPathComponent)")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The begin helper the site calls and the runner on the argv the site hands it.
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let shape = Self.shape(root, parityCase, inputs: sharedInputs)
        if let bundleDir = shape.bundleDir {
            // The wrapper runs inside the FASTQ operation's row, so the command it runs is what C' replays.
            let command = OperationCenter.buildCLICommand(subcommand: "import fasta", args: Array(shape.arguments.dropFirst(2)))
            do {
                let bundle = try await CLIReferenceBundleWrapper(cliURLOverride: harness.cliBinary)
                    .importReferenceBundle(sourceURL: shape.source, outputDirectory: bundleDir, preferredBundleName: shape.name)
                return RouteParitySideOutcome(end: .completed, detail: "Imported \(bundle.lastPathComponent)", recordedCommand: command)
            } catch {
                return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: command)
            }
        }
        let reporter = RecordingOperationReporter()
        var operationID: UUID?
        if shape.annotations != nil {
            ViewerViewController.beginAnnotatedReferenceImportOperation(
                arguments: shape.arguments, bundleStem: "stem", routeContext: nil, reporter: reporter
            ) { operationID = $0 }
        } else {
            AppDelegate.beginReferenceImportOperation(
                sourceURL: shape.source, projectURL: shape.project, preferredBundleName: shape.name,
                provenanceInputFiles: shape.inputs, rehydrateSourceProvenance: shape.rehydrate,
                routeContext: nil, reporter: reporter
            ) { operationID = $0 }
        }
        let command = reporter.items.first?.cliCommand
        guard let operationID else { return RouteParitySideOutcome(end: .failed, detail: "the row did not start") }
        let outcome = await AppDelegate.runReferenceImport(
            arguments: shape.arguments, operationID: operationID, reporter: reporter,
            run: { arguments, id in try await CLIBundleBuildRunner(cliURLOverride: self.harness.cliBinary).run(arguments: arguments, operationID: id) }
        )
        guard let bundle = outcome.bundleURL else {
            return RouteParitySideOutcome(end: .failed, detail: "\(outcome.error.map { "\($0)" } ?? "no end")", recordedCommand: command)
        }
        return RouteParitySideOutcome(end: .completed, detail: "Imported \(bundle.lastPathComponent)", recordedCommand: command)
    }

    // MARK: - Fixture

    /// A project of its own holding, in `inputs`, a FASTA selection of two records, its BED and
    /// selection, a durable source bundle, an alignment bundle, and the FASTA a FASTQ operation wrote
    /// with its record. Every side reads it and none writes to it.
    private static func writeInputs(_ root: URL) async throws {
        let inputs = root.appendingPathComponent(Self.inputs, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: inputs, withIntermediateDirectories: true)
        try await writeOperationOutput(in: inputs)
        for folder in ["Source.lungfishref", "Aligned.lungfishmsa"] {
            try fileManager.createDirectory(at: inputs.appendingPathComponent(folder), withIntermediateDirectories: true)
            try #"{"schemaVersion":1}"#.write(
                to: inputs.appendingPathComponent(folder).appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8
            )
        }
        try ">seqA first\nACGTACGTAC\n>seqB\nGGCCAATTGGCC\n"
            .write(to: inputs.appendingPathComponent("selection.fasta"), atomically: true, encoding: .utf8)
        try "seqA\t1\t6\tgeneA\t0\t+\t1\t6\t0,0,0\t1\t5,\t0,\tgene\tproduct=a%3Bb%3Dc,d\n"
            .write(to: inputs.appendingPathComponent("selected-annotations.bed"), atomically: true, encoding: .utf8)
        try JSONEncoder().encode(MSAExtractionAnnotationProvenance.annotationSelectionValue(annotationsByRecord))
            .write(to: inputs.appendingPathComponent("selected-annotations.json"))
    }

    /// A FASTQ operation's output with its record, normalized to FASTA as the operation leaves it,
    /// as pin P3 (`ReferenceImportRehydratePinTests`) builds it, here inside the project.
    private static func writeOperationOutput(in inputs: URL) async throws {
        let execution = inputs.appendingPathComponent("execution", isDirectory: true)
        try FileManager.default.createDirectory(at: execution, withIntermediateDirectories: true)
        let reads = inputs.appendingPathComponent("reads.fastq")
        let raw = execution.appendingPathComponent("output.fastq")
        try Data("@r\nACGTACGTAC\n+\nIIIIIIIIII\n".utf8).write(to: reads)
        try Data("@r\nACGTACGTAC\n+\nIIIIIIIIII\n".utf8).write(to: raw)
        let argv = ["fixture-tool", "--input", reads.path, "--output", raw.path]
        let step = ProvenanceStep(
            toolName: "fixture-tool", toolVersion: "1", argv: argv, runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [try descriptor(reads, role: .input)], outputs: [try descriptor(raw, role: .output)],
            exitStatus: 0, wallTimeSeconds: 1
        )
        let run = try ProvenanceRunBuilder(
            workflowName: "lungfish fixture", workflowVersion: "1", toolName: "fixture-tool", toolVersion: "1"
        )
        .argv(argv).runtime(ProvenanceRuntimeIdentity()).input(reads, format: .fastq)
        .output(raw, format: .fastq).step(step)
        .complete(exitStatus: 0, startedAt: Date(), endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(run, toSidecar: ProvenanceRecorder.fileSidecarURL(for: raw))
        _ = try await SequenceProcessingOutputNormalizer.normalize(outputURL: raw, preferredFormat: .fasta)
    }

    private static func descriptor(_ url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: url.path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), role: role
        )
    }
}
