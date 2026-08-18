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
            let operationID = OperationCenter.shared.start(
                title: title,
                detail: detail,
                operationType: .condaPluginPack
            )
            Registry.shared.record(handle: handle, operationID: operationID)
        }
        return handle
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
