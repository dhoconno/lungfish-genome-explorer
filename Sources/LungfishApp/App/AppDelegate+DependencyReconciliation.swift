// AppDelegate+DependencyReconciliation.swift - Launch-time tool reconciliation
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishWorkflow

/// Builds the reconciler the launch trigger and the Plugin Manager both use, so the two entry
/// points cannot drift apart in how they wire storage, manifest, and progress reporting.
@MainActor
enum DependencyReconciliationFactory {
    static func makeReconciler(storageRoot: URL) -> DependencyReconciler {
        DependencyReconciler(
            manifest: ManagedToolLock.bundled,
            storageRoot: storageRoot,
            services: .live(condaManager: .shared, storageRoot: storageRoot),
            appVersion: LungfishAppVersion.short,
            operationCenter: OperationCenterDependencySink()
        )
    }

    static var storageRoot: URL {
        ManagedStorageConfigStore.shared.currentLocation().rootURL
    }
}

extension AppDelegate {

    /// UserDefaults key holding the dependency set the app last confirmed this machine was on.
    static let lastLaunchedDependencySetKey = "com.lungfish.lastLaunchedDependencySet"
    /// UserDefaults key holding the app version that last confirmed it.
    static let lastLaunchedAppVersionKey = "com.lungfish.lastLaunchedAppVersion"

    /// Checks whether this machine matches the bundled dependency manifest and, if not,
    /// presents the Update Tools sheet.
    ///
    /// The fast path is three string comparisons against `UserDefaults`, so a launch where
    /// nothing changed does no filesystem or conda work at all. Only when a stamp is missing
    /// or stale does it pay for a full plan.
    func scheduleDependencyReconciliation() {
        guard !AppDebugLaunchConfiguration.current.bypassRequiredSetup else {
            debugLog("Dependency reconciliation skipped: required-setup bypass is on")
            return
        }

        let manifest = ManagedToolLock.bundled
        let defaults = UserDefaults.standard
        let root = DependencyReconciliationFactory.storageRoot
        let receipt = try? DependencyReceiptStore(storageRoot: root).load()
        let unchanged = defaults.string(forKey: Self.lastLaunchedDependencySetKey) == manifest.resolvedDependencySet
            && defaults.string(forKey: Self.lastLaunchedAppVersionKey) == LungfishAppVersion.short
            && receipt?.manifestHash == manifest.manifestHash
        guard !unchanged else {
            debugLog("Dependency reconciliation skipped: already on \(manifest.resolvedDependencySet)")
            return
        }

        let reconciler = DependencyReconciliationFactory.makeReconciler(storageRoot: root)
        Task { [weak self] in
            do {
                let plan = try await reconciler.currentPlan()
                if plan.isEmpty {
                    // Nothing to do, but the receipt has not recorded this set yet. Stamp both
                    // the receipt and the defaults so the next launch takes the fast path.
                    try await reconciler.stampCurrentSet()
                    await MainActor.run {
                        Self.stampLaunchDefaults(dependencySet: manifest.resolvedDependencySet)
                    }
                    return
                }
                await MainActor.run {
                    self?.presentUpdateToolsSheet(plan: plan, reconciler: reconciler, storageRoot: root)
                }
            } catch {
                debugLog("Dependency reconciliation failed to plan: \(error)")
            }
        }
    }

    /// Presents the sheet on whatever window is on screen, retrying shortly if the app has not
    /// put one up yet (the Welcome window is created a beat after `applicationDidFinishLaunching`).
    func presentUpdateToolsSheet(
        plan: ReconciliationPlan,
        reconciler: DependencyReconciler,
        storageRoot: URL,
        remainingAttempts: Int = 20
    ) {
        guard let window = UpdateToolsSheetController.hostWindow() else {
            guard remainingAttempts > 0 else {
                debugLog("Dependency reconciliation: no window to present the Update Tools sheet on")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated {
                    self?.presentUpdateToolsSheet(
                        plan: plan,
                        reconciler: reconciler,
                        storageRoot: storageRoot,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
            }
            return
        }

        let canDefer = !plan.hasRequiredWork
        UpdateToolsSheetController.present(
            plan: plan,
            reconciler: reconciler,
            storageRoot: storageRoot,
            on: window,
            onDismissWithoutRunning: {
                // With required work outstanding the sheet's button reads "Quit", because the
                // app cannot run its pipelines against a half-provisioned tool set.
                if !canDefer {
                    NSApp.terminate(nil)
                }
            },
            onFinished: { receipt in
                Self.stampLaunchDefaultsIfCurrent(receipt: receipt)
            }
        )
    }

    /// Records that this machine is on the manifest's dependency set, but only when the
    /// receipt actually says so: a run where a required item failed must keep re-planning.
    static func stampLaunchDefaultsIfCurrent(receipt: DependencyReceipt?) {
        let manifest = ManagedToolLock.bundled
        guard receipt?.dependencySet == manifest.resolvedDependencySet else { return }
        stampLaunchDefaults(dependencySet: manifest.resolvedDependencySet)
    }

    static func stampLaunchDefaults(dependencySet: String) {
        let defaults = UserDefaults.standard
        defaults.set(dependencySet, forKey: lastLaunchedDependencySetKey)
        defaults.set(LungfishAppVersion.short, forKey: lastLaunchedAppVersionKey)
    }
}
