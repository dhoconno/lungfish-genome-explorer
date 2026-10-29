// ViewerViewController+Surfaces.swift - The one composition point of the viewer's result surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishTwelveSUI

extension ViewerViewController {
    /// The factories of every result surface the viewer's `surfaceHost` shows. A
    /// surface joins with one registration line here, and Kit stays free of leaves.
    func makeSurfaceRegistry() -> SurfaceRegistry {
        let registry = SurfaceRegistry()
        registry.register(.bundle(.twelveSResult), factory: TwelveSSurface.factory { [weak self] in self?.wireTwelveSUnresolvedBlast($0) })
        registry.register(.bundle(.primerAnalysis)) { PrimerAnalysisSurface() }
        registry.register(.analysis(.primerOrder)) { PrimerOrderSurface() }
        return registry
    }

    /// Shows a surface whose load does not suspend and returns it installed, with
    /// the genomics chrome hidden under it. When it is not installed, the chrome
    /// comes back and the error says why in words the caller shows.
    func showSurface<Surface: ResultViewport>(
        _ kind: SurfaceKind,
        input: Any,
        as type: Surface.Type
    ) throws -> Surface {
        surfaceHost.show(kind: kind, input: input)
        if let surface = surfaceHost.activeViewport as? Surface {
            enhancedRulerView.isHidden = true
            viewerView.isHidden = true
            headerView.isHidden = true
            statusBar.isHidden = true
            geneTabBarView.isHidden = true
            return surface
        }
        let error: any Error
        if case .failed(let failure) = surfaceHost.lastOutcome {
            error = failure
        } else {
            error = SurfaceError.notInstalled(kind)
        }
        clearSurface(ifShowing: kind)
        throw error
    }

    /// Removes the surface of one of `kinds`, when it is the one the host shows or
    /// loads, and brings back the genomics chrome and drawers that a surface hides.
    /// The `hideX()` shim of each migrated kind calls this. It never makes the host,
    /// since a viewer whose view has not loaded shows no surface.
    func clearSurface(ifShowing kinds: SurfaceKind...) {
        guard isViewLoaded, let kind = surfaceHost.requestedKind, kinds.contains(kind) else { return }
        surfaceHost.clear()

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
    }
}
