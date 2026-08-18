// UpdateToolsSheetViewModelTests.swift - Selection, sizing, and gating for the Update Tools sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class UpdateToolsSheetViewModelTests: XCTestCase {

    private func plan() -> ReconciliationPlan {
        var plan = ReconciliationPlan(
            installEnvironments: [],
            reinstallEnvironments: [],
            removeEnvironments: [],
            databaseUpdates: [],
            pipelinePrefetch: [],
            bootstrapUpdate: nil,
            targetDependencySet: "2026.2",
            estimatedDownloadBytes: 0
        )
        plan.reinstallEnvironments = [
            .init(
                environment: "samtools",
                packID: "lungfish-tools",
                currentSpec: "a",
                targetSpec: "b",
                reason: .specChanged,
                isRequired: true
            ),
            .init(
                environment: "minimap2",
                packID: "read-mapping",
                currentSpec: "a",
                targetSpec: "b",
                reason: .specChanged,
                isRequired: false
            ),
        ]
        plan.databaseUpdates = [
            .init(
                id: "kraken2-viral",
                displayName: "Viral",
                installedVersion: "1",
                targetVersion: "2",
                policy: .advisory,
                estimatedBytes: 500,
                managedBy: .metagenomicsRegistry
            ),
            .init(
                id: "deacon-panhuman",
                displayName: "PH",
                installedVersion: "1",
                targetVersion: "2",
                policy: .required,
                estimatedBytes: 300,
                managedBy: .databaseRegistry
            ),
        ]
        return plan
    }

    func testDefaultsSelectRequiredDBsAndAllOptionalEnvs() {
        let viewModel = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        XCTAssertEqual(viewModel.selectedOptionalEnvironments, ["minimap2"])
        XCTAssertEqual(viewModel.selectedDatabases, ["deacon-panhuman"])
        XCTAssertFalse(viewModel.canDismissLater)

        let selection = viewModel.selection()
        XCTAssertTrue(selection.environments.contains("samtools"))
        XCTAssertEqual(selection.databases, ["deacon-panhuman"])
    }

    func testUncheckingAnOptionalEnvironmentReducesTheEstimate() {
        var sized = plan()
        // 800 of database bytes plus 1000 of environment budget across two environments.
        sized.estimatedDownloadBytes = 1800
        let viewModel = UpdateToolsSheetViewModel(plan: sized, reconciler: nil)
        let withOptional = viewModel.estimatedBytes
        viewModel.selectedOptionalEnvironments.remove("minimap2")
        XCTAssertLessThan(viewModel.estimatedBytes, withOptional)
        // The required environment's share stays charged no matter what is unchecked.
        XCTAssertGreaterThan(viewModel.estimatedBytes, 0)
    }

    func testRequiredWorkIsRunEvenWhenEverythingOptionalIsUnchecked() {
        let viewModel = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        viewModel.selectedOptionalEnvironments.removeAll()
        viewModel.selectedDatabases.removeAll()

        let selection = viewModel.selection()
        XCTAssertEqual(selection.environments, ["samtools"])
        XCTAssertEqual(selection.databases, ["deacon-panhuman"])
    }

    func testFreeSpaceWarningAppearsWhenHeadroomIsShort() {
        var sized = plan()
        sized.estimatedDownloadBytes = 1_000_000
        let tight = UpdateToolsSheetViewModel(
            plan: sized,
            reconciler: nil,
            freeSpaceProvider: { 1_000_000 }
        )
        XCTAssertNotNil(tight.freeSpaceWarning)
        XCTAssertTrue(tight.isBlockedByFreeSpace)
        XCTAssertFalse(tight.canStartUpdate)

        let roomy = UpdateToolsSheetViewModel(
            plan: sized,
            reconciler: nil,
            freeSpaceProvider: { 100_000_000 }
        )
        XCTAssertNil(roomy.freeSpaceWarning)
        XCTAssertTrue(roomy.canStartUpdate)
    }

    func testRunIsANoOpWithoutAReconciler() async {
        let viewModel = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        await viewModel.run()
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(viewModel.completed)
        XCTAssertTrue(viewModel.itemStatus.isEmpty)
    }

    func testCanDismissLaterWhenNothingIsRequired() {
        var optionalOnly = plan()
        optionalOnly.reinstallEnvironments = optionalOnly.reinstallEnvironments.filter { !$0.isRequired }
        optionalOnly.databaseUpdates = optionalOnly.databaseUpdates.filter { $0.policy != .required }
        let viewModel = UpdateToolsSheetViewModel(plan: optionalOnly, reconciler: nil)
        XCTAssertTrue(viewModel.canDismissLater)
    }

    func testEstimatedBytesFollowsSelection() {
        let viewModel = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        let base = viewModel.estimatedBytes
        viewModel.selectedDatabases.insert("kraken2-viral")
        XCTAssertEqual(viewModel.estimatedBytes, base + 500)
    }
}
