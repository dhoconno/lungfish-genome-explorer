// NvdSurface+ViewMemory.swift - The NVD result viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view fields and their classes are on `NvdViewMemory`. The surface adopts `ViewMemoryAdopting` and leaves the
// capture and the restore to the viewer. The viewer gets its database after the show, so its load is pending and the
// host's handle applies the kept view once the database is in (VS A2). Nothing here writes into the result or the
// project.

import AppKit
import LungfishIO
import LungfishKit

extension NvdSurface {
    /// The view the NVD result viewer keeps for one result. The type is public because the surface and
    /// `ViewMemoryAdopting` are, and its fields stay internal. It is nested, so the module's list of public types does
    /// not change.
    public struct ViewState: ViewMemoryState {
        public static var kind: String { "analysis.nvd" }
        public static var schemaVersion: Int { 1 }

        var view = NvdViewMemory()

        /// A selection past the store's cap is dropped whole, and the viewer says so (VS A9, word 4).
        public var selectionCount: Int { view.selectedIdentities.count }

        public func withoutSelection() -> ViewState {
            var copy = self
            copy.view.selectedIdentities = []
            return copy
        }
    }

    /// Reads where the result lives once, in `load`, from the folder the route named when it made the viewer. The load
    /// cannot suspend, so the folder's few attributes are read on the main actor, once a show (SWIFT ruling R2). The
    /// data key waits for the database (`NvdResultViewController.finishDatabaseConfigure()`).
    func readViewMemoryIdentity(of viewer: NvdResultViewController) {
        viewMemoryItem = NvdVisitMemo.memo(for: viewer).folder.map { ViewMemoryItem.read(at: $0) }
    }

    /// Has the viewer run the host's late restore once its database is in.
    func wireViewMemoryHandle() {
        guard let controller else { return }
        let handle = viewMemoryHandle
        NvdVisitMemo.memo(for: controller).onDatabaseConfigured = { [weak handle] start in
            handle?.applyPending(startingView: ViewState(view: start))
        }
    }
}

extension NvdSurface: ViewMemoryAdopting {
    /// The data key the viewer read from memory when its database came in, nil before.
    public var viewMemoryDataKey: String? {
        controller.flatMap { NvdVisitMemo.memo(for: $0).dataKey }
    }

    /// The viewer is always filled after the show.
    public var viewMemoryLoadIsPending: Bool { true }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> ViewState {
        ViewState(view: controller?.captureNvdViewMemory() ?? NvdViewMemory())
    }

    /// Applies a kept view, each field by its rule, and returns what it could not bring back.
    public func restoreViewMemory(_ state: ViewState, dataChanged: Bool) -> ViewMemoryLoss {
        controller?.applyNvdViewMemory(state.view, dataChanged: dataChanged) ?? []
    }
}
