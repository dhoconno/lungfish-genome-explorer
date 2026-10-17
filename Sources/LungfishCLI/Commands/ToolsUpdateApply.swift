// ToolsUpdateApply.swift - tools update --apply with --only, events and SIGTERM
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow
import Synchronization

extension ToolsCommand {
    private struct Overrides {
        var manifest: ManagedToolLock?
        var services: ReconcilerServices?
    }

    private static let overrides = Mutex(Overrides())

    /// Test seams. A test hands the reconciler a manifest and stand-in services, because micromamba
    /// never runs in a unit test.
    static var manifestOverride: ManagedToolLock? {
        get { overrides.withLock { $0.manifest } }
        set { overrides.withLock { $0.manifest = newValue } }
    }

    static var servicesOverride: ReconcilerServices? {
        get { overrides.withLock { $0.services } }
        set { overrides.withLock { $0.services = newValue } }
    }
}

/// `tools update --apply` for the Update Tools sheet (Phase 2.10 lane A52, family L10).
///
/// `--only <id>` chooses the items of the plan to apply. An id is an environment to install or
/// reinstall, a database id, or a retired environment to remove, the sets the sheet's
/// `PlanSelection` holds. Required work in the plan always runs too, as in the sheet, because the
/// reconciler stamps the dependency set current when no required item that ran has failed, and a
/// run that left a required item out must not say the machine is current. With `--format json`
/// standard output holds only `CLIEvent` lines and the text goes to standard error. SIGTERM, the
/// app's Cancel, cancels the run. Items that finished stay updated, the run's record reads
/// cancelled, and the command exits 125.
extension ToolsCommand.UpdateSubcommand {
    /// What `--only` chose from a plan.
    struct Chosen: Equatable {
        var selection: PlanSelection
        /// The plan with the retired environments `--only` named, because the reconciler removes
        /// every retired environment of the plan it is given when removals are on.
        var plan: ReconciliationPlan
        /// The required items of the plan that `--only` did not name and that run anyway.
        var foldedIn: [String]
    }

    enum ChoiceError: Error, Equatable {
        case nothingNamed
        case notInPlan(ids: [String], held: [String])

        var message: String {
            switch self {
            case .nothingNamed:
                return "--only needs the id of an item in the plan"
            case let .notInPlan(ids, held):
                let known = held.isEmpty ? "The plan holds nothing to apply." : "The plan holds: \(held.joined(separator: ", "))."
                return "Not in the plan: \(ids.joined(separator: ", ")). \(known)"
            }
        }
    }

