// ViewerDisplayRoute.swift - Viewer display routing seams
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishWorkflow

enum ViewerDisplayRoute: Equatable {
    case referenceBundle(ReferenceBundleViewportInput)
}

enum ViewerBundleDisplayRoute: Equatable {
    case referenceViewport(ViewerDisplayRoute)
    case sequence(name: String, restoreViewState: Bool)
}

enum ViewerDisplayRouteFactory {
    static func directReferenceBundle(
        bundleURL: URL,
        manifest: BundleManifest
    ) -> ViewerDisplayRoute {
        .referenceBundle(.directBundle(bundleURL: bundleURL, manifest: manifest))
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
        provenance: MappingProvenance?
    ) -> ViewerDisplayRoute {
        // Mapping rows need the embedded alignment declarations during their
        // initial configuration, not after a later Inspector refresh. Loading
        // the manifest here keeps the route self-contained for both sidebar
        // and programmatic display paths; unreadable bundles remain a valid
        // legacy mapping route with no track-derived rows.
        let viewerBundleManifest = result.viewerBundleURL.flatMap {
            try? BundleManifest.load(from: $0)
        }
        return .referenceBundle(.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectoryURL,
            provenance: provenance,
            viewerBundleManifest: viewerBundleManifest
        ))
    }

    @MainActor
    static func makeReferenceBundleViewportController() -> ReferenceBundleViewportController {
        ReferenceBundleViewportController()
    }
}
