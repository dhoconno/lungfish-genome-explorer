// ViewerDisplayRoute.swift - Viewer display routing seams
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum ViewerDisplayRoute: Equatable {
    case referenceBundle(ReferenceBundleViewportInput)
}

enum ViewerBundleDisplayRoute: Equatable {
    case referenceViewport(ViewerDisplayRoute)
    case sequence(name: String, restoreViewState: Bool)
}

enum ViewerDisplayRouteFactory {
    /// `preparedBundle` is the bundle an open built from `manifest` off the main
    /// actor, with its sequence indexes already built. The embedded viewer shows it.
    static func directReferenceBundle(
        bundleURL: URL,
        manifest: BundleManifest,
        preparedBundle: ReferenceBundle? = nil
    ) -> ViewerDisplayRoute {
        .referenceBundle(.directBundle(bundleURL: bundleURL, manifest: manifest, preparedBundle: preparedBundle))
    }

    static func referenceBundleDisplayRoute(
        bundleURL: URL,
        manifest: BundleManifest,
        mode: BundleDisplayMode
    ) -> ViewerBundleDisplayRoute {
        switch mode {
        case .browse:
            return .referenceViewport(directReferenceBundle(
                bundleURL: bundleURL,
                manifest: manifest
            ))
        case .sequence(let name, let restoreViewState):
            return .sequence(name: name, restoreViewState: restoreViewState)
        }
    }

    static func mappingResult(
        _ result: MappingResult,
        resultDirectoryURL: URL?,
        provenance: MappingProvenance?,
        viewerBundleManifest: BundleManifest?,
        resultModificationDate: Date? = nil,
        preparedBundle: ReferenceBundle? = nil
    ) -> ViewerDisplayRoute {
        // Mapping rows need the embedded alignment declarations during their
        // initial configuration, not after a later Inspector refresh. The
        // caller passes the manifest it decoded off the main actor, so a large
        // reference is never decoded here, and the viewer bundle it made from
        // that manifest with its sequence indexes, so none is built here. A nil
        // manifest (an unreadable bundle) remains a valid legacy mapping route
        // with no track rows.
        .referenceBundle(.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectoryURL,
            provenance: provenance,
            viewerBundleManifest: viewerBundleManifest,
            resultModificationDate: resultModificationDate,
            preparedBundle: preparedBundle
        ))
    }

    @MainActor
    static func makeReferenceBundleViewportController() -> ReferenceBundleViewportController {
        ReferenceBundleViewportController()
    }
}
