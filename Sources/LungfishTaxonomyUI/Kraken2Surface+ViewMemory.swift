// Kraken2Surface+ViewMemory.swift - The Kraken2 result viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view fields and their classes are on `TaxonomyViewMemory`. The Kraken2 surface adopts `ViewMemoryAdopting` and
// leaves the capture and the restore to the viewer it shows. Its load does not suspend, so the host restores before it
// installs the viewer (VS A2), and nothing here writes into the bundle or the project.

import AppKit
import LungfishIO
import LungfishKit

/// The view the Kraken2 result viewer keeps for one result. The type is public because `Kraken2Surface` and
/// `ViewMemoryAdopting` are, and its fields stay internal.
public struct Kraken2ViewState: ViewMemoryState {
    public static var kind: String { "analysis.kraken2" }
    public static var schemaVersion: Int { 1 }

    var view = TaxonomyViewMemory()

    /// A selection past the store's cap is dropped whole, and the viewer says so (VS A9, word 4).
    public var selectionCount: Int { view.selectedIdentities.count }

    public func withoutSelection() -> Kraken2ViewState {
        var copy = self
        copy.view.selectedIdentities = []
        return copy
    }
}

extension Kraken2Surface: ViewMemoryAdopting {
    /// Reads where the result lives and its data key once, in `load`, and stores both, so a capture and a restore
    /// read only memory (SWIFT SF-3). The App configures the viewer before the show and this load cannot suspend,
    /// so the folder's few attributes are read on the main actor, once a show (SWIFT ruling R2). The data key is
    /// made from what the viewer loaded (`TaxonomyViewController.viewMemoryDataKey()`).
    func readViewMemoryIdentity(of viewer: TaxonomyViewController) {
        viewMemoryItem = viewer.viewMemoryFolderURL.map { ViewMemoryItem.read(at: $0) }
        viewMemoryDataKey = viewer.viewMemoryDataKey()
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> Kraken2ViewState {
        Kraken2ViewState(view: controller?.captureTaxonomyViewMemory() ?? TaxonomyViewMemory())
    }

    /// Applies a kept view, each field by its rule, and returns what it could not bring back.
    public func restoreViewMemory(_ state: Kraken2ViewState, dataChanged: Bool) -> ViewMemoryLoss {
        controller?.applyTaxonomyViewMemory(state.view, dataChanged: dataChanged) ?? []
    }
}
