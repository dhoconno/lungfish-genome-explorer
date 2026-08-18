// ToolsCommand.swift - CLI surface over the dependency reconciler
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// Inspect and update the managed third-party tools pinned by the dependency manifest.
///
/// This is the headless twin of the app's Update Tools flow: it reads the same manifest,
/// produces the same `ReconciliationPlan`, and applies it through the same
/// `DependencyReconciler`. The CLI never presents UI, so the reconciler is constructed
/// with a nil operation sink and progress is printed to stdout instead.
///
/// ## Examples
///
/// ```
/// lungfish tools update --plan
/// lungfish tools update --plan --json
/// lungfish tools update --apply --yes
/// lungfish tools update --apply --yes --required-only
/// ```
struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "Inspect and update managed third-party tools",
        discussion: """
        Compares this machine against the dependency manifest bundled with this build and
        reports (or performs) the installs, reinstalls, removals, and database updates
        needed to bring it in line.
        """,
        subcommands: [UpdateSubcommand.self],
        defaultSubcommand: UpdateSubcommand.self
    )

}

// MARK: - tools update

extension ToolsCommand {

    struct UpdateSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Plan or apply updates to the pinned dependency set",
            discussion: """
            With --plan (the default), prints the pending work without changing anything.
            With --apply --yes, performs the work.

            Exit codes:
              0   nothing to do, or the update was applied
              10  work is pending (--plan only)
              2   usage error, such as --apply without --yes
              1   an item failed to install

            A failure to record the dependency receipt warns on stderr but still exits 0:
            the tools installed, they just were not written down.
            """
        )

        @Flag(name: .customLong("plan"), help: "Print the plan and exit 10 if work is pending")
        var planOnly: Bool = false

        @Flag(name: .customLong("apply"), help: "Apply the plan (requires --yes)")
        var apply: Bool = false

        @Flag(name: .customLong("yes"), help: "Confirm non-interactive application")
        var yes: Bool = false

        @Flag(name: .customLong("json"), help: "Machine-readable JSON output")
        var json: Bool = false

        @Flag(name: .customLong("required-only"), help: "Only work the user cannot defer")
        var requiredOnly: Bool = false

        @Flag(name: .customLong("include-databases"), help: "Include advisory database updates")
        var includeDatabases: Bool = false

        @Option(name: .customLong("storage-root"), help: "Managed storage root (default: the configured location)")
        var storageRoot: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            // Silently preferring one over the other would make `--plan --apply` look like a
            // dry run to a script that meant to apply, or vice versa.
            guard !(planOnly && apply) else {
                FileHandle.standardError.write(
                    Data("Error: --plan and --apply are mutually exclusive\n".utf8)
                )
                throw CLIExitCode.usage.exitCode
            }

            let root = try resolvedStorageRoot()
            let reconciler = DependencyReconciler(
                manifest: ManagedToolLock.bundled,
                storageRoot: root,
                services: .live(condaManager: .shared, storageRoot: root),
                appVersion: LungfishAppVersion.short,
                operationCenter: nil
            )

            let plan = try await reconciler.currentPlan()

            guard apply else {
                if json {
                    print(try Self.encodeJSON(plan))
                } else {
                    print(Self.render(plan))
                }
                // Pending work is not a failure: the command did its job and wrote the plan.
                // `updatesPending` is what scripts branch on to schedule an update window.
                throw plan.isEmpty ? CLIExitCode.success.exitCode : CLIExitCode.updatesPending.exitCode
            }

            // Checked before anything is printed so a JSON consumer never sees a partial
            // document ahead of the refusal.
            guard yes else {
                FileHandle.standardError.write(Data("Error: tools update --apply requires --yes\n".utf8))
                throw CLIExitCode.usage.exitCode
            }

            if !json {
                print(Self.render(plan))
                print("")
            }

            var selection: PlanSelection = requiredOnly ? .requiredOnly(from: plan) : .all(from: plan)
            if !includeDatabases {
                selection.databases = Set(
                    plan.databaseUpdates.filter { $0.policy == .required }.map(\.id)
                )
            }

            let quiet = globalOptions.quiet
            let printProgress = !json && !quiet
            let result = try await reconciler.apply(plan, selection: selection) { item, fraction, detail in
                guard printProgress else { return }
                let percent = Int((fraction * 100).rounded())
                print("[\(percent)%] \(item): \(detail)")
            }

            if json {
                print(try Self.encodeApplyJSON(plan: plan, result: result))
            } else {
                print(Self.renderResult(result))
            }

            // The receipt pseudo-item names the bookkeeping step, not an installable tool: a
            // machine whose tools all installed but whose receipt could not be written is
            // usable, so it warns rather than failing the command.
            let realFailures = result.failed.filter { $0.key != DependencyReconciler.receiptItemID }
            if let receiptFailure = result.failed[DependencyReconciler.receiptItemID] {
                FileHandle.standardError.write(
                    Data("Warning: could not record the dependency receipt: \(receiptFailure)\n".utf8)
                )
            }
            if !realFailures.isEmpty {
                throw CLIExitCode.failure.exitCode
            }
        }

        /// `--storage-root`, else the configured managed storage location (which itself honors
        /// `LUNGFISH_STORAGE_ROOT`).
        ///
        /// `--storage-root` is applied by exporting `LUNGFISH_STORAGE_ROOT` into this process
        /// before anything reads it, rather than only being handed to the reconciler. The
        /// reconciler's services reach `CondaManager.shared`, whose root prefix resolves from
        /// the same store: passing the flag to one and not the other would produce a plan that
        /// compared one machine's receipt against another machine's environments.
        private func resolvedStorageRoot() throws -> URL {
            guard let storageRoot, !storageRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ManagedStorageConfigStore().currentLocation().rootURL
            }

            let requested = URL(fileURLWithPath: storageRoot, isDirectory: true).standardizedFileURL
            setenv("LUNGFISH_STORAGE_ROOT", requested.path, 1)
            let resolved = ManagedStorageConfigStore().currentLocation().rootURL
            guard resolved == requested else {
                // `currentLocation` silently falls back when the override fails validation
                // (missing directory, not writable). Reporting that is better than planning
                // against a root the user did not ask for.
                FileHandle.standardError.write(
                    Data("Error: storage root is unavailable: \(requested.path)\n".utf8)
                )
                throw CLIExitCode.inputError.exitCode
            }
            return resolved
        }

        // MARK: - Rendering

        static func render(_ plan: ReconciliationPlan) -> String {
            var lines = ["Target dependency set: \(plan.targetDependencySet)"]
            guard !plan.isEmpty else {
                lines.append("Nothing to do.")
                return lines.joined(separator: "\n")
            }

            for change in plan.installEnvironments {
                lines.append(
                    "install   \(change.environment)  \(change.targetSpec)\(change.isRequired ? "  (required)" : "")"
                )
            }
            for change in plan.reinstallEnvironments {
                lines.append(
                    "reinstall \(change.environment)  \(change.currentSpec ?? "unknown") -> \(change.targetSpec)  [\(change.reason.rawValue)]"
                )
            }
            for environment in plan.removeEnvironments {
                lines.append("remove    \(environment)  (retired)")
            }
            for database in plan.databaseUpdates {
                lines.append(
                    "database  \(database.id)  \(database.installedVersion ?? "unknown") -> \(database.targetVersion)  [\(database.policy.rawValue)]"
                )
            }
            for pipeline in plan.pipelinePrefetch {
                lines.append(
                    "pipeline  \(pipeline.id)  \(pipeline.currentRevision ?? "unknown") -> \(pipeline.targetRevision)"
                )
            }
            if let bootstrap = plan.bootstrapUpdate {
                lines.append(
                    "bootstrap micromamba \(bootstrap.currentVersion ?? "unknown") -> \(bootstrap.targetVersion)"
                )
            }
            lines.append(
                "Estimated download: "
                    + ByteCountFormatter.string(fromByteCount: plan.estimatedDownloadBytes, countStyle: .file)
            )
            return lines.joined(separator: "\n")
        }

        static func renderResult(_ result: ReconciliationResult) -> String {
            var lines: [String] = []
            if result.succeeded.isEmpty {
                lines.append("Completed: nothing applied.")
            } else {
                lines.append("Completed: \(result.succeeded.sorted().joined(separator: ", "))")
            }
            for (item, message) in result.failed.sorted(by: { $0.key < $1.key }) {
                lines.append("failed    \(item): \(message)")
            }
            return lines.joined(separator: "\n")
        }

        // MARK: - JSON

        static func encodeJSON(_ plan: ReconciliationPlan) throws -> String {
            String(decoding: try jsonEncoder.encode(plan), as: UTF8.self)
        }

        static func encodeApplyJSON(plan: ReconciliationPlan, result: ReconciliationResult) throws -> String {
            String(decoding: try jsonEncoder.encode(ApplyReport(plan: plan, result: result)), as: UTF8.self)
        }

        private struct ApplyReport: Encodable {
            let plan: ReconciliationPlan
            let result: ReconciliationResult
        }

        private static var jsonEncoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return encoder
        }
    }
}
