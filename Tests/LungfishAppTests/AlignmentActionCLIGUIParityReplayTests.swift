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
// It launches the built lungfish-cli, so its name ends in ReplayTests and it runs in the
// integration tier.

import Foundation
import XCTest
import LungfishCore
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
    }

    /// Every difference A against C declares. Both routes write the removal's record through the
    /// one service, and the record differs only in the version of the process that wrote it.
    static let declared: [RouteParityDeclaredDifference<Case>] = {
        let record = "differs: Project.lungfish/Sample.lungfishref/provenance/removals/aln-derived.lungfish-provenance.json at "
        let reason = "Side A writes from the xctest process, whose bundle version is Xcode's. In the app the "
            + "in-process route and the bundled lungfish-cli both read the app's Info.plist "
            + "(ProvenanceRecord.swift:149-160), so a release records one version on both routes"
        let both: [Case: Int] = [.removeDerivedTrack: 1, .cancelWhileHashing: 1]
        return [
            RouteParityDeclaredDifference(both, record + "runtimeIdentity.appVersion", reason: reason, closedBy: "none, a harness fact"),
            RouteParityDeclaredDifference(both, record + "tool.version", reason: reason, closedBy: "none, a harness fact"),
            RouteParityDeclaredDifference(both, record + "toolVersion", reason: reason, closedBy: "none, a harness fact"),
            RouteParityDeclaredDifference(both, record + "workflowVersion", reason: reason, closedBy: "none, a harness fact"),
            RouteParityDeclaredDifference(
                [.removeDerivedTrack: 2], record + "steps[<ANY>].toolVersion", reason: reason, closedBy: "none, a harness fact"
            ),
        ]
    }()

    private var scratch: URL!
    private var cli: URL!
    private var harness: RouteParityHarness!

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

    // MARK: - Cases

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