    static func choose(only ids: [String], from plan: ReconciliationPlan) throws -> Chosen {
        let wanted = Set(ids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { throw ChoiceError.nothingNamed }
        let environments = plan.installEnvironments + plan.reinstallEnvironments
        let held = Set(environments.map(\.environment))
            .union(plan.databaseUpdates.map(\.id))
            .union(plan.removeEnvironments)
        let unknown = wanted.subtracting(held)
        guard unknown.isEmpty else { throw ChoiceError.notInPlan(ids: unknown.sorted(), held: held.sorted()) }

        let requiredEnvironments = Set(environments.filter(\.isRequired).map(\.environment))
        let requiredDatabases = Set(plan.databaseUpdates.filter { $0.policy == .required }.map(\.id))
        let removals = plan.removeEnvironments.filter { wanted.contains($0) }
        var trimmed = plan
        trimmed.removeEnvironments = removals
        return Chosen(
            selection: PlanSelection(
                environments: wanted.intersection(environments.map(\.environment)).union(requiredEnvironments),
                databases: wanted.intersection(plan.databaseUpdates.map(\.id)).union(requiredDatabases),
                includeRemovals: !removals.isEmpty
            ),
            plan: trimmed,
            foldedIn: requiredEnvironments.union(requiredDatabases).subtracting(wanted).sorted()
        )
    }

    /// The overall fraction of a run from the reconciler's per-item progress. The reconciler reports
    /// each item from 0 to 1, so the command spreads the items over the run, and the bar only rises.
    private final class ItemProgress: Sendable {
        private let seen = Mutex<[String]>([])
        private let total: Int
        init(total: Int) { self.total = max(total, 1) }

        func overall(item: String, fraction: Double) -> Double {
            let index = seen.withLock { seen -> Int in
                if !seen.contains(item) { seen.append(item) }
                return seen.firstIndex(of: item) ?? 0
            }
            return min(0.99, (Double(index) + min(max(fraction, 0), 1)) / Double(total))
        }
    }

    /// Applies the plan, or the items `--only` chose, with each event line handed to `emit`.
    func applyChosen(
        plan: ReconciliationPlan,
        reconciler: DependencyReconciler,
        storageRoot root: URL,
        eventsOn: Bool,
        emit: @escaping (String) -> Void
    ) async throws {
        let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
        let say: @Sendable (String) -> Void = { printHumanLine($0, eventsOn: eventsOn) }

        var applyPlan = plan
        var selection: PlanSelection = requiredOnly ? .requiredOnly(from: plan) : .all(from: plan)
        if only.isEmpty {
            if !includeDatabases {
                selection.databases = Set(plan.databaseUpdates.filter { $0.policy == .required }.map(\.id))
            }
        } else {
            do {
                let chosen = try Self.choose(only: only, from: plan)
                selection = chosen.selection
                applyPlan = chosen.plan
                if !chosen.foldedIn.isEmpty {
                    FileHandle.standardError.write(Data(
                        "Note: required work in the plan always runs: \(chosen.foldedIn.joined(separator: ", "))\n".utf8
                    ))
                }
            } catch let error as ChoiceError {
                events.emitFailed(error.message)
                FileHandle.standardError.write(Data("Error: \(error.message)\n".utf8))
                throw CLIExitCode.inputError.exitCode
            }
        }

        if !json {
            say(Self.render(plan))
            say("")
        }
        events.emitStart("Updating tools to \(plan.targetDependencySet)...")

        let total = (applyPlan.bootstrapUpdate == nil ? 0 : 1)
            + (applyPlan.installEnvironments + applyPlan.reinstallEnvironments)
                .filter { selection.environments.contains($0.environment) }.count
            + applyPlan.databaseUpdates.filter { selection.databases.contains($0.id) }.count
            + (selection.includeRemovals ? applyPlan.removeEnvironments.count : 0)
        let itemProgress = ItemProgress(total: total)
        let printProgress = !json && !globalOptions.quiet && !eventsOn
        let before = ManagedToolLeaf.recordNames(storageRoot: root, folder: "dependencies")
        let startedAt = Date()
        let chosenPlan = applyPlan
        let chosenSelection = selection

        let outcome = await ManagedToolLeaf.cancellingOnSIGTERM { () async throws -> ReconciliationResult in
            try await reconciler.apply(chosenPlan, selection: chosenSelection) { item, fraction, detail in
                if eventsOn {
                    events.emitProgress(itemProgress.overall(item: item, fraction: fraction), message: "\(item): \(detail)")
                } else if printProgress {
                    print("[\(Int((fraction * 100).rounded()))%] \(item): \(detail)")
                }
            }
        }
        let wroteRecords = ManagedToolLeaf.recordNames(storageRoot: root, folder: "dependencies").subtracting(before).sorted()
        let recordURL = wroteRecords.last.map {
            ManagedToolLeaf.recordDirectory(storageRoot: root, folder: "dependencies").appendingPathComponent($0)
        }

        var failure: (any Error)?
        var result: ReconciliationResult?
        switch outcome {
        case .success(let value): result = value
        case .failure(let error): failure = error
        }

        if ManagedToolLeaf.endedOnCancel(failure) {
            // The reconciler writes its record as the run ends, items that a SIGTERM stopped
            // included, and the command rewrites it as cancelled. A cancel that landed before the
            // reconciler wrote one gets a record of its own.
            var recorded = false
            if let recordURL {
                recorded = ManagedToolLeaf.markCancelled(sidecar: recordURL, reason: "Cancelled")
            }
            if !recorded {
                ManagedToolLeaf.writeRecord(
                    ManagedToolLeaf.Record(
                        workflowName: "dependency-reconcile",
                        folder: "dependencies",
                        label: plan.targetDependencySet,
                        argv: ["lungfish-cli", "tools", "update", "--apply", "--yes"] + only.flatMap { ["--only", $0] },
                        explicit: ["dependencySet": .string(plan.targetDependencySet)],
                        pluginPack: nil,
                        steps: [],
                        status: .cancelled,
                        failure: "Cancelled",
                        startedAt: startedAt,
                        endedAt: Date()
                    ),
                    storageRoot: root
                )
            }
            let message = "Update cancelled. Items that finished stay updated and the rest were not started."
            events.emitFailed(message)
            say(message)
            throw CLIExitCode.cancelled.exitCode
        }
        if let failure {
            events.emitFailed(CLIFailureWords.describe(failure))
            throw failure
        }
        guard let result else { return }

        if json {
            print(try Self.encodeApplyJSON(plan: plan, result: result))
        } else {
            say(Self.renderResult(result))
        }

        // The receipt pseudo-item names the bookkeeping step, not an installable tool: a
        // machine whose tools all installed but whose receipt could not be written is
        // usable, so it warns rather than failing the command.
        let realFailures = result.failed.filter { $0.key != DependencyReconciler.receiptItemID }
        if let receiptFailure = result.failed[DependencyReconciler.receiptItemID] {
            FileHandle.standardError.write(
                Data("Warning: could not record the dependency receipt: \(receiptFailure)\n".utf8)
            )
            events.emitLog(.warning, "Could not record the dependency receipt: \(receiptFailure)")
        }
        if !realFailures.isEmpty {
            let detail = realFailures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
            events.emitFailed("\(result.succeeded.count) updated, \(realFailures.count) failed", detail: detail)
            throw CLIExitCode.failure.exitCode
        }
        events.emitComplete(
            outputs: [(recordURL ?? root).path],
            message: "Updated \(result.succeeded.count) item(s) to \(plan.targetDependencySet)"
        )
    }
}
