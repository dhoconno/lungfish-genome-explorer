// MHCReferenceBundleSurface+ViewMemory.swift - The MHC reference viewer keeps its Mode picker for each bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane VS-MAP, k12. The surface keeps the Mode picker of the injected `MHCReferenceBundleViewportState`. The reference
// view inside is a `ReferenceBundleViewportController` whose viewer keeps its own view (k08's) for the embedded bundle,
// in the host's store, so the MHC record holds only the mode. Nothing here writes into the bundle or starts a tool.

import AppKit
import LungfishIO
import LungfishKit

/// The view the MHC reference viewer keeps for one bundle: the Mode picker, which is presentation and restores on any
/// data key while the bundle still embeds a reference (with none, the picker is not shown and the mode is fixed).
struct MHCReferenceViewMemory: ViewMemoryState {
    static var kind: String { SurfaceKind.bundle(.mhcReference).description }
    static var schemaVersion: Int { 1 }

    var mode: String
}

extension MHCReferenceBundleSurface: ViewMemoryAdopting {
    private var viewState: MHCReferenceBundleViewportState? { controller?.rootView.state }

    /// Read by the model's load, never here: off the main actor by the async load of a sidebar open, with the bundle by
    /// the sync load of an external open.
    var viewMemoryItem: ViewMemoryItem? { controller?.rootView.model.viewMemoryItem }

    var viewMemoryDataKey: String? { controller?.rootView.model.viewMemoryDataKey }

    func captureViewMemory() -> MHCReferenceViewMemory {
        MHCReferenceViewMemory(mode: (viewState?.mode ?? .haplotypes).rawValue)
    }

    func restoreViewMemory(_ state: MHCReferenceViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        guard let viewState, controller?.rootView.model.embeddedReferenceBundleURL != nil,
              let mode = MHCReferenceBundleViewportMode(rawValue: state.mode) else { return [] }
        viewState.mode = mode
        return []
    }

    /// Keeps the reference view inside before the host removes the surface (VS-REF SWIFT SF-1).
    func willDeactivate(replacedBy next: SurfaceKind?) {
        viewState?.embeddedViewport?.embeddedViewerController.keepViewMemoryNow()
        viewState?.embeddedViewport?.stopWorkForRemoval()
    }
}
