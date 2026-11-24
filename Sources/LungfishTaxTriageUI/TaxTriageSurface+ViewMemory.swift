// TaxTriageSurface+ViewMemory.swift - The TaxTriage result viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view fields and their classes are on `TaxTriageViewMemory`. The surface adopts `ViewMemoryAdopting` and leaves the
// capture and the restore to the viewer. The viewer's rows come in pages after the show, so its load is pending and the
// host's handle applies the kept view once the open's first page is in (VS A2). Nothing here writes into the result or
// the project.

import AppKit
import LungfishIO
import LungfishKit

extension TaxTriageSurface {
    /// The view the TaxTriage result viewer keeps for one result. The type is public because the surface and
    /// `ViewMemoryAdopting` are, and its fields stay internal. It is nested, so the module's list of public types does
    /// not change.
    public struct ViewState: ViewMemoryState {
        public static var kind: String { "analysis.taxtriage" }
        public static var schemaVersion: Int { 1 }

        var view = TaxTriageViewMemory()

        /// A selection past the store's cap is dropped whole, and the viewer says so (VS A9, word 4).
        public var selectionCount: Int { view.selectedIdentities.count }

        public func withoutSelection() -> ViewState {
            var copy = self
            copy.view.selectedIdentities = []
            return copy
        }
    }

    /// Reads where the result lives and its data key once, in `load`, for a viewer the route made to keep its view. The
    /// App configures the viewer before the show and this load cannot suspend, so the folder's few attributes and the
    /// database's run record are read on the main actor, once a show (SWIFT ruling R2).
    func readViewMemoryIdentity(of viewer: TaxTriageResultViewController) {
        let memo = TaxTriageVisitMemo.memo(for: viewer)
        guard memo.keepsView else { return }
        viewMemoryItem = viewer.viewMemoryFolderURL.map { ViewMemoryItem.read(at: $0) }
        memo.dataKey = viewer.viewMemoryDataKey()
        viewer.noteOpeningView()
    }

    /// Has the viewer run the host's late restore once the open's first page is in, or now when it is in already.
    func wireViewMemoryHandle() {
        guard let controller else { return }
        let memo = TaxTriageVisitMemo.memo(for: controller)
        let handle = viewMemoryHandle
        memo.onFirstPage = { [weak handle] start in
            handle?.applyPending(startingView: ViewState(view: start))
        }
        if let start = memo.waitingStart, let handle {
            memo.waitingStart = nil
            handle.applyPending(startingView: ViewState(view: start))
            memo.resetBeforeFirstPage = false
            controller.selectRestoredRowsIfShown(afterLateRestore: true)
        }
    }
}

extension TaxTriageSurface: ViewMemoryAdopting {
    /// The data key the load read, nil for a viewer that keeps no view.
    public var viewMemoryDataKey: String? {
        controller.flatMap { TaxTriageVisitMemo.memo(for: $0).dataKey }
    }

    /// The rows are always paged in after the show.
    public var viewMemoryLoadIsPending: Bool { true }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> ViewState {
        ViewState(view: controller?.captureTaxTriageViewMemory() ?? TaxTriageViewMemory())
    }

    /// Applies a kept view, each field by its rule, and returns what it could not bring back. The host's late restore
    /// waits for the open's first page, so a restore before it is Reset View's: the view is still the open's, and the
    /// reset stands over the late restore that follows, which brings nothing back (VS A2, the reset side).
    public func restoreViewMemory(_ state: ViewState, dataChanged: Bool) -> ViewMemoryLoss {
        guard let controller else { return [] }
        let memo = TaxTriageVisitMemo.memo(for: controller)
        if memo.keepsView, !memo.firstPageLanded {
            memo.resetBeforeFirstPage = true
            return []
        }
        if memo.resetBeforeFirstPage {
            memo.resetBeforeFirstPage = false
            return []
        }
        return controller.applyTaxTriageViewMemory(state.view, dataChanged: dataChanged)
    }
}
