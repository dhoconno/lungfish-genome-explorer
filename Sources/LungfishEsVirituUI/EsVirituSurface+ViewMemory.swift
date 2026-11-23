// EsVirituSurface+ViewMemory.swift - The EsViritu result viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view fields and their classes are on `EsVirituViewMemory`. The surface adopts `ViewMemoryAdopting` and leaves the
// capture and the restore to the viewer it shows. Its load does not suspend, so the host restores before it installs the
// viewer (VS A2), and nothing here writes into the bundle or the project.

import AppKit
import LungfishIO
import LungfishKit

/// The view the EsViritu result viewer keeps for one result. The type is public because `EsVirituSurface` and
/// `ViewMemoryAdopting` are, and its fields stay internal.
public struct EsVirituViewState: ViewMemoryState {
    public static var kind: String { "analysis.esviritu" }
    public static var schemaVersion: Int { 1 }

    var view = EsVirituViewMemory()

    /// A selection past the store's cap is dropped whole, and the viewer says so (VS A9, word 4).
    public var selectionCount: Int { view.selectedIdentities.count }

    public func withoutSelection() -> EsVirituViewState {
        var copy = self
        copy.view.selectedIdentities = []
        return copy
    }
}

extension EsVirituSurface: ViewMemoryAdopting {
    /// Reads where the result lives and its data key once, in `load`, and stores both, so a capture and a restore
    /// read only memory (SWIFT SF-3). The App configures the viewer before the show and this load cannot suspend,
    /// so the folder's few attributes are read on the main actor, once a show (SWIFT ruling R2). The data key is
    /// made from what the viewer loaded (`EsVirituResultViewController.viewMemoryDataKey()`).
    func readViewMemoryIdentity(of viewer: EsVirituResultViewController) {
        viewMemoryItem = viewer.viewMemoryFolderURL.map { ViewMemoryItem.read(at: $0) }
        viewMemoryDataKey = viewer.viewMemoryDataKey()
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> EsVirituViewState {
        EsVirituViewState(view: controller?.captureEsVirituViewMemory() ?? EsVirituViewMemory())
    }

    /// Applies a kept view, each field by its rule, and returns what it could not bring back.
    public func restoreViewMemory(_ state: EsVirituViewState, dataChanged: Bool) -> ViewMemoryLoss {
        controller?.applyEsVirituViewMemory(state.view, dataChanged: dataChanged) ?? []
    }
}
