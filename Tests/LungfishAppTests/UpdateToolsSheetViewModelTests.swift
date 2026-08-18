// UpdateToolsSheetViewModelTests.swift - Selection, sizing, and gating for the Update Tools sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// Counts calls from a `@Sendable` closure without tripping strict concurrency.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

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

        let selection = viewModel.selection()
        XCTAssertTrue(selection.environments.contains("samtools"))
        XCTAssertEqual(selection.databases, ["deacon-panhuman"])
    }

    /// Only the Welcome-hosted launch path refuses deferral. Everywhere else the user keeps
    /// "Later" even with required work outstanding, because quitting under a restored project
    /// window would cost more than deferring.
    func testDeferralIsRefusedOnlyWhenTheHostDisallowsIt() {
        let welcomeHosted = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        welcomeHosted.allowsDeferral = false
        XCTAssertFalse(welcomeHosted.canDismissLater)

        let elsewhere = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        XCTAssertTrue(elsewhere.allowsDeferral)
        XCTAssertTrue(elsewhere.canDismissLater)

        // Even a host that disallows deferral offers "Later" when nothing is required.
        var optionalOnly = plan()
        optionalOnly.reinstallEnvironments = optionalOnly.reinstallEnvironments.filter { !$0.isRequired }
        optionalOnly.databaseUpdates = optionalOnly.databaseUpdates.filter { $0.policy != .required }
        let nothingRequired = UpdateToolsSheetViewModel(plan: optionalOnly, reconciler: nil)
        nothingRequired.allowsDeferral = false
        XCTAssertTrue(nothingRequired.canDismissLater)
    }

    func testFreeSpaceIsSampledOnceAtInitRatherThanPerAccess() {
        let probeCount = Counter()
        let viewModel = UpdateToolsSheetViewModel(
            plan: plan(),
            reconciler: nil,
            freeSpaceProvider: {
                probeCount.increment()
                return 5_000_000_000
            }
        )
        XCTAssertEqual(probeCount.value, 1)

        // Repeated reads of the derived properties must not touch the volume again.
        for _ in 0..<10 {
            _ = viewModel.freeSpaceWarning
            _ = viewModel.isBlockedByFreeSpace
            _ = viewModel.canStartUpdate
        }
        XCTAssertEqual(probeCount.value, 1)

        viewModel.refreshFreeSpace()
        XCTAssertEqual(probeCount.value, 2)
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

    // MARK: - Deferral suppression

    private func optionalOnlyPlan() -> ReconciliationPlan {
        var optionalOnly = plan()
        optionalOnly.reinstallEnvironments = optionalOnly.reinstallEnvironments.filter { !$0.isRequired }
        optionalOnly.databaseUpdates = optionalOnly.databaseUpdates.filter { $0.policy != .required }
        return optionalOnly
    }

    /// An all-optional plan the user declined must not reappear on every launch, but the same
    /// deferral must not silence a plan that has required work or a different manifest.
    func testDeferredOptionalOnlyPlanIsSuppressedUntilTheManifestChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "update-tools-deferral-\(UUID().uuidString)"))
        defer { defaults.removeVolatileDomain(forName: UserDefaults.registrationDomain) }

        let manifest = ManagedToolLock.bundled
        let optionalOnly = optionalOnlyPlan()

        // Nothing deferred yet: the sheet should be presented.
        XCTAssertFalse(
            AppDelegate.shouldSuppressDeferredPlan(optionalOnly, manifest: manifest, defaults: defaults)
        )

        defaults.set(manifest.manifestHash, forKey: AppDelegate.deferredDependencyManifestHashKey)
        XCTAssertTrue(
            AppDelegate.shouldSuppressDeferredPlan(optionalOnly, manifest: manifest, defaults: defaults)
        )

        // Required work overrides the deferral: the user cannot defer their way past it.
        XCTAssertFalse(
            AppDelegate.shouldSuppressDeferredPlan(plan(), manifest: manifest, defaults: defaults)
        )

        // A deferral recorded against a different manifest does not silence this one.
        defaults.set("some-other-manifest-hash", forKey: AppDelegate.deferredDependencyManifestHashKey)
        XCTAssertFalse(
            AppDelegate.shouldSuppressDeferredPlan(optionalOnly, manifest: manifest, defaults: defaults)
        )
    }

    /// The shared busy flag is what stops Welcome's required-setup installer and the Plugin
    /// Manager from driving conda into the same environments while a run is in flight.
    func testReconciliationActivityFlagNestsAndClears() {
        let center = NotificationCenter()
        let activity = DependencyReconciliationActivity(notificationCenter: center)
        var startCount = 0
        let token = center.addObserver(
            forName: .lungfishDependencyReconciliationDidStart,
            object: nil,
            queue: nil
        ) { _ in startCount += 1 }
        defer { center.removeObserver(token) }

        XCTAssertFalse(activity.isApplying)

        activity.begin()
        XCTAssertTrue(activity.isApplying)
        XCTAssertEqual(startCount, 1)

        // A nested begin must not re-announce, and its end must not clear early.
        activity.begin()
        XCTAssertEqual(startCount, 1)
        activity.end()
        XCTAssertTrue(activity.isApplying)

        activity.end()
        XCTAssertFalse(activity.isApplying)

        // Unbalanced ends are harmless.
        activity.end()
        XCTAssertFalse(activity.isApplying)
    }

    func testEstimatedBytesFollowsSelection() {
        let viewModel = UpdateToolsSheetViewModel(plan: plan(), reconciler: nil)
        let base = viewModel.estimatedBytes
        viewModel.selectedDatabases.insert("kraken2-viral")
        XCTAssertEqual(viewModel.estimatedBytes, base + 500)
    }
}
