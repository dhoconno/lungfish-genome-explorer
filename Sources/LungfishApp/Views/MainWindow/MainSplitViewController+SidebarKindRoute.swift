// MainSplitViewController+SidebarKindRoute.swift - Opens a row of a kind that SidebarKindRegistry names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import os.log

extension MainSplitViewController {
    /// Opens a row whose type is a bundle or result kind of `SidebarKindRegistry`, and returns false for any other
    /// row. A kind added by registration alone opens in the viewport its descriptor names, from the viewer's surface
    /// registry, so it needs no case here.
    func displaySidebarKind(
        _ item: SidebarItem,
        at url: URL,
        identity: ContentSelectionIdentity,
        token: AsyncRequestToken<ContentSelectionIdentity>
    ) -> Bool {
        switch item.type {
        case .referenceBundle:
            displayReferenceBundleViewportFromSidebar(at: url, identity: identity, token: token)
        case .primerAnalysisBundle:
            displayPrimerAnalysisBundleFromSidebar(at: url, identity: identity, token: token)
        case .genotypeResultBundle:
            displayGenotypeResultBundleFromSidebar(at: url, identity: identity, token: token)
        case .twelveSAmpliconResultBundle:
            displayTwelveSAmpliconResultBundleFromSidebar(at: url, identity: identity, token: token)
        case .multipleSequenceAlignmentBundle:
            displayMultipleSequenceAlignmentBundleFromSidebar(at: url, identity: identity, token: token)
        case .mhcReferenceBundle:
            displayMHCReferenceBundleFromSidebar(at: url, identity: identity, token: token)
        case .phylogeneticTreeBundle:
            displayPhylogeneticTreeBundleFromSidebar(at: url, identity: identity, token: token)
        case .primerSchemeBundle:
            // Metadata only. A primer scheme is no document, so it never reaches the genomics-file loader.
            displayPrimerSchemeBundleFromSidebar(at: url)
        case .classificationResult, .esvirituResult, .taxTriageResult:
            // Kraken2, EsViritu and TaxTriage results all go through the DB-backed classifier router.
            routeClassifierDisplay(url: url)
        case .naoMgsResult:
            displayNaoMgsResultFromSidebar(at: url, identity: identity, token: token)
        case .nvdResult:
            displayNvdResultFromSidebar(at: url, identity: identity, token: token)
        case .czIdResult:
            displayCzIdResultFromSidebar(at: url, identity: identity, token: token)
        case .registeredBundle:
            displayRegisteredSidebarKind(item, at: url, identity: identity, token: token)
        default:
            return false
        }
        return true
    }

    /// Opens a row of a kind that joined `SidebarKindRegistry` by registration, in the surface the viewer's surface
    /// registry makes for the kind's viewport. When the kind or its viewer is missing, the viewport says so.
    private func displayRegisteredSidebarKind(
        _ item: SidebarItem,
        at url: URL,
        identity: ContentSelectionIdentity,
        token: AsyncRequestToken<ContentSelectionIdentity>
    ) {
        clearInspectorKeepingRowIdentity()
        inspectorController.updateProvenanceTarget(url: url, sidebarType: item.type, displayName: item.title)
        guard let kindID = item.userInfo[SidebarItemType.registeredKindKey],
              let kind = SidebarKindRegistry.descriptor(id: kindID),
              let viewport = kind.viewport else {
            viewerController.clearViewport(
                statusMessage: "Lungfish has no viewer for \(item.title). Check for a newer version of Lungfish.")
            return
        }
        let surfaceKind: SurfaceKind = switch viewport {
        case .bundle(let id): .bundle(id)
        case .analysis(let id): .analysis(id)
        case .view(let id): .view(SurfaceViewID(rawValue: id))
        }
        let viewer: ViewerViewController = viewerController
        viewer.clearSurfaceForNewContent()
        viewer.setGenomicsChrome(hidden: true)
        let show = viewer.surfaceHost.show(kind: surfaceKind, input: url)
        Task { @MainActor [weak self] in
            let outcome = await show.value
            guard let self, viewer.surfaceHost.loadTask == show, canCommitDisplayRequest(token, identity: identity),
                  case .failed(let error) = outcome else { return }
            viewer.clearSurface(ifShowing: surfaceKind)
            viewer.clearViewport(statusMessage: viewer.surfaceFailureWords("Unable to open the \(kind.displayName).", error))
        }
    }
}
