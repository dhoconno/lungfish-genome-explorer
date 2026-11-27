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

    private(set) var rows: [Row] = ReferenceSetCatalog.entries.map { Row(entry: $0, state: .notInstalled) }
    private(set) var installing: Set<String> = []
    var fraction: [String: Double] = [:]
    var message: [String: String] = [:]
    var failure: [String: String] = [:]

    let systemRAMBytes = Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    private let reporter: any OperationReporting
    private let storageRoot: @MainActor () -> URL
    private let launch: @MainActor (_ invocation: CLIManagedToolsRunner.Invocation, _ operationID: UUID,
                                    _ progress: @escaping @Sendable (Double, String) -> Void,
                                    _ stage: @escaping @Sendable (String) -> Void) async throws -> Void

    init(
        reporter: any OperationReporting = OperationCenter.shared,
        storageRoot: @escaping @MainActor () -> URL = { ManagedStorageConfigStore().currentLocation().rootURL },
        launch: (@MainActor (CLIManagedToolsRunner.Invocation, UUID, @escaping @Sendable (Double, String) -> Void,
                             @escaping @Sendable (String) -> Void) async throws -> Void)? = nil
    ) {
        self.reporter = reporter
        self.storageRoot = storageRoot
        self.launch = launch ?? { invocation, operationID, progress, stage in
            _ = try await CLIManagedToolsRunner.launch(invocation, operationID: operationID, progress: progress, stage: stage)
        }
    }

    /// The words beside Download when this Mac cannot build the index, nil when it can. The command refuses in its own
    /// words too, before any byte downloads.
    var memoryRefusal: String? {
        guard systemRAMBytes < ReferenceSetCatalog.indexMemoryBytes else { return nil }
        return "Building the salmon index needs about 18 GB of memory, more than this Mac has. "
            + "Count on a Linux machine instead, as the RNA-seq chapter of the manual shows."
    }

    /// Reads what the storage root holds of each entry, off the main actor.
    func refresh() async {
        let root = storageRoot()
        let states = await Task.detached {
            ReferenceSetCatalog.entries.map { ReferenceSetCatalog.state(of: $0, storageRoot: root) }
        }.value
        rows = zip(ReferenceSetCatalog.entries, states).map { Row(entry: $0, state: $1) }
    }

    /// Registers the install row and, only when it starts, runs the command on it.
    @discardableResult
    func install(_ entryID: String) -> OperationStartResult? {
        guard !installing.contains(entryID), let entry = ReferenceSetCatalog.entry(entryID) else { return nil }
        let invocation = CLIManagedToolsRunner.installReference(defaultID: entryID)
        let result = reporter.begin(
            title: "RNA-seq Reference Set: \(entry.title)",
            detail: "Downloading \(entry.title)",
            operationType: .download,
            cliCommand: invocation.recordedCommand
        )
        guard case .started(let operationID) = result else { return result }
        installing.insert(entryID)
        failure[entryID] = nil
        message[entryID] = "Starting\u{2026}"
        Task {
            defer {
                installing.remove(entryID)
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
