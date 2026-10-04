// OperationCenterDependencySink.swift - Routes reconciler progress into the Operations panel
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// Adapter that lets ``DependencyReconciler`` report into ``OperationCenter`` without
/// `LungfishWorkflow` depending on `LungfishKit`.
///
/// `DependencyOperationSink.start` must hand back an id synchronously, but `OperationCenter`
/// mints its own id on the main actor. The sink therefore returns a *handle* id immediately and
/// records the center's id against it once the main-actor hop lands. Every later call resolves
/// the handle to the real id, and calls that arrive before the hop completes are queued behind
/// it on the same serial main queue, so the ordering the reconciler emitted is preserved.
struct OperationCenterDependencySink: DependencyOperationSink {

    /// Handle id -> OperationCenter id. Main-actor isolated: only the hopped bodies touch it.
    @MainActor
    private final class Registry {
        static let shared = Registry()
        private var operationIDs: [UUID: UUID] = [:]

        func record(handle: UUID, operationID: UUID) {
            operationIDs[handle] = operationID
        }

        func operationID(for handle: UUID) -> UUID? {
            operationIDs[handle]
        }

        func forget(handle: UUID) {
            operationIDs.removeValue(forKey: handle)
        }
    }

    func start(title: String, detail: String) -> UUID {
        let handle = UUID()
        onMain {
            Self.beginDependencyOperation(title: title, detail: detail) { operationID in
                Registry.shared.record(handle: handle, operationID: operationID)
            }
        }
        return handle
    }

    /// Registers a reconciler row and, only when it starts, calls `launch` with the
    /// operation ID, which the sink records against its handle. The row is a plugin
    /// pack row and locks no bundle.
    ///
    /// When `begin` refuses the row, `launch` never runs and the handle stays
    /// unrecorded, so every later `update`, `log` and terminal call for it finds no
    /// operation and does nothing. A real `OperationCenter` refuses only on a bundle
    /// lock, and this row asks for none.
    ///
    /// cli-parity-gap: tools-update-subset. The row records no command.
    /// `lungfish-cli tools update --apply --yes` is the closest, and it runs the same `DependencyReconciler` plan. The
    /// reconciler opens one parent row for the whole run and one row for every item
    /// inside it, through this same call. The sink sees only a title and a detail, so
    /// it cannot tell which command a row belongs to or which items the user chose in
    /// the Update Tools sheet. The command has no option for an arbitrary choice of
    /// items, and no command runs a single item. The row keeps recording no command
    /// until the sink protocol carries one.
    @MainActor
    @discardableResult
    static func beginDependencyOperation(
        title: String,
        detail: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: title,
            detail: detail,
            operationType: .condaPluginPack,
            cliCommand: nil
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    func update(id: UUID, progress: Double, detail: String) {
        onMain {
            guard let operationID = Registry.shared.operationID(for: id) else { return }
            _ = OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
        }
    }

    func log(id: UUID, message: String) {
        onMain {
            guard let operationID = Registry.shared.operationID(for: id) else { return }
            OperationCenter.shared.log(id: operationID, level: .info, message: message)
        }
    }

    func complete(id: UUID, detail: String) {
        onMain {
            guard let operationID = Registry.shared.operationID(for: id) else { return }
            _ = OperationCenter.shared.complete(id: operationID, detail: detail)
            Registry.shared.forget(handle: id)
        }
    }

    func completeWithWarning(id: UUID, detail: String) {
        onMain {
            guard let operationID = Registry.shared.operationID(for: id) else { return }
            _ = OperationCenter.shared.completeWithWarning(id: operationID, detail: detail)
            Registry.shared.forget(handle: id)
        }
    }

    func fail(id: UUID, detail: String, error: String) {
        onMain {
            guard let operationID = Registry.shared.operationID(for: id) else { return }
            _ = OperationCenter.shared.fail(id: operationID, detail: detail, errorMessage: error)
            Registry.shared.forget(handle: id)
        }
    }

    /// Hops to the main actor without `Task { @MainActor in }`, which would not preserve the
    /// order the reconciler emitted calls in. `DispatchQueue.main.async` does, so an item never
    /// completes before its own progress updates land, and no call outruns its `start`.
    private func onMain(_ body: @escaping @Sendable @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { body() }
        }
    }
}
