// AppDelegateAnnotationTrackImportOperationTests.swift - The begin() site of the annotation track attach
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Import Center and a file dropped on the sidebar attach an annotation
// file to a reference bundle through one begin helper,
// `AppDelegate.beginAnnotationTrackImportOperation` (2.10 A42 M2). Its row
// keeps the words, type and lock the two inline sites registered before, and
// it records no command while no lungfish-cli command attaches a track. These
// pins replace the two inline pins of CLIParityGapInlineSiteTests, so a lock
// or a command added later fails here and prompts a deliberate change.

import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AppDelegateAnnotationTrackImportOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)
    private let annotationURL = URL(fileURLWithPath: "/tmp/lane 1a2/genes v2.gff3")

    func testAHeldBundleLockRefusesTheRowAndLaunchesNothing() async throws {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Find ORFs",
            detail: "Running",
            operationType: .bundleBuild,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli sequence annotate-orfs"
        ).startedID)
        var launched = false

        let result = await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a refused begin must not start the attach")
        }
        XCTAssertFalse(launched, "a refused row must write nothing to the bundle")
        XCTAssertEqual(refusal.blockingOperationTitle, "Find ORFs")
    }

    func testTheRowLocksTheBundleAndRecordsNoCommandForEitherSite() async throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(
            projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
            windowStateScopeID: UUID()
        )
        var launchedID: UUID?

        await AppDelegate.beginAnnotationTrackImportOperation(
            annotationURL: annotationURL,
            bundleURL: bundleURL,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "Annotation Import")
        XCTAssertEqual(item.initialDetail, "Importing genes v2.gff3...")
        XCTAssertEqual(item.operationType, .bundleBuild)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        // CLI parity gaps. No lungfish-cli command attaches a track to an
        // existing bundle. When `sequence attach-track` records here, replace
        // these pins with a parse test and a replay test.
        assertCLIParityGap(item.cliCommand, id: "annotation-attach-import-center")
        assertCLIParityGap(item.cliCommand, id: "annotation-attach-sidebar-drop")
    }
}
