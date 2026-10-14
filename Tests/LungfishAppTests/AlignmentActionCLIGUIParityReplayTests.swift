// AlignmentActionCLIGUIParityReplayTests.swift - The L3 alignment actions on the CLI against the in-process route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 family L3 (lanes A51 and A54), on lane Q30's `RouteParityHarness` (G1, QC-2). Side A is
// the in-process route, the Workflow service the Inspector awaited in the app. Side C is the CLI
// route, whose row records `lungfish-cli bam remove-track` and whose L3 runner runs it through the
// app's transport. Side C' replays the recorded command. The removal's record is written by the
// service on both routes, so A against C declares nothing (C4, ARCH 7), and the in-process path goes.
//
// The tracks hold the sarscov2 BAM, which the bundle comparison reads with samtools. The cancel
// case makes the derived statistics database a sparse 1 GiB file, cancels each side once it holds
// that file open to hash it, and checks sides C and C' with lane S30's assertions through the real
// transport (SWIFT 3, S30 note 2). Side A cancels the service's task at the same point.
//
// The consensus cases (ruling A51-consensus) run the viewer's Generate Consensus for a FASTA, a
// reference bundle and an all-N result the user accepted. Side A is today's in-process route, the
// consensus call and the publication service the viewer awaited. Side C begins the viewer's row,
// which records `lungfish-cli bam consensus`, and runs it on the L3 runner, which answers the all-N
// refusal with the user's answer and records it with `setCommand`. Both write the record through
// the one service, so A against C declares nothing (C4).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class AlignmentActionCLIGUIParityReplayTests: XCTestCase {
    enum Case: String, Sendable {
        case removeDerivedTrack
        case refuseSourceTrack
        case cancelWhileHashing
        case consensusFASTA
        case consensusBundle
        case consensusAcceptedAllN
        case regionReads
        case selectedReads
    }

    /// Every difference A against C declares, none (C4). Both routes write the removal's record
    /// and the consensus record through one service each, which names `LungfishAppVersion.short`
    /// as the leaves do, so the xctest host of side A lends no record a version (the A42
    /// precedent, commit 1082a4b88).
    static let declared: [RouteParityDeclaredDifference<Case>] = []

    private static let contig = "MT192765.1"
    private static let contigLength = 29829

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

    override func setUp() async throws {
        try await super.setUp()
        // Side C of a consensus case begins its row on the shared center, and a run that fails ends
        // it failed, whose report stays out of the user's ~/Library/Logs.
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "alignment-action-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .bundle, replayTimeout: .seconds(120))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: - Sides

    /// The derived statistics database, the file the cancel case makes large.
    nonisolated private static func slowFile(in root: URL) -> URL {
        DerivedAlignmentTrackFixture.existing(in: root).bundleURL
            .appendingPathComponent(DerivedAlignmentTrackFixture.derivedArtifactPaths[2])
    }

    /// The fixture with real alignments, which the bundle comparison reads with samtools.
    nonisolated private static func makeFixture(in root: URL, slowFileSize: UInt64? = nil) throws {
        let fixture = try DerivedAlignmentTrackFixture.make(in: root)
        try fixture.useAlignment(
            ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        )
        if let slowFileSize { try fixture.makeDerivedDatabaseSparse(size: slowFileSize) }
    }

    nonisolated private static func recordStatus(in root: URL) throws -> String? {
        let url = BundleAlignmentTrackRemovalRecord.recordURL(
            bundleURL: DerivedAlignmentTrackFixture.existing(in: root).bundleURL,
            trackID: DerivedAlignmentTrackFixture.derivedTrackID
        )
        return try ProvenanceEnvelopeReader.load(fromSidecar: url)?.status.rawValue
    }

    /// Side A, the in-process route: the service the Inspector's task awaited. With `cancelAtWork`
    /// the task is cancelled once this process holds the derived BAM open to hash it.
    private static func sideA(_ root: URL, trackID: String, cancelAtWork: Bool = false) async -> RouteParitySideOutcome {
        let bundleURL = DerivedAlignmentTrackFixture.existing(in: root).bundleURL
        let task = Task.detached {
            try await BundleAlignmentTrackRemovalService().removeDerivedAlignmentTrack(bundleURL: bundleURL, trackID: trackID)
        }
        if cancelAtWork {
            let bam = slowFile(in: root).path
            let pid = getpid()
            _ = await waitUntil(timeout: CLISIGTERMHarness.processWait, pollInterval: .milliseconds(20)) {
                OpenFileProbe.process(pid, holdsOpen: bam)
            }
            task.cancel()
        }
        do {
            let result = try await task.value
            return RouteParitySideOutcome(end: .completed, detail: "removed \(result.removedArtifactURLs.count) files")
        } catch is CancellationError {
            return RouteParitySideOutcome(end: .cancelled, detail: "cancelled")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription)
        }
    }

    /// The row of side C, begun on a recording reporter, with its recorded command and argv.
    private static func beginSideC(_ root: URL, trackID: String) throws -> (id: UUID, command: String?, arguments: [String]) {
        let bundleURL = DerivedAlignmentTrackFixture.existing(in: root).bundleURL
        let reporter = RecordingOperationReporter()
        var launched: UUID?
        InspectorViewController.beginRemoveDerivedAlignmentOperation(
            trackName: DerivedAlignmentTrackFixture.derivedTrackName,
            trackID: trackID,
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: reporter
        ) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let arguments = InspectorViewController.removeDerivedAlignmentCLIArguments(bundleURL: bundleURL, trackID: trackID)
        return (id, reporter.items.first?.cliCommand, arguments)
    }

    /// Side C, the CLI route. The row's begin helper records the command and the L3 runner runs it
    /// through the app's transport, as the Inspector does.
    private func sideC(_ root: URL, trackID: String) async throws -> RouteParitySideOutcome {
        let row = try Self.beginSideC(root, trackID: trackID)
        let outcome = await withCheckedContinuation { continuation in
            InspectorViewController.runRemoveDerivedAlignmentThroughCLI(
                bundleURL: DerivedAlignmentTrackFixture.existing(in: root).bundleURL,
                trackID: trackID,
                operationID: row.id,
                runner: CLIAlignmentActionRunner(cliURLOverride: cli)
            ) { continuation.resume(returning: $0) }
        }
        switch outcome {
        case .success(let completion):
            return RouteParitySideOutcome(end: .completed, detail: completion.message ?? "", recordedCommand: row.command)
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: row.command)
        }
    }

    // MARK: - Consensus sides

    /// The sarscov2 BAM and its index, the evidence the viewer shows, copied into the root, and
    /// the folder the user chose in the save panel.
    nonisolated private static func makeConsensusFixture(in root: URL) throws {
        let fileManager = FileManager.default
        let bam = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/sarscov2/test.paired_end.sorted.bam")
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        try fileManager.createDirectory(at: evidence, withIntermediateDirectories: true)
        try fileManager.copyItem(at: bam, to: evidence.appendingPathComponent("S1.bam"))
        try fileManager.copyItem(at: URL(fileURLWithPath: bam.path + ".bai"), to: evidence.appendingPathComponent("S1.bam.bai"))
        try fileManager.createDirectory(at: root.appendingPathComponent("out", isDirectory: true), withIntermediateDirectories: true)
    }

    /// What the viewer holds for root `root` and builds for Generate Consensus over the whole
    /// contig, every filter off but the depth, as `presentAlignmentConsensusGeneration` does.
    private static func consensusRequest(
        in root: URL,
        minimumDepth: Int
    ) throws -> (context: AlignmentActionContext, export: MappingConsensusExportRequest) {
        let bam = root.appendingPathComponent("evidence/S1.bam")
        let index = root.appendingPathComponent("evidence/S1.bam.bai")
        func snapshot(_ url: URL) throws -> AlignmentEvidenceFileSnapshot {
            .init(url: url, byteCount: try ProvenanceFileHasher.fileSize(of: url), sha256: try ProvenanceFileHasher.sha256(of: url))
        }
        let context = try AlignmentActionContext(
            identity: .init(workflow: "mapping", resultID: "run-1", sampleID: "S1", evidenceID: contig),
            alignmentURL: bam, indexURL: index, decodingReferenceURL: nil,
            contig: contig, contigLength: contigLength,
            alignmentSnapshot: try snapshot(bam), indexSnapshot: try snapshot(index), decodingReferenceSnapshot: nil,
            filters: .init(minimumDepth: minimumDepth, minimumMapQ: 0, minimumBaseQuality: 0, excludedFlags: 0x904, readGroups: []),
            outputCapability: .userSelectedDestination, sourceReads: .bamFallback, presentationLabel: "S1 \(contig)"
        )
        let export = try MappingConsensusExportRequestBuilder.build(
            sampleName: "S1", context: context,
            region: ResolvedAlignmentRegion(scope: .wholeContig, contig: contig, start: 0, end: contigLength),
            consensusMode: .bayesian, useAmbiguity: false
        )
        return (context, export)
    }

    /// Side A, today's in-process route: the consensus call and, after the second check of the
    /// evidence, the publication service, with the user's answer to an all-N result.
    private static func consensusSideA(_ root: URL, output: String, minimumDepth: Int) async -> RouteParitySideOutcome {
        do {
            let (context, export) = try consensusRequest(in: root, minimumDepth: minimumDepth)
            let result = try await AlignmentDataProvider(
                alignmentPath: context.alignmentURL.path, indexPath: context.indexURL.path, format: .bam, referenceFastaPath: nil
            ).fetchConsensus(export.consensusRequest)
            try await context.validateCurrentSnapshots()
            let url = root.appendingPathComponent(output)
            let bundle = url.pathExtension == "lungfishref"
            _ = try AlignmentConsensusPublicationService().publish(AlignmentConsensusPublicationRequest(
                context: context, region: export.region, consensusRequest: export.consensusRequest, result: result,
                recordName: export.recordName, destination: bundle ? .referenceBundle(url) : .fasta(url),
                allowAllLowDepth: result.allLowDepth
            ))
            return RouteParitySideOutcome(end: .completed, detail: bundle ? "Consensus reference bundle created" : "Consensus FASTA saved")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription)
        }
    }

    /// Side C, the CLI route. The viewer's begin helper records `bam consensus` on a row of the
    /// shared center and its run helper runs it on the L3 runner, answering the all-N refusal with
    /// Continue, which records the answer on that row with `setCommand`.
    private func consensusSideC(_ root: URL, output: String, minimumDepth: Int) async throws -> RouteParitySideOutcome {
        let (context, export) = try Self.consensusRequest(in: root, minimumDepth: minimumDepth)
        let invocation = AlignmentConsensusInvocation(
            context: context, region: export.region, consensusRequest: export.consensusRequest,
            recordName: export.recordName, output: root.appendingPathComponent(output).path
        )
        var launched: UUID?
        ViewerViewController.beginAlignmentConsensusGenerationOperation(invocation: invocation) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let runner = CLIAlignmentActionRunner(cliURLOverride: cli)
        let outcome = await withCheckedContinuation { continuation in
            ViewerViewController.runAlignmentConsensusThroughCLI(
                invocation: invocation, workingDirectory: nil, operationID: id, runner: runner,
                confirmAllLowDepth: { true }, finish: { continuation.resume(returning: $0) }
            )
        }
        let command = OperationCenter.shared.items.first { $0.id == id }?.cliCommand
        switch outcome {
        case .success(let completion):
            _ = OperationCenter.shared.complete(id: id, detail: completion.message ?? "")
            return RouteParitySideOutcome(end: .completed, detail: completion.message ?? "", recordedCommand: command)
        case .failure(let error):
            _ = OperationCenter.shared.fail(id: id, detail: "Alignment consensus failed", errorMessage: error.localizedDescription)
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: command)
        }
    }

    private func assertConsensusParity(_ parityCase: Case, output: String, minimumDepth: Int = 1) async throws -> RouteParityResult {
        try await harness.assertParity(
            parityCase, declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { try Self.makeConsensusFixture(in: $0) },
            sideA: { await Self.consensusSideA($0, output: output, minimumDepth: minimumDepth) },
            sideC: { try await self.consensusSideC($0, output: output, minimumDepth: minimumDepth) }
        )
    }

    // MARK: - Read sides (M3, census row 22)

    /// The names the selected-reads case selects, in the file the route writes before its row begins.
    nonisolated private static let selectedNames = ["ERR5069949.114870", "ERR5069949.29668"]

    /// The consensus evidence, with the names file beside the bundle the selected-reads case publishes.
    nonisolated private static func makeReadsFixture(in root: URL) throws {
        try makeConsensusFixture(in: root)
        try AlignmentReadExtractionInvocation.writeReadNames(selectedNames, to: root.appendingPathComponent("out/S1.read-names.txt"))
    }

    /// The run the route chooses for `root`: the region MT192765.1:1-3000, or the two selected reads,
    /// one of whose records held no sequence.
    private static func readsRequest(in root: URL, selected: Bool) throws -> (context: AlignmentActionContext, invocation: AlignmentReadExtractionInvocation) {
        let (context, _) = try consensusRequest(in: root, minimumDepth: 1)
        guard selected else {
            return (context, ViewerViewController.alignmentRegionExtractionInvocation(
                context: context, region: ResolvedAlignmentRegion(scope: .selectedRegion, contig: contig, start: 0, end: 3000),
                destination: .bundle(root.appendingPathComponent("out/region.lungfishfastq")), outputBaseName: "selected-region"
            ))
        }
        let records = selectedNames.map {
            AlignedRead(name: $0, flag: 0, chromosome: contig, position: 0, mapq: 60, cigar: [], sequence: "ACGT", qualities: [30, 30, 30, 30])
        } + [AlignedRead(name: selectedNames[0], flag: 256, chromosome: contig, position: 0, mapq: 0, cigar: [], sequence: "*", qualities: [])]
        return (context, ViewerViewController.selectedReadsExtractionInvocation(
            context: context, records: records, namesFile: root.appendingPathComponent("out/S1.read-names.txt"),
            destination: .bundle(root.appendingPathComponent("out/S1.lungfishfastq")), outputBaseName: "S1_selected_2reads"
        ))
    }

    /// Side A, today's in-process route: what the coordinator ran in the app, the stager and the
    /// publisher between two checks of the evidence, with the record the row's command names.
    private static func readsSideA(_ root: URL, selected: Bool) async -> RouteParitySideOutcome {
        do {
            let (context, invocation) = try readsRequest(in: root, selected: selected)
            let folder = invocation.outputURL.deletingLastPathComponent()
            try await context.validateCurrentSnapshots()
            let transaction: AlignmentReadExtractionTransaction
            if selected {
                transaction = try await AlignmentReadExtractionStager().stageReadIDsFromBAM(
                    config: ReadIDBAMExtractionConfig(
                        bamURL: context.alignmentURL, readIDs: Set(selectedNames), includeSecondary: false, excludeDuplicates: false,
                        outputDirectory: folder, outputBaseName: "S1_selected_2reads"
                    ),
                    recordsWithoutSequence: 1,
                    missingSequenceMessage: "1 selected alignment record(s) did not contain sequence."
                )
            } else {
                transaction = try await AlignmentReadExtractionStager().stageRegion(config: BAMRegionExtractionConfig(
                    bamURL: context.alignmentURL, indexURL: context.indexURL, decodingReferenceURL: nil,
                    regions: ["\(contig):1-3000"], fallbackToAll: false, minMapQ: 0, excludedFlags: 0x904, readGroups: [],
                    outputDirectory: folder, outputBaseName: "selected-region", deduplicateReads: false
                ))
            }
            try await context.validateCurrentSnapshots()
            _ = try AlignmentReadExtractionPublisher().publish(.init(
                transaction: transaction, destination: .bundle(invocation.outputURL), provenance: invocation.provenance
            ))
            return RouteParitySideOutcome(end: .completed, detail: "Alignment read extraction published")
        } catch {
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription)
        }
    }

    /// Side C, the CLI route. The viewer's begin helper records `extract reads` and its run helper
    /// runs it on the L3 runner.
    private func readsSideC(_ root: URL, selected: Bool) async throws -> RouteParitySideOutcome {
        let (context, invocation) = try Self.readsRequest(in: root, selected: selected)
        let reporter = RecordingOperationReporter()
        var launched: UUID?
        ViewerViewController.beginAlignmentReadExtractionOperation(
            title: selected ? "Extract Selected Reads" : "Extract Reads in Selected Region", detail: "Preparing…",
            invocation: invocation, evidence: context.identity, routeContext: nil, reporter: reporter
        ) { launched = $0 }
        let id = try XCTUnwrap(launched, "the row started")
        let command = reporter.items.first?.cliCommand
        let outcome = await withCheckedContinuation { continuation in
            ViewerViewController.runReadExtractionThroughCLI(
                arguments: ViewerViewController.alignmentReadExtractionCLIArguments(invocation),
                operationID: id,
                runner: CLIAlignmentActionRunner(cliURLOverride: cli)
            ) { continuation.resume(returning: $0) }
        }
        switch outcome {
        case .success:
            return RouteParitySideOutcome(end: .completed, detail: "Alignment read extraction published", recordedCommand: command)
        case .failure(let error):
            return RouteParitySideOutcome(end: .failed, detail: error.localizedDescription, recordedCommand: command)
        }
    }

    private func assertReadsParity(_ parityCase: Case, selected: Bool) async throws -> RouteParityResult {
        try await harness.assertParity(
            parityCase, declared: Self.declared,
            in: scratch.appendingPathComponent(parityCase.rawValue, isDirectory: true),
            fixture: { try Self.makeReadsFixture(in: $0) },
            sideA: { await Self.readsSideA($0, selected: selected) },
            sideC: { try await self.readsSideC($0, selected: selected) }
        )
    }

    // MARK: - Cases

    func testARegionsReadsAreTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await assertReadsParity(.regionReads, selected: false)
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    func testSelectedReadsAreTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await assertReadsParity(.selectedReads, selected: true)
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(
                fromSidecar: run.root.appendingPathComponent("out/S1.lungfishfastq/.lungfish-provenance.json")
            ))
            let names = run.root.appendingPathComponent("out/S1.read-names.txt").standardizedFileURL.path
            XCTAssertTrue(record.files.contains { $0.role == .input && $0.path == names }, "side \(run.side) names the names file")
        }
    }

    func testAConsensusFASTAIsTheSameFileAndRecordOnEveryRoute() async throws {
        let result = try await assertConsensusParity(.consensusFASTA, output: "out/S1.fasta")
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.c.outcome.detail, "Consensus FASTA saved")
    }

    func testAConsensusBundleIsTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await assertConsensusParity(.consensusBundle, output: "out/S1.lungfishref")
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
        }
        XCTAssertEqual(result.runs.c.outcome.detail, "Consensus reference bundle created")
    }

    func testAnAcceptedAllNConsensusIsTheSameOnEveryRouteAndTheRowRecordsTheAnswer() async throws {
        let result = try await assertConsensusParity(.consensusAcceptedAllN, output: "out/S1.fasta", minimumDepth: 100_000)
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            let fasta = try String(contentsOf: run.root.appendingPathComponent("out/S1.fasta"), encoding: .utf8)
            XCTAssertEqual(fasta, ">S1 \(Self.contig) consensus\n\(String(repeating: "N", count: Self.contigLength))\n", "side \(run.side)")
        }
        let command = try RecordedCLICommand.parse(result.runs.c.outcome.recordedCommand, as: BAMConsensusSubcommand.self)
        XCTAssertTrue(command.allowAllLowDepth, "the row records the user's Continue, which side C' replays")
    }

    func testTheConsensusRecordNamesTheOutputTheRowRecorded() async throws {
        let root = scratch.appendingPathComponent("record", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeConsensusFixture(in: root)
        let outcome = try await consensusSideC(root, output: "out/S1.fasta", minimumDepth: 1)
        XCTAssertEqual(outcome.end, .completed, outcome.detail)

        let arguments = try RecordedCLICommand.arguments(of: outcome.recordedCommand)
        let command = try RecordedCLICommand.parse(outcome.recordedCommand, as: BAMConsensusSubcommand.self)
        let fasta = URL(fileURLWithPath: command.outputPath)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: fasta)))
        XCTAssertEqual(record.output?.path, command.outputPath, "the record names the file the row's command writes")
        XCTAssertEqual(record.argv, [CLICommandIdentity.executableName] + arguments.dropLast(2), "and the row's command, events aside")
        XCTAssertEqual(Array(arguments.suffix(2)), ["--format", "json"])
    }

    func testRemovingADerivedTrackGivesTheSameBundleAndRecordOnEveryRoute() async throws {
        let result = try await harness.assertParity(
            Case.removeDerivedTrack, declared: Self.declared,
            in: scratch.appendingPathComponent("remove", isDirectory: true),
            fixture: { try Self.makeFixture(in: $0) },
            sideA: { await Self.sideA($0, trackID: DerivedAlignmentTrackFixture.derivedTrackID) },
            sideC: { try await self.sideC($0, trackID: DerivedAlignmentTrackFixture.derivedTrackID) }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(try Self.recordStatus(in: run.root), "completed", "side \(run.side)")
        }
        XCTAssertEqual(result.runs.c.outcome.detail, "Removed derived alignment track \"Sample 1 filtered\".")
    }

    func testASourceTrackIsRefusedOnEveryRouteAndNothingChanges() async throws {
        let result = try await harness.assertParity(
            Case.refuseSourceTrack, declared: Self.declared,
            in: scratch.appendingPathComponent("refuse", isDirectory: true),
            fixture: { try Self.makeFixture(in: $0) },
            sideA: { await Self.sideA($0, trackID: DerivedAlignmentTrackFixture.sourceTrackID) },
            sideC: { try await self.sideC($0, trackID: DerivedAlignmentTrackFixture.sourceTrackID) }
        )
        let refusal = BundleAlignmentTrackRemovalError.notDerivedTrack(DerivedAlignmentTrackFixture.sourceTrackID).localizedDescription
        XCTAssertEqual(result.runs.a.outcome.detail, refusal)
        XCTAssertEqual(result.runs.c.outcome.detail, refusal, "the sheet keeps today's words (W3)")
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .failed, "side \(run.side): \(run.outcome.detail)")
        }
    }

    func testACancelWhileHashingEndsCancelledWithARecordAndNoChangeOnEveryRoute() async throws {
        let cancel = RouteParityCancel(
            when: { OpenFileProbe.anyDescendant(holdsOpen: Self.slowFile(in: $0).path) },
            record: { try Self.recordStatus(in: $0) }
        )
        let cli = cli!
        let result = try await harness.assertParity(
            Case.cancelWhileHashing, declared: Self.declared,
            in: scratch.appendingPathComponent("cancel", isDirectory: true),
            cancel: cancel,
            fixture: { try Self.makeFixture(in: $0, slowFileSize: 1 << 30) },
            sideA: { await Self.sideA($0, trackID: DerivedAlignmentTrackFixture.derivedTrackID, cancelAtWork: true) },
            sideC: { root in
                let row = try Self.beginSideC(root, trackID: DerivedAlignmentTrackFixture.derivedTrackID)
                let run = await RouteParityHarness.runCLI(
                    cli, arguments: row.arguments, timeout: .seconds(120), cancelWhen: { cancel.isReached(root) }
                )
                return RouteParitySideOutcome(end: run.end, detail: run.detail, recordedCommand: row.command, cancel: run.cancel)
            }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .cancelled, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(
                try BundleManifest.load(from: DerivedAlignmentTrackFixture.existing(in: run.root).bundleURL).alignments.count, 2,
                "side \(run.side) keeps the track"
            )
        }
    }
}
