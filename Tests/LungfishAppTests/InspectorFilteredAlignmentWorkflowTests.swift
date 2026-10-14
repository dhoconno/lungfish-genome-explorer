import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class InspectorFilteredAlignmentWorkflowTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    func testLaunchContextUsesMappingResultTargetAndReloadsMappingViewerWhenStartedFromMappingMode() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfishref", isDirectory: true)
        let mappingResultURL = URL(fileURLWithPath: "/tmp/mapping-run", isDirectory: true)
        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: .mappingResult(mappingResultURL),
            isMappingViewerDisplayedAtLaunch: true,
            canStartBundleMutation: { _ in true },
            activeBundleMutationTitle: { _ in nil }
        )

        guard case .launch(let context) = outcome else {
            return XCTFail("Expected workflow launch context")
        }

        XCTAssertEqual(context.serviceTarget, .mappingResult(mappingResultURL))

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
            serviceTarget: .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: false,
            canStartBundleMutation: { _ in true },
            activeBundleMutationTitle: { _ in nil }
        )

        guard case .launch(let context) = outcome else {
            return XCTFail("Expected workflow launch context")
        }

        XCTAssertEqual(context.serviceTarget, .bundle(bundleURL))

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

    func testLaunchContextFallsBackToBundleTargetWhenMappingViewerHasNoResultDirectory() {
        let bundleURL = URL(fileURLWithPath: "/tmp/fixture.lungfishref", isDirectory: true)
        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: true,
            canStartBundleMutation: { _ in true },
            activeBundleMutationTitle: { _ in nil }
        )

        guard case .launch(let context) = outcome else {
            return XCTFail("Expected workflow launch context")
        }

        XCTAssertEqual(context.serviceTarget, .bundle(bundleURL))
        XCTAssertEqual(context.reloadTarget, .mappingViewer)
    }

    func testStartOutcomeBlocksWhenAnotherBundleMutationIsRunning() {
        let bundleURL = URL(fileURLWithPath: "/tmp/locked-fixture.lungfishref", isDirectory: true)
        let operationID = OperationCenter.shared.begin(
            title: "Variant Calling",
            detail: "Running",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: nil
        ).rowID
        defer {
            _ = OperationCenter.shared.fail(id: operationID, detail: "Cancelled for test cleanup")
        }

        let outcome = InspectorViewController.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
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

    func testBeginFilteredAlignmentWorkflowOperationLocksBundleUntilCompletion() throws {
        let bundleURL = URL(fileURLWithPath: "/tmp/filter-running-fixture.lungfishref", isDirectory: true)
        let center = OperationCenter()
        var launchedID: UUID?

        InspectorViewController.beginFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            request: AlignmentFilterInspectorLaunchRequest(
                sourceTrackID: "aln-1",
                outputTrackName: "Exact Matches",
                filterRequest: AlignmentFilterRequest(identityFilter: .exactMatch)
            ),
            reporter: center
        ) { launchedID = $0 }
        let operationID = try XCTUnwrap(launchedID, "a free bundle must start and launch")

        XCTAssertFalse(center.canStartOperation(on: bundleURL))
        XCTAssertEqual(
            center.activeLockHolder(for: bundleURL)?.title,
            "Create Filtered Alignment Track"
        )

        _ = center.complete(
            id: operationID,
            detail: "Created filtered alignment track \"Exact Matches\"."
        )

        XCTAssertTrue(center.canStartOperation(on: bundleURL))
        XCTAssertNil(center.activeLockHolder(for: bundleURL))
    }

    func testApplyFilteredAlignmentSuccessFocusesAnalysisFilteringSection() {
        let vc = InspectorViewController()
        _ = vc.view

        vc.viewModel.selectedTab = .view

        vc.applyFilteredAlignmentSuccess(createdTrackID: "filtered-track")

        XCTAssertEqual(vc.viewModel.selectedTab, .analysis)
        XCTAssertEqual(vc.readStyleSectionViewModel.selectedVisibleAlignmentTrackID, "filtered-track")
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.visibleAlignmentTrackID, "filtered-track")
    }
}
