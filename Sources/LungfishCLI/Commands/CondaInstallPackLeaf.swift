// CondaInstallPackLeaf.swift - lungfish-cli conda install --pack [--reinstall]
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow
import Synchronization

/// The pack half of `conda install` (Phase 2.10 lane A52, family L10), which the Plugin Manager's
/// Install and Reinstall buttons run.
///
/// `PluginPackStatusService.install` installs what a pack is missing, or with `--reinstall` recreates
/// every environment of the pack. Each pack's run writes a record,
/// `<storage root>/provenance/packs/<time>-<pack>-<install|reinstall>.lungfish-provenance.json`, that
/// reads completed, failed or cancelled. SIGTERM, the app's Cancel, cancels the install, which puts
/// back the environments it moved aside, and the run is then recorded as cancelled and the command
/// exits 125. With `--format json` standard output holds only `CLIEvent` lines and the text goes to
/// standard error.
extension CondaCommand.InstallSubcommand {
    /// The requirements a pack run reported, in the order it reported them, and the ones that reached
    /// the end of their work. The service reports a requirement at `itemFraction` 1 when it is done.
    private final class RequirementLog: Sendable {
        private let ids = Mutex<[String]>([])
        private let reachedEnd = Mutex<Set<String>>([])
        func note(_ id: String?, itemFraction: Double) {
            guard let id else { return }
            ids.withLock { if !$0.contains(id) { $0.append(id) } }
            if itemFraction >= 1 { reachedEnd.withLock { _ = $0.insert(id) } }
        }
        var all: [String] { ids.withLock { $0 } }
        var finished: Set<String> { reachedEnd.withLock { $0 } }
    }

    /// The run, with each event line handed to `emit`, so a test can keep them.
    func executePacks(eventsOn: Bool, quiet: Bool, emit: @escaping (String) -> Void) async throws {
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let events = CLIEventEmitter(enabled: eventsOn, emit: emit)
        let service = CondaCommand.packStatusServiceOverride ?? PluginPackStatusService.shared
        let reinstall = self.reinstall
        let say: @Sendable (String) -> Void = { printHumanLine($0, eventsOn: eventsOn) }

        // Every pack is named before any is installed, so a typo changes nothing.
        let visible = CondaCommand.visiblePacksForTesting()
        var resolved: [PluginPack] = []
        for packID in packages {
            guard let pack = visible.first(where: { $0.id == packID }) else {
                let available = visible.map(\.id).joined(separator: ", ")
                events.emitFailed("Unknown tool pack: \(packID). Available packs: \(available)")
                say(formatter.error("Unknown tool pack: \(packID)"))
                say("Available packs: \(available)")
                throw CLIExitCode.inputError.exitCode
            }
            resolved.append(pack)
        }
        let packs = resolved

        let verb = reinstall ? "Reinstalling" : "Installing"
        events.emitStart("\(verb) \(packs.map(\.name).joined(separator: ", "))...")
        let storageRoot = ManagedToolLeaf.currentStorageRoot()
        let packCount = Double(packs.count)

        let outcome = await ManagedToolLeaf.cancellingOnSIGTERM { () async throws -> [String] in
            var records: [String] = []
            for (index, pack) in packs.enumerated() {
                say(formatter.header("\(verb) Tool Pack: \(pack.name)"))
                say("Packages: \(pack.packages.joined(separator: ", "))")
                say("")

                let startedAt = Date()
                let seen = RequirementLog()
                func record(_ status: RunStatus, _ failure: String?) {
                    let written = ManagedToolLeaf.writeRecord(
                        ManagedToolLeaf.Record(
                            workflowName: "conda-pack-install",
                            folder: "packs",
                            label: "\(pack.id)-\(reinstall ? "reinstall" : "install")",
                            argv: ["lungfish-cli", "conda", "install", "--pack", pack.id] + (reinstall ? ["--reinstall"] : []),
                            explicit: ["pack": .string(pack.id), "reinstall": .boolean(reinstall)],
                            pluginPack: pack.id,
                            // A failed or cancelled run rolls back the conda environments it attempted
                            // (PluginPackStatusService.install), so only a database requirement that reached its
                            // end stays. A completed run has no failure text, so its requirements all read succeeded.
                            steps: seen.all.map { id in
                                let stays = seen.finished.contains(id)
                                    && pack.toolRequirements.first(where: { $0.id == id })?.managedDatabaseID != nil
                                return ManagedToolLeaf.Step(id: id, version: "unknown", failure: stays ? nil : failure)
                            },
                            status: status,
                            failure: failure,
                            startedAt: startedAt,
                            endedAt: Date()
                        ),
                        storageRoot: storageRoot
                    )
                    if let written { records.append(written.path) }
                }

                do {
                    try await service.install(pack: pack, reinstall: reinstall) { event in
                        seen.note(event.requirementID, itemFraction: event.itemFraction)
                        if eventsOn {
                            let overall = (Double(index) + min(max(event.overallFraction, 0), 1)) / packCount
                            events.emitProgress(overall, message: event.message)
                        } else if !quiet {
                            print("\r\(formatter.info(event.message))", terminator: "")
                        }
                    }
                    record(.completed, nil)
                    say("")
                    say(formatter.success("Tool pack '\(pack.name)' \(reinstall ? "reinstalled" : "installed")"))
                } catch is CancellationError {
                    record(.cancelled, "Cancelled")
                    throw CancellationError()
                } catch let error as PluginPackStatusServiceError {
                    if ManagedToolLeaf.endedOnCancel(error) {
                        // The pack's tools died of the same SIGTERM before the cancel reached the task.
                        record(.cancelled, "Cancelled")
                        throw CancellationError()
                    }
                    if case .storageUnavailable(let root) = error {
                        events.emitFailed("Storage location unavailable: \(root.path)")
                        throw CondaCommand.storageUnavailableValidationError(for: root)
                    }
                    let message: String
                    switch error {
                    case .verificationFailed(_, let reason):
                        message = "Tool pack '\(pack.name)' failed verification: \(reason)"
                    case .smokeTestFailed, .storageUnavailable:
                        message = "Tool pack '\(pack.name)' failed: \(error.localizedDescription)"
                    case .invalidRequirementSelection, .selectedRequirementInstallUnsupported:
                        message = error.localizedDescription
                    }
                    record(.failed, message)
                    say("")
                    say(formatter.error(message))
                    events.emitFailed(message)
                    throw CLIExitCode.dependency.exitCode
                } catch {
                    if ManagedToolLeaf.endedOnCancel(error) {
                        record(.cancelled, "Cancelled")
                        throw CancellationError()
                    }
                    let message = "Tool pack '\(pack.name)' failed: \(error.localizedDescription)"
                    record(.failed, message)
                    say("")
                    say(formatter.error(message))
                    events.emitFailed(message)
                    throw CLIExitCode.dependency.exitCode
                }
            }
            return records
        }

        switch outcome {
        case .success(let records):
            let names = packs.map(\.name).joined(separator: ", ")
            events.emitComplete(
                outputs: records.isEmpty ? [storageRoot.path] : records,
                message: "\(names) \(reinstall ? "reinstalled" : "installed")"
            )
        case .failure(let error):
            if ManagedToolLeaf.endedOnCancel(error) {
                // The pack's run recorded itself as cancelled when the cancel reached it. A cancel
                // that landed while the next pack was being named still exits 125 with the same words.
                events.emitFailed("Installation cancelled. The environments of the pack were left as they were.")
                say("Installation cancelled. The environments of the pack were left as they were.")
                throw CLIExitCode.cancelled.exitCode
            }
            throw error
        }
    }
}
