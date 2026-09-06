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
    /// UserDefaults key holding the manifest hash the user last said "Later" to.
    static let deferredDependencyManifestHashKey = "com.lungfish.deferredDependencyManifestHash"

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
                DebugDependencySharing.recordLaunchPlan(plan, storageRoot: root)
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
                    // A brand-new machine belongs to Welcome's required-setup flow, which is
                    // already the front door for a first install. Two installers offering the
                    // same work at the same launch is worse than one.
                    if Self.isFreshInstallOwnedByWelcome(plan, hasReceipt: receipt != nil) {
                        debugLog(
                            "Dependency reconciliation stood down: fresh install of \(plan.installEnvironments.count) tool(s) is Welcome's required-setup flow to run"
                        )
                        return
                    }
                    // An all-optional plan the user already declined must not reappear at every
                    // launch. The deferral is keyed to the manifest hash, so a new manifest (or
                    // any plan that turns out to have required work) asks again.
                    if Self.shouldSuppressDeferredPlan(plan, manifest: manifest, defaults: defaults) {
                        debugLog("Dependency reconciliation deferred by the user for this manifest")
                        return
                    }
                    self?.presentUpdateToolsSheet(plan: plan, reconciler: reconciler, storageRoot: root)
                }
            } catch {
                debugLog("Dependency reconciliation failed to plan: \(error)")
            }
        }
    }

    /// True when this plan is a first install and therefore belongs to Welcome, not to us.
    ///
    /// A machine with no tools at all produces a plan that is nothing but `.missing` installs.
    /// Presenting the Update Tools sheet for it puts two installers on screen for the same work:
    /// Welcome's required-setup flow is already the front door for a fresh machine, and it is
    /// the one that explains what is being installed and why. Reconciliation exists to carry a
    /// machine from one dependency set to the next, so it stands down until there is something
    /// to carry.
    ///
    /// Any reinstall, removal, or bootstrap change means the machine has a tool set already and
    /// this really is an update, so the sheet is presented. So does an existing receipt: that is
    /// the record of a previous install, which makes "fresh machine" false however empty the
    /// disk looks now.
    static func isFreshInstallOwnedByWelcome(
        _ plan: ReconciliationPlan,
        hasReceipt: Bool
    ) -> Bool {
        guard !hasReceipt else { return false }
        guard plan.reinstallEnvironments.isEmpty,
              plan.removeEnvironments.isEmpty,
              plan.bootstrapUpdate == nil,
              plan.databaseUpdates.isEmpty else { return false }
        // Nothing at all to do is not a fresh install; that case is stamped, not presented.
        guard !plan.installEnvironments.isEmpty else { return false }
        return plan.installEnvironments.allSatisfy { $0.reason == .missing }
    }

    /// True when this exact manifest was deferred and the outstanding work is all optional.
    static func shouldSuppressDeferredPlan(
        _ plan: ReconciliationPlan,
        manifest: ManagedToolLock,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !plan.hasRequiredWork else { return false }
        return defaults.string(forKey: deferredDependencyManifestHashKey) == manifest.manifestHash
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

        // "Quit" is only honest on the Welcome window: that is the one host where the app has
        // nothing else on screen to fall back to. If the user has restored project windows,
        // terminating under them would destroy more than it protects, so those hosts get
        // "Later" and rely on Welcome's required-setup gate to block new analyses.
        let isWelcomeHost = window.isWelcomeWindow
        let allowsDeferral = !(isWelcomeHost && plan.hasRequiredWork)

        UpdateToolsSheetController.present(
            plan: plan,
            reconciler: reconciler,
            storageRoot: storageRoot,
            on: window,
            allowsDeferral: allowsDeferral,
            onDismissWithoutRunning: {
                if !allowsDeferral {
                    NSApp.terminate(nil)
                } else {
                    Self.recordDeferral()
                }
            },
            onFinished: { receipt in
                Self.stampLaunchDefaultsIfCurrent(receipt: receipt)
            }
        )
    }

    /// Remembers that the user declined this manifest's optional work, so the next launch does
    /// not ask again until the manifest changes.
    static func recordDeferral() {
        UserDefaults.standard.set(
            ManagedToolLock.bundled.manifestHash,
            forKey: deferredDependencyManifestHashKey
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
        // A successful run supersedes any earlier "Later": the work is done, so the deferral
        // must not keep suppressing a future plan built from the same manifest.
        defaults.removeObject(forKey: deferredDependencyManifestHashKey)
    }
}
