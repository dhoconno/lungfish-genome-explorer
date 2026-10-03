// AppDelegateSequenceMenuOperationTests.swift - begin() sites in AppDelegate+SequenceMenu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Sequence menu registers two rows through static begin helpers (R4).
// Find ORFs locks the bundle and runs `lungfish-cli sequence annotate-orfs`,
// so a held bundle lock must refuse its row and launch nothing, and its
// recorded command must parse with the run's values. Adding a manual
// annotation declares no bundle lock today and has no lungfish-cli
// equivalent. Its tests pin both facts, so a lock or a command added later
// fails here and prompts a deliberate test change.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
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

    // MARK: - Add a manual annotation, a lock-free site and a CLI parity gap

    func testManualAnnotationRefusedBeginLaunchesNothing() async throws {
        // The site declares no bundle lock, so no real center refuses it. A
        // reporter that refuses every begin still proves the branch.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = await AppDelegate.beginManualReferenceAnnotationOperation(
            annotationName: "Primer site",
            routeContext: nil,
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a refused begin must not start the annotation write")
        }
        XCTAssertFalse(launched, "a refused row must write nothing to the bundle")
        XCTAssertEqual(refusal.blockingOperationTitle, "Importing BAM")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    func testManualAnnotationRecordsNoLockAndNoCommandAsAParityGap() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?

        await AppDelegate.beginManualReferenceAnnotationOperation(
            annotationName: "Primer site",
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Add Annotation")
        XCTAssertEqual(item.initialDetail, "Adding Primer site...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        // The write changes the bundle and declares no lock, as it did before
        // the migration. A lock added later fails these two assertions.
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gap. No lungfish-cli command adds an annotation to a
        // bundle. The closest is `sequence update-annotation`, which edits an
        // existing row. When an add command exists, record it and replace
        // this pin with a parse test.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "annotation-add")
    }
}
