// RNASeqReferenceCatalogModel.swift - The RNA-seq reference rows of Plugin Manager > Databases (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow
import Observation

/// The state of the RNA-seq reference rows. It is its own model, not part of `PluginManagerViewModel`, so that file stays
/// at its size baseline, and one shared instance keeps a running install's row when the tab is left and opened again.
///
/// Each install runs `lungfish-cli rnaseq install-reference --default <id> --format json` on an Operations row, as
/// `conda db update` runs (ARCH ruling 2026-11-26). The command writes the set and the index, and the app only reads
/// the storage root again afterwards.
@MainActor
@Observable
final class RNASeqReferenceCatalogModel {
    static let shared = RNASeqReferenceCatalogModel()

    struct Row: Identifiable, Equatable {
        let entry: ReferenceSetCatalogEntry
        var state: ReferenceSetInstallState
        var id: String { entry.id }
    }

    let entries: [ReferenceSetCatalogEntry]
    private(set) var rows: [Row]
    private(set) var installing: Set<String> = []
    var fraction: [String: Double] = [:]
    var message: [String: String] = [:]
    var failure: [String: String] = [:]
    /// True when gffread or salmon is missing, so Download is off and the words name the pack (UX trap 5).
    private(set) var toolsMissing = false
    private var operationIDs: [String: UUID] = [:]

    let systemRAMBytes: Int64
    private let reporter: any OperationReporting
    private let storageRoot: @MainActor () -> URL
    private let toolsCheck: @Sendable () async -> Bool
    private let launch: @MainActor (_ invocation: CLIManagedToolsRunner.Invocation, _ operationID: UUID,
                                    _ progress: @escaping @Sendable (Double, String) -> Void,
                                    _ stage: @escaping @Sendable (String) -> Void) async throws -> Void

    init(
        reporter: any OperationReporting = OperationCenter.shared,
        storageRoot: @escaping @MainActor () -> URL = { ManagedStorageConfigStore().currentLocation().rootURL },
        launch: (@MainActor (CLIManagedToolsRunner.Invocation, UUID, @escaping @Sendable (Double, String) -> Void,
                             @escaping @Sendable (String) -> Void) async throws -> Void)? = nil,
        toolsCheck: (@Sendable () async -> Bool)? = nil,
        entries: [ReferenceSetCatalogEntry] = ReferenceSetCatalog.entries,
        systemRAMBytes: Int64 = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    ) {
        self.entries = entries
        rows = entries.map { Row(entry: $0, state: .notInstalled) }
        self.systemRAMBytes = systemRAMBytes
        self.reporter = reporter
        self.storageRoot = storageRoot
        self.toolsCheck = toolsCheck ?? { await ReferenceSetInstall.toolsMissing() }
        self.launch = launch ?? { invocation, operationID, progress, stage in
            _ = try await CLIManagedToolsRunner.launch(invocation, operationID: operationID, progress: progress, stage: stage)
        }
    }

    /// The words below the rows when some row's Download is off for memory, nil when none is.
    var memoryRefusal: String? {
        rows.lazy.compactMap { self.memoryRefusal($0.entry) }.first
    }

    /// The words when this Mac has less memory than `entry`'s install checks, nil when it has enough. A served index
    /// checks a count's memory, and a built one the build's (plan of 2026-11-27). The command refuses in its own words
    /// too, before any byte downloads.
    func memoryRefusal(_ entry: ReferenceSetCatalogEntry) -> String? {
        guard systemRAMBytes < entry.memoryNeedBytes else { return nil }
        let need = String(format: "%.1f", Double(entry.memoryNeedBytes) / 1_073_741_824)
        let what = entry.servedIndex == nil ? "Building the salmon index" : "Counting"
        return "\(what) needs about \(need) GB of memory, more than this Mac has. "
            + "Count on a Linux machine instead, as the RNA-seq chapter of the manual shows."
    }

    /// The line under a row's description: what it downloads, keeps and needs.
    func needWords(_ entry: ReferenceSetCatalogEntry) -> String {
        guard let served = entry.servedIndex else {
            return "Download \(LungfishFormatters.formatBytes(entry.downloadBytes)), about 18 GB kept, 64 GB free disk and "
                + "16.6 GB of memory while it builds, about an hour"
        }
        let gigabytes = Int((Double(entry.downloadBytes + served.archiveBytes) / 1_000_000_000).rounded())
        let memory = String(format: "%.1f", Double(entry.memoryNeedBytes) / 1_073_741_824)
        return "Download about \(gigabytes) GB with the salmon index, about 18 GB kept, \(memory) GB of memory"
    }

    /// The words beside Download when the pack's tools are missing, nil when they are there.
    var toolsRefusal: String? {
        toolsMissing ? ReferenceSetInstallError.toolsMissing.localizedDescription : nil
    }

    /// Cancels the running install of `entryID` through its Operations row, which sends the command SIGTERM.
    func cancel(_ entryID: String) {
        guard let id = operationIDs[entryID] else { return }
        reporter.cancel(id: id)
    }

    /// Reads what the storage root holds of each entry, off the main actor.
    func refresh() async {
        let root = storageRoot()
        toolsMissing = await toolsCheck()
        let entries = self.entries
        let states = await Task.detached {
            entries.map { ReferenceSetCatalog.state(of: $0, storageRoot: root) }
        }.value
        rows = zip(entries, states).map { Row(entry: $0, state: $1) }
    }

    /// Registers the install row and, only when it starts, runs the command on it.
    @discardableResult
    func install(_ entryID: String) -> OperationStartResult? {
        guard !installing.contains(entryID), let entry = entries.first(where: { $0.id == entryID }) else { return nil }
        let invocation = CLIManagedToolsRunner.installReference(defaultID: entryID)
        let result = reporter.begin(
            title: "RNA-seq Reference Set: \(entry.title)",
            detail: "Downloading \(entry.title)",
            operationType: .download,
            cliCommand: invocation.recordedCommand
        )
        guard case .started(let operationID) = result else { return result }
        installing.insert(entryID)
        operationIDs[entryID] = operationID
        failure[entryID] = nil
        message[entryID] = "Starting\u{2026}"
        Task {
            defer {
                installing.remove(entryID)
                operationIDs[entryID] = nil
                fraction[entryID] = nil
                message[entryID] = nil
            }
            do {
                try await launch(invocation, operationID, { [weak self] value, words in
                    Task { @MainActor in
                        self?.fraction[entryID] = value
                        self?.message[entryID] = words
                    }
                }, { [weak self] words in
                    Task { @MainActor in
                        self?.fraction[entryID] = nil
                        self?.message[entryID] = words
                    }
                })
                _ = reporter.complete(id: operationID, detail: "\(entry.title) is ready to count")
            } catch is CancellationError {
                // The runner acknowledged the cancel and the row reads Cancelled. No alert.
            } catch {
                failure[entryID] = error.localizedDescription
                reporter.log(id: operationID, level: .error, message: error.localizedDescription)
                _ = reporter.fail(id: operationID, detail: "Could not install \(entry.title)", errorMessage: error.localizedDescription)
            }
            await refresh()
            NotificationCenter.default.post(name: .managedResourcesDidChange, object: nil)
        }
        return result
    }
}
