// UpdateToolsSheetViewModel.swift - Selection, sizing, and run state for the Update Tools sheet
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "UpdateToolsSheet")

/// Where one item of the plan stands while the sheet is running it.
enum ItemStatus: Equatable {
    case pending
    case running(String)
    case done
    case failed(String)
    /// The reconciler declined to do this item. Removals are the case in practice: they are
    /// held back when a required install failed, so the machine is not stripped of a working
    /// tool before its replacement is in place.
    case skipped(String)
}

/// Drives ``UpdateToolsSheet``: which pieces of the plan the user has chosen, how much that
/// selection will download, and what happened once the reconciler ran it.
///
/// Required work is not representable as "unselected": ``selection()`` always folds the
/// required environments and `.required` databases back in, so a user who unchecks everything
/// optional still gets a run that satisfies the launch gate.
@MainActor
@Observable
final class UpdateToolsSheetViewModel {
    /// The plan being presented. Fixed for the lifetime of the sheet.
    private(set) var plan: ReconciliationPlan

    /// Optional (non-required) environments the user has chosen. Defaults to all of them.
    var selectedOptionalEnvironments: Set<String>

    /// Databases the user has chosen. Defaults to the `.required` ones only, because advisory
    /// database downloads are large and the user should opt into them deliberately.
    var selectedDatabases: Set<String>

    /// Whether retired environments get removed as part of this run.
    var includeRemovals: Bool = true

    private(set) var isRunning = false
    private(set) var itemStatus: [String: ItemStatus] = [:]
    private(set) var completed = false
    private(set) var failureSummary: String?

    /// The receipt written by the run, once one has finished. The presenter uses it to decide
    /// whether the launch-time defaults may be stamped.
    private(set) var resultReceipt: DependencyReceipt?

    /// Last sampled free space on the storage volume, or nil when it could not be read.
    /// Sampled at init and refreshed via ``refreshFreeSpace()`` rather than read per access.
    private(set) var freeSpaceBytes: Int64?

    private let reconciler: DependencyReconciler?
    private let freeSpaceProvider: @Sendable () -> Int64?

    /// `nil` reconciler is the unit-test seam: everything but ``run()`` behaves identically.
    init(
        plan: ReconciliationPlan,
        reconciler: DependencyReconciler?,
        freeSpaceProvider: @escaping @Sendable () -> Int64? = { nil }
    ) {
        self.plan = plan
        self.reconciler = reconciler
        self.freeSpaceProvider = freeSpaceProvider
        self.selectedOptionalEnvironments = Set(
            Self.optionalEnvironments(in: plan).map(\.environment)
        )
        self.selectedDatabases = Set(
            plan.databaseUpdates.filter { $0.policy == .required }.map(\.id)
        )
        self.freeSpaceBytes = freeSpaceProvider()
    }

    // MARK: - Plan partitioning

    /// Environment changes (installs and reinstalls) the user cannot decline.
    var requiredEnvironments: [ReconciliationPlan.EnvironmentChange] {
        Self.allEnvironments(in: plan).filter(\.isRequired)
    }

    /// Environment changes the user may skip for now.
    var optionalEnvironments: [ReconciliationPlan.EnvironmentChange] {
        Self.optionalEnvironments(in: plan)
    }

    var requiredDatabases: [ReconciliationPlan.DatabaseChange] {
        plan.databaseUpdates.filter { $0.policy == .required }
    }

    var advisoryDatabases: [ReconciliationPlan.DatabaseChange] {
        plan.databaseUpdates.filter { $0.policy != .required }
    }

    private static func allEnvironments(in plan: ReconciliationPlan) -> [ReconciliationPlan.EnvironmentChange] {
        plan.installEnvironments + plan.reinstallEnvironments
    }

    private static func optionalEnvironments(in plan: ReconciliationPlan) -> [ReconciliationPlan.EnvironmentChange] {
        allEnvironments(in: plan).filter { !$0.isRequired }
    }

    // MARK: - Gating and sizing

    /// Whether this host can let the user walk away from required work.
    ///
    /// Only the Welcome-hosted launch path sets this false: that is the one context where the
    /// app genuinely has nowhere to go without its required tools, so the button reads "Quit"
    /// and really terminates. Every other host (Plugin Manager, a restored project window)
    /// leaves it true and offers "Later", because terminating out from under a user's open
    /// windows would be worse than deferring, and new analyses stay gated by the Welcome
    /// required-setup check anyway.
    var allowsDeferral: Bool = true

    /// "Later" is offered when the host permits deferral, or when nothing is required at all.
    var canDismissLater: Bool { allowsDeferral || !plan.hasRequiredWork }

    /// Download size of the current selection.
    ///
    /// Databases contribute their own estimates. The planner does not publish a per-environment
    /// figure, so the aggregate environment budget is divided evenly across the environments in
    /// the plan and charged only for the ones actually selected. That keeps unchecking an
    /// optional tool visibly reducing the total, which is what the free-space check needs in
    /// order for "uncheck something" to be actionable advice.
    var estimatedBytes: Int64 {
        let databaseTotal = plan.databaseUpdates
            .filter { selectedDatabases.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.estimatedBytes }
        let allDatabaseBytes = plan.databaseUpdates.reduce(Int64(0)) { $0 + $1.estimatedBytes }
        // What the plan estimated for everything that is not a database.
        let environmentBudget = max(0, plan.estimatedDownloadBytes - allDatabaseBytes)
        let allEnvironments = Self.allEnvironments(in: plan)
        guard !allEnvironments.isEmpty else { return databaseTotal + environmentBudget }

        let perEnvironment = environmentBudget / Int64(allEnvironments.count)
        let selectedCount = requiredEnvironments.count + selectedOptionalEnvironments.count
        // The bootstrap is not optional and is not one of the environments, so whatever the
        // even split leaves over rides along with it rather than disappearing.
        let remainder = environmentBudget - perEnvironment * Int64(allEnvironments.count)
        return databaseTotal + perEnvironment * Int64(selectedCount) + remainder
    }

