// RegionExtractionWithoutBundleParityReplayTests.swift - A viewer with no reference bundle, in process against extract sequence
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.12 M2 (A48-GAP), plan R-A1 and R-A3, C4 and C5 of 2.10, on lane Q30's harness. A viewer
// whose document has no reference bundle builds a region bundle from the sequence the document shows. Each
// case runs on three sides that start as copies of one project holding the document.
//
// - Side A is the in-process route, `SequenceExtractionPipeline().buildBundle(from:outputDirectory:
//   desiredBundleName:isConcatenated:)`, the call `createExtractionBundleInProcess` makes, which the hidden
//   key's `legacy` value keeps until lane 13.03.
// - Side C is the CLI route. `StagedSequenceInput` writes the sequence under the project's `.tmp/`, then the
//   begin helper the site calls and `CLIBundleBuildRunner` launch the built `lungfish-cli extract sequence`
//   on `SequenceExtractionPipeline.cliFASTAArguments`. Its row records the command. The staged folder is then
//   copied to root C', where the replay reads it, as the BLAST classes copy their query.
// - Side C' is the harness's replay of that command.
//
// The bundle's payload, manifest and genome match. A against C declares each difference with `<ANY>`, the
// staged folder only side C keeps and the record lines of the command each route states, and C against C'
// declares nothing. It runs the managed bgzip and samtools faidx and launches the built lungfish-cli, so its
// name ends in ReplayTests and it skips without the tools unless `LUNGFISH_REQUIRE_TOOLS=1`.

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
final class RegionExtractionWithoutBundleParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        /// A region of a FASTA document, as the viewer's visible window gives it.
        case fastaRegion
        /// A reverse CDS of two parts of a GenBank document, joined, with a 5' flank and a blank name.
        case genBankFeature
    }

    private static let projectPath = "Project.lungfish"
    private static let extractionsPath = "Project.lungfish/Extractions"
    private static let fastaPath = "Project.lungfish/Downloads/test virus.fasta"
    private static let genBankPath = "Project.lungfish/Downloads/test virus.gb"

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "region-without-bundle-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    func testARegionOfAFASTADocumentBuildsWhatTheInProcessRouteBuilt() async throws {
        try await requireTools()
        try await assertCase(.fastaRegion)
    }

    func testAFeatureOfAGenBankDocumentBuildsWhatTheInProcessRouteBuilt() async throws {
        try await requireTools()
        try await assertCase(.genBankFeature)
    }

    private func assertCase(_ parityCase: Case) async throws {
        let result = try await harness.assertParity(
            parityCase,
            declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { root in try Self.writeFixture(root) },
            sideA: { root in await self.sideA(root, parityCase) },
            sideC: { root in await self.sideC(root, parityCase) }
        )
        for run in [result.runs.a, result.runs.c, result.runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "\(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.c.outcome.detail, "Bundle ready", "the row's complete words")
    }

    /// What A against C differs in, each with `<ANY>` and an exact count for each case.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.fastaRegion: 2, .genBankFeature: 2], "only in C: Project.lungfish/.tmp/extract-sequence-input-<ANY>",
            reason: "The CLI route stages the viewer's sequence as a FASTA and keeps it with its folder marker, so the "
                + "record names an input that exists (ARCH 5, BIO 6). The in-process route read it from memory.",
            closedBy: "13.03 (DEL-REST), which deletes the in-process route with its hidden key RegionExtractionWithoutBundleRoute"
        ),
        RouteParityDeclaredDifference(
            [.fastaRegion: 405, .genBankFeature: 513], "differs: Project.lungfish/Extractions/<ANY>.lungfish-provenance.json at <ANY>",
            reason: "Each record states the command its route ran, the in-process lungfish-gui argv against the leaf's, "
                + "and the leaf's names the staged FASTA and the document as inputs with digests, adds input and "
                + "source_document, and for a GenBank document source_annotations (R-B3). The bundle's payload, "
                + "manifest and genome match.",
            closedBy: "13.03 (DEL-REST), which deletes the in-process route with its hidden key RegionExtractionWithoutBundleRoute"
        ),
    ]

    // MARK: - The sides

    /// What the site holds for `parityCase` in `root`, the sequence its document shows and the extraction.
    private struct Extraction {
        let sequence: LungfishCore.Sequence
        let document: URL
        let request: ExtractionRequest
        let result: LungfishCore.ExtractionResult
        let bundleName: String
        let project: URL
        let extractions: URL
    }

    private func extraction(_ root: URL, _ parityCase: Case) async throws -> Extraction {
        let sequence: LungfishCore.Sequence
        let document: URL
        let request: ExtractionRequest
        let bundleName: String
        switch parityCase {
        case .fastaRegion:
            document = root.appendingPathComponent(Self.fastaPath)
            sequence = try await RegionExtractionWithoutBundlePinConformanceTests.readFASTADocument(document)
            request = ExtractionRequest(source: .region(chromosome: sequence.name, start: 10, end: 40))
            bundleName = "Region 1"
        case .genBankFeature:
            document = root.appendingPathComponent(Self.genBankPath)
            let records = try await GenBankReader(url: document).readAll()
            let record = try XCTUnwrap(records.first)
            sequence = record.sequence
            let cds = try XCTUnwrap(record.annotations.first { $0.type == .cds })
            request = ExtractionRequest(source: .annotation(cds), flank5Prime: 2, concatenateExons: true)
            bundleName = "  "
        }
        let result = try SequenceExtractor.extract(
            request: request,
            sequenceProvider: RegionExtractionWithoutBundlePinConformanceTests.viewerProvider(sequence),
            chromosomeLength: sequence.length
        )
        return Extraction(
            sequence: sequence, document: document, request: request, result: result, bundleName: bundleName,
            project: root.appendingPathComponent(Self.projectPath, isDirectory: true),
            extractions: root.appendingPathComponent(Self.extractionsPath, isDirectory: true)
        )
    }

    /// Side A. The call `createExtractionBundleInProcess` makes.
    private func sideA(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        do {
            let run = try await extraction(root, parityCase)
            _ = try await SequenceExtractionPipeline().buildBundle(
                from: run.result, outputDirectory: run.extractions, desiredBundleName: run.bundleName,
                isConcatenated: run.request.concatenateExons
            )
            return RouteParitySideOutcome(end: .completed, detail: "Bundle ready")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)")
        }
    }

    /// Side C. The staged FASTA, the begin helper the site calls and the runner on the argv the site
    /// builds, which launches the built CLI. The staged folder is then copied to root C'.
    private func sideC(_ root: URL, _ parityCase: Case) async -> RouteParitySideOutcome {
        let reporter = RecordingOperationReporter()
        let runner = CLIBundleBuildRunner(cliURLOverride: harness.cliBinary)
        do {
            let run = try await extraction(root, parityCase)
            let staged = try await StagedSequenceInput.writeFASTA(
                [.init(name: run.sequence.name, bases: run.sequence.asString())],
                fileName: "sequence.fa", prefix: "extract-sequence-input-", projectURL: run.project
            )
            let arguments = SequenceExtractionPipeline.cliFASTAArguments(
                source: run.request.source, flank5Prime: run.request.flank5Prime, flank3Prime: run.request.flank3Prime,
                reverseComplement: run.request.reverseComplement, concatenateExons: run.request.concatenateExons,
                inputURL: staged, sequenceName: run.sequence.name, sourceDocumentURL: run.document,
                bundleName: run.bundleName,
                outputBundleURL: SequenceExtractionBundleBuilder.uniqueBundleURL(
                    for: run.result, desiredBundleName: run.bundleName, in: run.extractions
                )
            )
            var operationID: UUID?
            SequenceViewerView.beginExtractionBundleOperation(
                sourceName: run.result.sourceName, arguments: arguments, routeContext: nil, reporter: reporter
            ) { operationID = $0 }
            let id = try XCTUnwrap(operationID, "the row did not start")
            let result = try await runner.run(arguments: arguments, operationID: id)
            try Self.copyStage(staged.deletingLastPathComponent(), from: root)
            return RouteParitySideOutcome(
                end: .completed, detail: result.message ?? "", recordedCommand: reporter.items.first?.cliCommand
            )
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: "\(error)", recordedCommand: reporter.items.first?.cliCommand)
        }
    }

    /// Copies side C's staged folder to the same place under root C', with each spelling of root C in its
    /// files rewritten to root C', so side C' reads the FASTA its command names.
    private static func copyStage(_ stage: URL, from rootC: URL) throws {
        let stagePath = stage.standardizedFileURL.path
        let rootPath = rootC.standardizedFileURL.path
        guard stagePath.hasPrefix(rootPath + "/") else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: stagePath]) }
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: rootC.deletingLastPathComponent())
        let target = rootCPrime.appendingPathComponent(String(stagePath.dropFirst(rootPath.count + 1)), isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: stage, to: target)
        let renames = [(rootC.resolvingSymlinksInPath().path, rootCPrime.resolvingSymlinksInPath().path), (rootC.path, rootCPrime.path)]
        for name in try fileManager.subpathsOfDirectory(atPath: target.path) {
            let file = target.appendingPathComponent(name)
            guard let original = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let text = renames.reduce(original) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            if text != original { try text.write(to: file, atomically: true, encoding: .utf8) }
        }
    }

    // MARK: - Fixture

    /// A project with a FASTA document and a GenBank document of the same 60 bases.
    private static func writeFixture(_ root: URL) throws {
        let downloads = root.appendingPathComponent("Project.lungfish/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try ">NC_TEST.1 Test virus segment 4\n\(RegionExtractionWithoutBundlePinConformanceTests.bases)\n"
            .write(to: root.appendingPathComponent(fastaPath), atomically: true, encoding: .utf8)
        try RegionExtractionWithoutBundlePinConformanceTests.genBankText
            .write(to: root.appendingPathComponent(genBankPath), atomically: true, encoding: .utf8)
    }

    private func requireTools(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            try await BundleBuildHelpers.validateTools(using: .shared)
        } catch {
            try ToolAvailability.skipOrFail("Managed bgzip and samtools are required: \(error)", file: file, line: line)
        }
    }
}
