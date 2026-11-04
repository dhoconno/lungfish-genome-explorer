// ViewerViewController+Surfaces.swift - The one composition point of the viewer's result surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishNaoMgsUI
import LungfishEsVirituUI
import LungfishGenotypeUI
import LungfishNvdUI
import LungfishPhylogeneticsUI
import LungfishTaxTriageUI
import LungfishTaxonomyUI
import LungfishTwelveSUI

extension ViewerViewController {
    /// The factories of every result surface the viewer's `surfaceHost` shows. A
    /// surface joins with one registration line here, and Kit stays free of leaves.
    func makeSurfaceRegistry() -> SurfaceRegistry {
        let registry = SurfaceRegistry()
        registry.register(.bundle(.twelveSResult), factory: TwelveSSurface.factory { [weak self] in self?.wireTwelveSUnresolvedBlast($0) })
        registry.register(.bundle(.primerAnalysis)) { PrimerAnalysisSurface() }
        registry.register(.analysis(.primerOrder)) { PrimerOrderSurface() }
        registry.register(.analysis(.naomgs), factory: NaoMgsSurface.factory())
        registry.register(.analysis(.esviritu), factory: EsVirituSurface.factory())
        registry.register(.analysis(.nvd), factory: NvdSurface.factory())
        registry.register(.analysis(.taxtriage), factory: TaxTriageSurface.factory())
        registry.register(.analysis(.kraken2), factory: Kraken2Surface.factory())
        registry.register(.analysis(.czId), factory: CzIdSurface.factory())
        registry.register(.bundle(.mhcReference)) { MHCReferenceBundleSurface() }
        registry.register(.bundle(.genotypeResult), factory: GenotypeResultSurface.factory())
        registry.register(.bundle(.phylogeneticTree), factory: PhylogeneticTreeSurface.factory())
        registry.register(.bundle(.multipleSequenceAlignment)) { MultipleSequenceAlignmentSurface() }
        return registry
    }

    /// The surface the host has installed. It never makes the host, since a viewer
    /// whose view has not loaded shows no surface.
    var installedSurface: (any ResultViewport)? {
        isViewLoaded ? surfaceHost.activeViewport : nil
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
        // The show has replaced the old surface, so a failure below clears as usual.
        surfaceKindBeingDisplayed = nil
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

    /// Shows a surface whose load suspends and returns it installed, or nil when something newer took over while it
    /// loaded. The genomics chrome hides before the load, since `showSurface` cannot see one in flight.
    ///
    /// Two guards decide, side by side. The host's says no newer show or clear came, and `canCommit`, the caller's own,
    /// says no newer selection has begun, which can be before that selection's route reaches the host. Whatever took
    /// over owns the chrome and the status line, so a superseded load changes neither and throws nothing, even if it
    /// failed. A load that fails while it is still current brings the chrome back, and the error says why.
    func showSurfaceAfterLoad<Surface: ResultViewport>(
        _ kind: SurfaceKind,
        input: Any,
        as type: Surface.Type,
        canCommit: @MainActor () -> Bool = { true }
    ) async throws -> Surface? {
        enhancedRulerView.isHidden = true
        viewerView.isHidden = true
        headerView.isHidden = true
        statusBar.isHidden = true
        geneTabBarView.isHidden = true
        let show = surfaceHost.show(kind: kind, input: input)
        surfaceKindBeingDisplayed = nil
        let outcome = await show.value
        guard surfaceHost.loadTask == show, canCommit() else { return nil }
        if case .failed(let failure) = outcome {
            clearSurface(ifShowing: kind)
            throw failure
        }
        return surfaceHost.activeViewport as? Surface
    }

    /// Removes the surface of one of `kinds`, when it is the one the host shows or
    /// loads, and brings back the genomics chrome and drawers that a surface hides.
    /// The `hideX()` shim of each migrated kind calls this. It never makes the host,
    /// since a viewer whose view has not loaded shows no surface.
    func clearSurface(ifShowing kinds: SurfaceKind...) {
        guard isViewLoaded, let kind = surfaceHost.requestedKind, kinds.contains(kind),
              kind != surfaceKindBeingDisplayed else { return }
        surfaceHost.clear()

        enhancedRulerView?.isHidden = false
        viewerView?.isHidden = false
        headerView?.isHidden = false
        statusBar?.isHidden = false
        geneTabBarView?.isHidden = (geneTabBarView?.selectedGeneRegion == nil)
        revealAnnotationDrawerUnlessNativeBundleInstalled()
        fastqMetadataDrawerView?.isHidden = false
    }

    /// The words a person reads when a surface did not open. They say what happened and
    /// then what to try, which `localizedDescription` alone leaves out. An error with no
    /// next step of its own gets `fallback`, and a description with no full stop gets one.
    func surfaceFailureWords(_ headline: String, _ error: any Error, orElse fallback: String = "Select the item again.") -> String {
        let localized = error as? any LocalizedError
        var what = localized?.errorDescription ?? error.localizedDescription
        if let last = what.last, !".!?".contains(last) { what += "." }
        let next = localized?.recoverySuggestion ?? fallback
        return [headline, what, next].joined(separator: " ")
    }
}
