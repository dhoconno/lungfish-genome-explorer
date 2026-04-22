import XCTest
@testable import LungfishApp

@MainActor
final class InspectorFilteredAlignmentWorkflowTests: XCTestCase {
    func testLaunchContextReloadsMappingViewerWhenWorkflowStartedFromMappingMode() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfishref", isDirectory: true)
        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            isMappingViewerDisplayedAtLaunch: true,
            canStartBundleMutation: { _ in true },
            activeBundleMutationTitle: { _ in nil }
        )

        guard case .launch(let context) = outcome else {
            return XCTFail("Expected workflow launch context")
        }

        var reloadedMappingViewer = false
        var displayedBundleURLs: [URL] = []
        try context.reload(
            using: FilteredAlignmentWorkflowReloadActions(
                reloadMappingViewerBundle: {
                    reloadedMappingViewer = true
                },
                displayBundle: { url in
                    displayedBundleURLs.append(url)
                }
            )
        )

        XCTAssertTrue(reloadedMappingViewer)
        XCTAssertEqual(displayedBundleURLs, [])
        XCTAssertEqual(context.reloadFailureAlertTitle, "Mapping Viewer Reload Failed")
    }

    func testLaunchContextReloadsBundleViewerWhenWorkflowStartedOutsideMappingMode() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfishref", isDirectory: true)
        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            isMappingViewerDisplayedAtLaunch: false,
            canStartBundleMutation: { _ in true },
            activeBundleMutationTitle: { _ in nil }
        )

        guard case .launch(let context) = outcome else {
            return XCTFail("Expected workflow launch context")
        }

        var reloadedMappingViewer = false
        var displayedBundleURLs: [URL] = []
        try context.reload(
            using: FilteredAlignmentWorkflowReloadActions(
                reloadMappingViewerBundle: {
                    reloadedMappingViewer = true
                },
                displayBundle: { url in
                    displayedBundleURLs.append(url)
                }
            )
        )

        XCTAssertFalse(reloadedMappingViewer)
        XCTAssertEqual(displayedBundleURLs, [bundleURL])
        XCTAssertEqual(context.reloadFailureAlertTitle, "Reload Failed")
    }

    func testStartOutcomeBlocksWhenAnotherBundleMutationIsRunning() {
        let bundleURL = URL(fileURLWithPath: "/tmp/locked-fixture.lungfishref", isDirectory: true)
        let operationID = OperationCenter.shared.start(
            title: "Variant Calling",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL
        )
        defer {
            OperationCenter.shared.fail(id: operationID, detail: "Cancelled for test cleanup")
        }

        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            isMappingViewerDisplayedAtLaunch: false
        )

        guard case .blocked(let alert) = outcome else {
            return XCTFail("Expected bundle-lock conflict alert")
        }

        XCTAssertEqual(alert.title, "Operation in Progress")
        XCTAssertEqual(
            alert.message,
            "\"Variant Calling\" is currently running on this bundle. Please wait for it to finish."
        )
    }
}
