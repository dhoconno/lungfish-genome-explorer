// MappingRouteParityReplayTests.swift - The Map Reads routes and the recorded command, with minimap2 and samtools
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A46 M3 (panel G1, C4 and C13, ARCH 2 and 3, BIO 1 and 2, UX 1, 3 and 4, QA 1, 4
// and 5), cut down in Phase 2.11 lane A62 M3, which deleted the hidden mapping key and the in-process route
// it kept (K3). Map Reads runs `lungfish-cli map`. The parity cases map the mapping golden's fixture
// (MappingRouteGolden, Tests/Fixtures/sarscov2 with minimap2, the sr preset, paired reads and two threads)
// on the two sides of RouteParityHarness that remain, with no side A (ReadsRouteParity.runCAndCPrime).
//
// - Side C, the CLI route, `runSingleManagedMappingThroughCLI` on the built CLI.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// The route takes the analysis folder the fixture made, without a run record, as a batch child
// takes its folder, so the two roots name one folder. Each case holds C against C' to nothing
// declared. The plain FASTA case also holds side C's row to the row M2 froze (the stage words, the lines
// logged and the end, Fixtures/MappingRouteRow/plain-fasta.txt), and side C's BAM, counts and record to
// the mapping golden (BIO 1). The SIGTERM case cancels the route's `map` argv through the real transport
// once a stand-in minimap2 runs, in a conda root of its own.
//
// Phase 2.11 lane A62 M1 (SW20, K11) added a case that maps a virtual FASTQ bundle, so the run materializes
// its input (BIO's ruling D8, choice 2, and B7, each bundle with its digest at the run level), and a case that
// maps onto a `.lungfishref`, the launch the plain FASTA case never reaches, so the route publishes the
// reference viewer bundle. Both ran against the in-process route as side A until M3.
//
// minimap2 and samtools are the storage root's own, stated with ToolAvailability, and the class
// launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier (docs/contracts/CLI-EQUIVALENCE.md).

import CryptoKit
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
final class MappingRouteParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var cliBinary: URL!

    enum Case: String, Sendable {
        case sarscov2PairedMinimap2
        case sarscov2MaterializedBundleMinimap2
        case sarscov2PairedMinimap2OntoReferenceBundle
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "mapping-route-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    func testTheMapReadsRoutesAgreeAndTheRecordedCommandReproducesTheCLIRoute() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        let samtools = try await ToolAvailability.require("samtools", environment: "samtools")
        let (runs, rows) = try await runTwoSides(
            .sarscov2PairedMinimap2,
            fixture: { root in
                // The folder carries no run record, so the replay owns and completes it as a
                // fresh run of the command would, rather than leaving it to the test process.
                _ = AnalysisRunRecord.markComplete(try MappingRouteGolden.Fixture(in: root).analysisDirectory)
            },
            request: { root in try Self.request(in: root) }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        let result = try harness.evaluate(Case.sarscov2PairedMinimap2, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(Case.sarscov2PairedMinimap2)")
        // UX 1 and 3, the CLI route's row shows the words, bar, lines and end of the in-process row
        // M2 froze. The frozen file still holds that route's step back to 0.93 after the bar reached 1,
        // which the CLI row never shows (it holds the bar, W2), so both bars are read through
        // comparableBar (QA's ruling D9).
        let row = try XCTUnwrap(rows[.c])
        let frozen = try String(contentsOf: MappingRouteRow.frozenFolder.appendingPathComponent("plain-fasta.txt"), encoding: .utf8)
        XCTAssertEqual(
            MappingRouteRow.comparableText(row.text), MappingRouteRow.comparableText(frozen),
            "the CLI route's row shows what the in-process row M2 froze"
        )

        // BIO 1, side C's BAM, counts and record are the golden's.
        let folder = try Self.analysisFolder(in: runs.c.root)
        let mapping = try MappingResult.load(from: folder)
        try MappingRouteGolden.assertMatchesGolden(
            outputDirectory: folder, bam: mapping.bamURL, totalReads: mapping.totalReads,
            mappedReads: mapping.mappedReads, samtools: samtools
        )

        // BIO's ruling D8 on A46 M3. The record names the command the row recorded (CLI-EQUIVALENCE,
        // provenance names the command), while its steps keep minimap2's.
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "side C wrote no record in \(folder.path)")
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        // The record keeps project paths, which load back under the scratch folder's other spelling.
        let roots = ["/private" + scratch.standardizedFileURL.path, scratch.standardizedFileURL.path]
        let spelled = { (words: [String]) in words.map { roots.reduce($0) { $1.isEmpty ? $0 : $0.replacingOccurrences(of: $1, with: "<scratch>") } } }
        XCTAssertEqual(spelled(Array(record.argv.dropFirst())), spelled(try RecordedCLICommand.arguments(of: command)))
    }

    // MARK: - Onto a .lungfishref, and from a materialized input (Phase 2.11 lane A62, K11 and SW20)

    private typealias Fixture = MappingViewerBundlePublicationSigningReplayTests

    private var harness: RouteParityHarness {
        RouteParityHarness(cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120))
    }

    /// BIO's ruling D8 on A46 M3 and B7 (SW20). The input is a virtual FASTQ bundle, so each route materializes it
    /// before the mapper runs. Every record names the run's own `lungfish-cli map` command with no replay of the
    /// mapper beside it, lists the bundle and the files it reads at the run level with their digests, and no step
    /// makes a bundle. Only the materialization step names the bundle, as the input it read.
    func testTheMapReadsRoutesAgreeFromAMaterializedInput() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let parityCase = Case.sarscov2MaterializedBundleMinimap2
        // The digests are read before any side runs, from the bundle as the user chose it, by path under the root.
        var expected: [(path: String, digest: String?)] = []
        let (runs, _) = try await runTwoSides(
            parityCase,
            fixture: { root in
                try Self.writeMaterializedFixture(root)
                let rootPath = URL(fileURLWithPath: root.path).standardizedFileURL.path
                expected = try CLISequenceInputMaterialization
                    .originalInputDescriptors(for: root.appendingPathComponent(Self.materializedBundle, isDirectory: true))
                    .map { (String($0.path.dropFirst(rootPath.count)), $0.checksumSHA256) }
            },
            request: { root in try Self.materializedRequest(in: root) }
        )
        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        for side in runs.all {
            try Self.assertMaterializedInputRecord(
                in: try Self.analysisFolder(in: side.root), root: side.root, side: side.side, expected: expected
            )
        }
    }

    /// The sidebar's Map Reads onto a `.lungfishref`, the launch the plain FASTA case never reaches (K11, SW20). Each
    /// side publishes the reference viewer bundle, C against C' shows nothing, and side C's row shows the viewer's words.
    func testTheMapReadsRoutesAgreeOntoAReferenceBundle() async throws {
        _ = try await ToolAvailability.require("minimap2", environment: "minimap2")
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let parityCase = Case.sarscov2PairedMinimap2OntoReferenceBundle
        let (runs, rows) = try await runTwoSides(
            parityCase,
            fixture: { root in try Fixture.writeFixture(root, onReferenceBundle: true) },
            request: { root in try Fixture.request(in: root, onReferenceBundle: true) }
        )
        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase)")
        for side in runs.all {
            MappingRoutePrivateProjectReplayTests.assertViewerPublished(in: try Self.analysisFolder(in: side.root))
        }
        XCTAssertTrue(try XCTUnwrap(rows[.c]).shown.contains("Validating alignment file..."), "side C's row never showed the viewer's words")
    }

    /// Runs `parityCase` on side C and side C', with the request `makeRequest` builds for its root, and keeps the row
    /// side C showed. There is no side A, since the in-process route went with the mapping key (Phase 2.11, K3).
    private func runTwoSides(
        _ parityCase: Case,
        fixture: (URL) throws -> Void,
        request makeRequest: @escaping (URL) throws -> MappingRunRequest
    ) async throws -> (RouteParityRuns, [RouteParitySide: MappingRouteRow]) {
        var rows: [RouteParitySide: MappingRouteRow] = [:]
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("\(parityCase)", isDirectory: true),
            fixture: fixture,
            sideC: { root in
                let request = try makeRequest(root)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (row, item) = try await ReadsRouteParity.record(title: Self.title(of: request)) {
                    Task { @MainActor in
                        await AppDelegate().runSingleManagedMappingThroughCLI(
                            request: request, warning: nil, routeContext: nil,
                            preassignedAnalysisDirectory: request.outputDirectory, runner: runner,
                            cancelBatch: {}, registerCancel: { _ in }
                        )
                    }
                }
                rows[.c] = row
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )
        return (runs, rows)
    }

    nonisolated static func title(of request: MappingRunRequest) -> String {
        "Map Reads (\(request.tool.displayName)): \(request.sampleName)"
    }

    // MARK: - The materialized input

    /// The virtual bundle of the materialized case, under a side root, and the root bundle it reads.
    nonisolated static let materializedBundle = "Project.lungfish/Imports/pooled-oriented.lungfishfastq"
    nonisolated static let materializedRootFASTQ = "Project.lungfish/Imports/pooled.lungfishfastq/pooled.fastq"

    /// The golden's project with its first mate file as a virtual bundle, an `orient` derivative that keeps every read
    /// forward over a root bundle that holds the reads, so mapping the bundle materializes its input.
    @MainActor
    static func writeMaterializedFixture(_ root: URL) throws {
        let fixture = try MappingRouteGolden.Fixture(in: root)
        let fileManager = FileManager.default
        let rootBundle = root.appendingPathComponent(materializedRootFASTQ).deletingLastPathComponent()
        let derived = root.appendingPathComponent(materializedBundle, isDirectory: true)
        for folder in [rootBundle, derived] { try fileManager.createDirectory(at: folder, withIntermediateDirectories: true) }
        let reads = try MappingRouteGolden.run(URL(fileURLWithPath: "/usr/bin/gunzip"), ["-c", fixture.readOne.path])
        try reads.write(to: root.appendingPathComponent(materializedRootFASTQ), atomically: true, encoding: .utf8)
        let lines = reads.split(separator: "\n", omittingEmptySubsequences: false)
        let identifiers = lines.enumerated().compactMap { index, line in
            index % 4 == 0 && line.hasPrefix("@") ? line.dropFirst().split(separator: " ").first.map(String.init) : nil
        }
        try (identifiers.map { "\($0)\t+" }.joined(separator: "\n") + "\n")
            .write(to: derived.appendingPathComponent("orient-map.tsv"), atomically: true, encoding: .utf8)
        try (lines.prefix(4).joined(separator: "\n") + "\n")
            .write(to: derived.appendingPathComponent("preview.fastq"), atomically: true, encoding: .utf8)
        let operation = FASTQDerivativeOperation(kind: .orient)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: "pooled-oriented",
                parentBundleRelativePath: "@/Imports/pooled.lungfishfastq",
                rootBundleRelativePath: "@/Imports/pooled.lungfishfastq",
                rootFASTQFilename: "pooled.fastq",
                payload: .orientMap(orientMapFilename: "orient-map.tsv", previewFilename: "preview.fastq"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: identifiers.count, baseCount: 0),
                pairingMode: .singleEnd,
                sequenceFormat: .fastq
            ),
            in: derived
        )
        _ = AnalysisRunRecord.markComplete(fixture.analysisDirectory)
    }

    /// The request the Map Reads window builds when the user chooses the virtual bundle of the fixture in `root`.
    @MainActor
    static func materializedRequest(in root: URL) throws -> MappingRunRequest {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let folder = try analysisFolder(in: root)
        let plan = MappingWizardSheet.buildRunPlan(
            bundleURLs: [root.appendingPathComponent(materializedBundle, isDirectory: true)],
            mode: .perBundle, tool: .minimap2, modeID: MappingMode.defaultShortRead.id,
            referenceFASTAURL: project.appendingPathComponent("inputs/genome.fasta"),
            sourceReferenceBundleURL: nil, projectURL: project, outputDirectory: folder, runToken: "parity",
            readGroupIDText: "", readGroupSampleText: "", readGroupLibraryText: "",
            readGroupPlatformText: "", readGroupPlatformUnitText: "", threads: 2,
            includeSecondary: false, includeSupplementary: true, minimumMappingQuality: 0, advancedArguments: []
        )
        return try XCTUnwrap(plan.requests.first).withOutputDirectory(folder)
    }

    /// BIO's ruling D8 and B7 on the record a side left in `folder`.
    nonisolated static func assertMaterializedInputRecord(
        in folder: URL, root: URL, side: RouteParitySide, expected: [(path: String, digest: String?)],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "side \(side) wrote no record in \(folder.path)", file: file, line: line)
        let canonical = { (path: String) in URL(fileURLWithPath: path).standardizedFileURL.path }
        // D8, choice 2. The record names the run's command, and no replay of the mapper stands beside it.
        XCTAssertEqual(Array(record.argv.prefix(2)), [CLICommandIdentity.executableName, "map"], "side \(side) argv", file: file, line: line)
        XCTAssertNil(record.durableReplayArgv, "side \(side) keeps a mapper replay beside the run command", file: file, line: line)
        XCTAssertTrue(
            record.reproducibleCommand.hasPrefix("\(CLICommandIdentity.executableName) map "),
            "side \(side) reproducibleCommand \(record.reproducibleCommand)", file: file, line: line
        )
        // B7. Every file of the bundle is at the run level with the digest of its bytes, and the bundle with its own.
        let bundle = root.appendingPathComponent(materializedBundle, isDirectory: true)
        let recorded = Dictionary(record.files.map { (canonical($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertGreaterThanOrEqual(expected.count, 3, "the bundle, its manifest and its reads", file: file, line: line)
        for (relative, digest) in expected {
            let path = canonical(root.path) + relative
            let entry = recorded[path]
            XCTAssertNotNil(entry, "side \(side) lists no \(path) at the run level", file: file, line: line)
            XCTAssertEqual(entry?.checksumSHA256, digest, "side \(side) digest of \(path)", file: file, line: line)
            XCTAssertFalse((entry?.checksumSHA256 ?? "").isEmpty, "side \(side) lists \(path) with no digest", file: file, line: line)
        }
        let reads = root.appendingPathComponent(materializedRootFASTQ)
        let readsDigest = SHA256.hash(data: try Data(contentsOf: reads)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(recorded[canonical(reads.path)]?.checksumSHA256, readsDigest, "side \(side) digest of the reads", file: file, line: line)
        // No step makes a bundle, and only the materialization step names the bundle, as the input it read.
        let bundlePath = canonical(bundle.path)
        XCTAssertEqual(
            record.steps.filter { $0.outputs.contains { canonical($0.path) == bundlePath } }.map(\.toolName), [],
            "side \(side) has a step that makes the bundle", file: file, line: line
        )
        XCTAssertEqual(
            record.steps.filter { $0.inputs.contains { canonical($0.path) == bundlePath } }.map(\.toolName),
            [CLISequenceInputMaterialization.materializationToolName], "side \(side) steps that name the bundle", file: file, line: line
        )
    }

    // MARK: - SIGTERM through the transport (P2, SWIFT 3 and 7)

    /// The Map Reads row's cancel reaches `map` as SIGTERM through the transport every CLI route
    /// uses, once the mapper runs. The command exits 125 inside the grace, records its run as
    /// cancelled, leaves its folder out of the sidebar, and no process of its tree is left.
    func testSIGTERMThroughTheTransportCancelsMap() async throws {
        let tools = scratch.appendingPathComponent("cancel-tools", isDirectory: true)
        let condaRoot = tools.appendingPathComponent("conda", isDirectory: true)
        let mapperPID = scratch.appendingPathComponent("mapper.pid")
        try ReadsRouteParity.write(
            ReadsRouteParity.sleepingMicromamba(tool: "minimap2", pidFile: mapperPID),
            executableAt: condaRoot.appendingPathComponent("bin/micromamba")
        )
        for (environment, executable) in [("minimap2", "minimap2"), ("samtools", "samtools")] {
            try ReadsRouteParity.write("#!/bin/sh\nexit 0\n", executableAt: condaRoot.appendingPathComponent("envs/\(environment)/bin/\(executable)"))
        }
        let home = tools.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let root = scratch.appendingPathComponent("cancel", isDirectory: true)
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("Analyses", isDirectory: true), withIntermediateDirectories: true)
        let folder = project.appendingPathComponent("Analyses/minimap2-sigterm", isDirectory: true)
        let reads = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let reference = root.appendingPathComponent("reference.fa")
        try ">chr1\n\(String(repeating: "ACGTTGCA", count: 20))\n".write(to: reference, atomically: true, encoding: .utf8)
        let request = MappingRunRequest(
            tool: .minimap2, modeID: MappingMode.defaultShortRead.id, inputFASTQURLs: [reads],
            referenceFASTAURL: reference, projectURL: project, outputDirectory: folder, sampleName: "sigterm", threads: 1
        )

        let run = await RouteParityHarness.runCLI(
            cliBinary, arguments: AppDelegate.managedMappingCLIArguments(for: request), timeout: .seconds(60),
            environment: [
                "LUNGFISH_CONDA_ROOT": condaRoot.path,
                "LUNGFISH_STORAGE_ROOT": tools.appendingPathComponent("storage", isDirectory: true).path,
                "LUNGFISH_CONDA_SHARED_PKGS": "0",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
            ],
            cancelWhen: { FileManager.default.fileExists(atPath: mapperPID.path) }
        )

        let observed = try XCTUnwrap(run.cancel, "the mapper never ran, so nothing was cancelled: \(run.detail)\n\(run.stderr)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)\n\(run.stderr)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        CLISIGTERMHarness.assertRecordCancelled { AnalysisRunRecord.load(from: folder)?.outcome?.rawValue }
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(folder), "a cancelled run stays out of the sidebar")
    }

    // MARK: - The request of a side

    /// The one analysis folder the fixture made in `root`.
    nonisolated static func analysisFolder(in root: URL) throws -> URL {
        let analyses = root.appendingPathComponent("Project.lungfish/Analyses", isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(at: analyses, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(MappingTool.minimap2.rawValue)-") }
        return try XCTUnwrap(folders.count == 1 ? folders.first : nil, "one mapping folder in \(analyses.path): \(folders)")
    }

    /// The request the Map Reads window builds for the fixture in `root` (MappingRouteGolden), bound
    /// to the fixture's folder.
    nonisolated static func request(in root: URL) throws -> MappingRunRequest {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputs = project.appendingPathComponent("inputs", isDirectory: true)
        let modeID = MappingMode.defaultShortRead.id
        return MappingRunRequest(
            tool: .minimap2,
            modeID: modeID,
            inputFASTQURLs: [inputs.appendingPathComponent("test_1.fastq.gz"), inputs.appendingPathComponent("test_2.fastq.gz")],
            referenceFASTAURL: inputs.appendingPathComponent("genome.fasta"),
            projectURL: project,
            outputDirectory: try analysisFolder(in: root),
            sampleName: MappingRouteGolden.sampleName,
            readGroup: MappingReadGroup.resolved(
                sampleName: MappingRouteGolden.sampleName, id: nil, readGroupSampleName: nil, library: nil,
                platform: nil, platformUnit: nil, defaultPlatform: MappingReadGroup.defaultPlatform(forModeID: modeID)
            ),
            pairedEnd: true,
            threads: 2,
            includeSecondary: false,
            includeSupplementary: true,
            minimumMappingQuality: 0,
            advancedArguments: []
        )
    }
}
