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

    // The row's words (UX and editorial rulings of 2026-11-27, `docs/reports/2026-11-26-rnaseq-novice-path/`). The
    // owner's direction: the row shows only the disk space a set uses once installed.

    static let sizeHelp = "Disk space this set uses once installed"
    static let installedWords = "Installed"
    static let installedHelp = "Plugin Manager cannot remove a reference set yet."
    static let packRefusal = "Install the RNA-Seq Analysis pack first, on the Packs tab."
    static let partlyInstalled = "Partly installed. Download adds the missing salmon index."

    /// The one figure on a row, such as "18.6 GB".
    func sizeWords(_ entry: ReferenceSetCatalogEntry) -> String {
        LungfishFormatters.formatBytes(entry.installedBytes)
    }

    /// The words when this Mac has less memory than `entry`'s install checks, nil when it has enough. A served index
    /// checks a count's memory, and a built one the build's. The command refuses in its own words too.
    func memoryRefusal(_ entry: ReferenceSetCatalogEntry) -> String? {
        guard systemRAMBytes < entry.memoryNeedBytes else { return nil }
        let need = String(format: "%.0f", Double(entry.memoryNeedBytes) / 1_073_741_824)
        let what = entry.servedIndex == nil ? "Building the salmon index" : "Counting"
        return "\(what) needs \(need) GB of memory, more than this Mac has. "
            + "Count on a Linux computer instead, as the RNA-seq chapter of the manual shows."
    }

    /// Whether the row's Download is on: no refusal for memory or the pack.
    func canDownload(_ row: Row) -> Bool {
        memoryRefusal(row.entry) == nil && !toolsMissing
    }

    /// The row's one status line, nil when the icon and the action say it all. A refusal shows only while Download
    /// is off, on the row whose Download it turns off.
    func statusLine(_ row: Row) -> String? {
        if row.state.isReady { return nil }
        if let refusal = memoryRefusal(row.entry) { return refusal }
        if toolsMissing { return Self.packRefusal }
        if case .setWithoutIndex = row.state { return Self.partlyInstalled }
        return nil
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
