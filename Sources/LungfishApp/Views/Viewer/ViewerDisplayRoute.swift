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
        .referenceBundle(.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectoryURL,
            provenance: provenance
        ))
    }

    @MainActor
    static func makeReferenceBundleViewportController() -> ReferenceBundleViewportController {
        ReferenceBundleViewportController()
    }
}
