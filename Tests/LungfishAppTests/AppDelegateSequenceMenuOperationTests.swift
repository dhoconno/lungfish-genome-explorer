// AppDelegateSequenceMenuOperationTests.swift - begin() sites in AppDelegate+SequenceMenu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Sequence menu registers two rows through static begin helpers (R4).
// Find ORFs locks the bundle and runs `lungfish-cli sequence annotate-orfs`,
// so a held bundle lock must refuse its row and launch nothing, and its
// recorded command must parse with the run's values. Adding a manual
// annotation locks the bundle too and records `lungfish-cli sequence
// add-annotation`, whose Workflow function it runs in process (2.10 A42 M3,
// decision C3). AnnotationEditRouteParityTests replays that command.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateSequenceMenuOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Delete Annotation Track",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli sequence delete-annotation-track"
        ).startedID)
        return center
    }

    // MARK: - Find ORFs

    private func orfRequest() -> SequenceAnnotationOperationRequest {
        SequenceAnnotationOperationRequest(
            operation: .orf,
            bundleURL: bundleURL,
            sequenceName: "chr 1",
            start: 100,
            end: 2_500,
            frames: ["+1", "+2", "-1"],
            codonTableID: 11,
            trackID: "orfs_chr_1",
            trackName: "chr 1 ORFs",
            minimumORFLength: 150,
            includePartialORFs: true,
            allowAlternativeStarts: true
        )
    }

    func testSequenceAnnotationRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = AppDelegate.beginSequenceAnnotationOperation(
            request: orfRequest(),
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the Find ORFs row")
        }
        XCTAssertFalse(launched, "a refused row must start no CLI run")
        XCTAssertEqual(refusal.blockingOperationTitle, "Delete Annotation Track")
    }

    func testSequenceAnnotationRecordsItsTypeLockAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?

        AppDelegate.beginSequenceAnnotationOperation(
            request: orfRequest(),
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Find ORFs")
        XCTAssertEqual(item.initialDetail, "Running Find ORFs...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.AnnotateORFs.self)
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.sequence, "chr 1")
        XCTAssertEqual(command.start, 100)
        XCTAssertEqual(command.end, 2_500)
        XCTAssertEqual(command.frames, "+1,+2,-1")
        XCTAssertEqual(command.table, 11)
        XCTAssertEqual(command.trackID, "orfs_chr_1")
        XCTAssertEqual(command.trackName, "chr 1 ORFs")
        XCTAssertEqual(command.minLength, 150)
        XCTAssertTrue(command.includePartial)
        XCTAssertTrue(command.allowAlternativeStarts)
        XCTAssertTrue(command.globalOptions.quiet)
    }

    // MARK: - Add a manual annotation, run in process and recorded as sequence add-annotation

    /// A minus-strand feature whose name starts with a hyphen, the two values the parser would
    /// read as options if the command did not join them to theirs.
    private func manualAnnotation() -> SequenceAnnotation {
        SequenceAnnotation(
            type: .primer,
            name: "-35 box",
            chromosome: "chr 1",
            intervals: [AnnotationInterval(start: 120, end: 146)],
            strand: .reverse
        )
    }

    func testManualAnnotationRefusedByAHeldBundleLockWritesNothing() async throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = await AppDelegate.beginManualReferenceAnnotationOperation(
            annotation: manualAnnotation(),
            chromosome: "chr 1",
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center
        ) { _, _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the Add Annotation row")
        }
        XCTAssertFalse(launched, "a refused row must write nothing to the bundle")
        XCTAssertEqual(refusal.blockingOperationTitle, "Delete Annotation Track")
    }

    func testManualAnnotationLocksTheBundleAndRecordsTheAddCommandItsWriteRecords() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launched: (id: UUID, argv: [String])?

        await AppDelegate.beginManualReferenceAnnotationOperation(
            annotation: manualAnnotation(),
            chromosome: "chr 1",
            bundleURL: bundleURL,
            routeContext: routeContext,
            reporter: reporter
        ) { launched = ($0, $1) }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launched?.id, item.id)
        XCTAssertEqual(item.title, "Add Annotation")
        XCTAssertEqual(item.initialDetail, "Adding -35 box...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SequenceCommand.AddAnnotation.self)
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.chromosome, "chr 1")
        XCTAssertEqual(command.start, 120)
        XCTAssertEqual(command.end, 146)
        XCTAssertEqual(command.name, "-35 box")
        XCTAssertEqual(command.type, "primer")
        XCTAssertEqual(command.strand, "-")
        // The write's record names the same command the row shows.
        XCTAssertEqual(launched?.argv, [LungfishAppIdentity.recordedToolName] + (try RecordedCLICommand.arguments(of: item.cliCommand)))
    }
}
