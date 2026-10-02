// AnnotationTableDrawerViewOperationTests.swift - begin() sites in AnnotationTableDrawerView
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Every stored variant edit (deleting variants, deleting all variants and
// importing sample metadata) registers one row through a static begin helper
// (R4) and locks the bundle. A held bundle lock must refuse the row and launch
// nothing. No lungfish-cli command edits stored variants yet, so the test pins
// that the row records no command and fails when a command is added.
// VariantStorageWorkerOwnershipTests covers the worker's lease and publication.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class AnnotationTableDrawerViewOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Sample.lungfishref", isDirectory: true)

    /// A fresh center whose bundle lock is already held, as when another
    /// operation is running on the same bundle.
    private func centerHoldingBundleLock() throws -> OperationCenter {
        let center = OperationCenter()
        _ = try XCTUnwrap(center.begin(
            title: "Calling variants with LoFreq",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: "lungfish-cli variants call"
        ).startedID)
        return center
    }

    func testVariantStorageMutationRefusedByAHeldBundleLockLaunchesNothing() throws {
        let center = try centerHoldingBundleLock()
        var launched = false

        let result = AnnotationTableDrawerView.beginVariantStorageMutationOperation(
            title: "Variant deletion",
            bundleURL: bundleURL,
            routeContext: nil,
            reporter: center
        ) { _ in launched = true }

        guard case .refused(let refusal) = result else {
            return XCTFail("a held bundle lock must refuse the stored variant edit")
        }
        XCTAssertFalse(launched, "a refused row must start no worker")
        XCTAssertEqual(refusal.blockingOperationTitle, "Calling variants with LoFreq")
    }

    func testVariantStorageMutationRecordsItsTypeAndLockAndNoCommandAsAParityGap() throws {
        let titles = ["Variant deletion", "Delete all variants", "Sample metadata import"]
        for title in titles {
            let reporter = RecordingOperationReporter()
            let routeContext = OperationRouteContext(
                projectURL: URL(fileURLWithPath: "/tmp/lane 1a2/Project.lungfish"),
                windowStateScopeID: UUID()
            )
            var launchedID: UUID?

            AnnotationTableDrawerView.beginVariantStorageMutationOperation(
                title: title,
                bundleURL: bundleURL,
                routeContext: routeContext,
                reporter: reporter
            ) { launchedID = $0 }

            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertEqual(launchedID, item.id)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.initialDetail, "Updating stored data and provenance")
            XCTAssertEqual(item.operationType, .workflow)
            XCTAssertEqual(item.targetBundleURL, bundleURL)
            XCTAssertEqual(item.additionalLockedBundleURLs, [])
            XCTAssertEqual(item.routeContext, routeContext)
            // CLI parity gap. No lungfish-cli command edits the variants stored
            // in a bundle. The closest is `variants query`, which only reads.
            // When an edit command exists, record it and replace this pin
            // with a parse test.
            XCTAssertNil(item.cliCommand)
            XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
        }
    }

    /// The drawer's own entry point registers its row through the helper, on
    /// the center it is given, and runs the worker only for a started row.
    func testRunVariantStorageMutationRegistersItsRowThroughTheHelper() async throws {
        _ = NSApplication.shared
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.searchIndex = AnnotationSearchIndex()
        let center = OperationCenter()

        let task = try XCTUnwrap(drawer.runVariantStorageMutation(
            title: "Variant deletion",
            bundleURL: bundleURL,
            center: center,
            work: { 7 },
            publish: { _ in }
        ))

        let item = try XCTUnwrap(center.items.first)
        XCTAssertEqual(item.title, "Variant deletion")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertNil(item.cliCommand)
        await task.value
        XCTAssertEqual(center.items.first?.state, .completed)
        XCTAssertTrue(center.canStartOperation(on: bundleURL))
    }
}
