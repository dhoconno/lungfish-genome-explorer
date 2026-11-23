// CzIdSurface+ViewMemory.swift - The CZ ID result viewer keeps its view for each import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// What the CZ ID viewer holds (read for this lane, `CzIdResultViewController.swift`, 101 lines): a root view that embeds
// one `TaxonomyViewController`, the provenance popover (never kept, VS U1), and a name line on the shared action bar.
// Every control a person changes is the embedded taxonomy viewer's, so the view kept is its sunburst zoom, row
// selection, "Filter taxa..." text, sort and Collections drawer. An import is one sample, so it has no sample choice.

import AppKit
import LungfishIO
import LungfishKit

/// The view the CZ ID result viewer keeps for one import. The type is public because `CzIdSurface` and
/// `ViewMemoryAdopting` are, and its fields stay internal.
public struct CzIdViewState: ViewMemoryState {
    public static var kind: String { "analysis.czId" }
    public static var schemaVersion: Int { 1 }

    var view = TaxonomyViewMemory()

    public var selectionCount: Int { view.selectedIdentities.count }

    public func withoutSelection() -> CzIdViewState {
        var copy = self
        copy.view.selectedIdentities = []
        return copy
    }
}

extension CzIdResultViewController {
    /// The data key of VS B1, from the import manifest and what the embedded viewer loaded, so it reads no file.
    func czIdViewMemoryDataKey() -> String? {
        guard let manifest, let inner = taxonomyViewController.viewMemoryDataKey() else { return nil }
        return ["czid v1", manifest.sampleName, "rows \(manifest.rowCount)", inner].joined(separator: "\n")
    }
}

extension CzIdSurface: ViewMemoryAdopting {
    /// Reads where the result lives and its data key once, in `load`, and stores both, so a capture and a restore
    /// read only memory (SWIFT SF-3). The App configures the viewer before the show and this load cannot suspend,
    /// so the folder's few attributes are read on the main actor, once a show (SWIFT ruling R2). The data key is
    /// made from what the viewer loaded (`CzIdResultViewController.czIdViewMemoryDataKey()`).
    func readViewMemoryIdentity(of viewer: CzIdResultViewController) {
        viewMemoryItem = viewer.bundleURL.map { ViewMemoryItem.read(at: $0) }
        viewMemoryDataKey = viewer.czIdViewMemoryDataKey()
    }

    /// The view as the embedded viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> CzIdViewState {
        CzIdViewState(view: controller?.taxonomyViewController.captureTaxonomyViewMemory() ?? TaxonomyViewMemory())
    }

    public func restoreViewMemory(_ state: CzIdViewState, dataChanged: Bool) -> ViewMemoryLoss {
        controller?.taxonomyViewController.applyTaxonomyViewMemory(state.view, dataChanged: dataChanged) ?? []
    }
}