    /// Set when the storage volume does not have comfortable headroom for the selection.
    ///
    /// The 1.1 factor covers the unpacked-versus-downloaded gap and conda's staging copies.
    /// Derived from ``freeSpaceBytes``, which is a stored sample rather than a live read: this
    /// is evaluated on every SwiftUI body pass, and hitting the volume synchronously from a
    /// computed property would put filesystem I/O on the main thread each time.
    var freeSpaceWarning: String? {
        guard estimatedBytes > 0, let free = freeSpaceBytes else { return nil }
        let needed = Int64(Double(estimatedBytes) * 1.1)
        guard free < needed else { return nil }
        return "This update needs about \(Self.format(needed)) of free space but the storage volume has about \(Self.format(free)). Uncheck optional items or free up space."
    }

    /// Re-samples the volume. Called when the sheet appears and after a run, since a run both
    /// consumes space and may free it by removing retired environments.
    func refreshFreeSpace() {
        freeSpaceBytes = freeSpaceProvider()
    }

    /// True when the free-space check says there is not enough room to start.
    var isBlockedByFreeSpace: Bool { freeSpaceWarning != nil }

    var canStartUpdate: Bool { !isRunning && !completed && !isBlockedByFreeSpace }

    private static func format(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Selection

    /// The selection handed to the reconciler. Required work is always included regardless of
    /// what the checkboxes say.
    func selection() -> PlanSelection {
        var environments = Set(requiredEnvironments.map(\.environment))
        environments.formUnion(selectedOptionalEnvironments)
        var databases = Set(requiredDatabases.map(\.id))
        databases.formUnion(selectedDatabases)
        return PlanSelection(
            environments: environments,
            databases: databases,
            includeRemovals: includeRemovals
        )
    }

    // MARK: - Running

    /// Applies the selection. A no-op when no reconciler was supplied (unit tests).
    func run() async {
        guard let reconciler, !isRunning, !completed else { return }
        isRunning = true
        failureSummary = nil
        // Tell the rest of the app that conda is busy, so Welcome's required-setup install and
        // the Plugin Manager's install/reinstall buttons stand down rather than racing us into
        // the same environments.
        DependencyReconciliationActivity.shared.begin()
        let currentSelection = selection()
        for id in currentSelection.environments.union(currentSelection.databases) {
            itemStatus[id] = .pending
        }
        if currentSelection.includeRemovals {
            for name in plan.removeEnvironments {
                itemStatus[Self.removalStatusKey(name)] = .pending
            }
        }

        // The progress closure is `@Sendable` and called from the reconciler's actor context,
        // so it hops back to the main actor before touching observable state.
        let progress: @Sendable (String, Double, String) -> Void = { [weak self] id, fraction, detail in
            Task { @MainActor [weak self] in
                self?.applyProgress(id: id, fraction: fraction, detail: detail)
            }
        }

        do {
            let result = try await reconciler.apply(
                plan,
                selection: currentSelection,
                progress: progress
            )
            finish(with: result)
        } catch {
            logger.error("Update Tools run failed: \(error.localizedDescription, privacy: .public)")
            failureSummary = error.localizedDescription
            isRunning = false
            completed = true
        }
        DependencyReconciliationActivity.shared.end()
        refreshFreeSpace()
    }

    /// Namespaces a removal's status so it cannot collide with an install or reinstall of an
    /// environment that happens to carry the same name.
    static func removalStatusKey(_ environment: String) -> String {
        "remove:\(environment)"
    }

    private func applyProgress(id: String, fraction: Double, detail: String) {
        // A finished item must not be dragged back into `.running` by a late progress callback.
        switch itemStatus[id] {
        case .done, .failed:
            return
        default:
            break
        }
        if fraction >= 1.0 {
            itemStatus[id] = .done
        } else {
            itemStatus[id] = .running(detail)
        }
    }

    private func finish(with result: ReconciliationResult) {
        for id in result.succeeded {
            itemStatus[id] = .done
        }
        for (id, message) in result.failed {
            itemStatus[id] = .failed(message)
        }

        // The reconciler reports removals under the bare environment name and holds all of
        // them back when a required item failed, so anything still unresolved here was skipped
        // rather than attempted. Saying so beats leaving the row blank.
        if includeRemovals {
            let succeededNames = Set(result.succeeded)
            for name in plan.removeEnvironments {
                let key = Self.removalStatusKey(name)
                if succeededNames.contains(name) {
                    itemStatus[key] = .done
                } else if let message = result.failed[name] {
                    itemStatus[key] = .failed(message)
                } else {
                    itemStatus[key] = .skipped("Skipped (required item failed)")
                }
            }
        }
        resultReceipt = result.receipt
        if result.failed.isEmpty {
            failureSummary = nil
        } else {
            let names = result.failed.keys.sorted().joined(separator: ", ")
            failureSummary = result.failed.count == 1
                ? "1 item did not finish: \(names)"
                : "\(result.failed.count) items did not finish: \(names)"
        }
        isRunning = false
        completed = true
    }
}
