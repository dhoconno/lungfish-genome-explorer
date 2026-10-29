// PrimerAnalysisSurface.swift - Saved primer analyses and primer orders as ViewportHost surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

/// The saved primer analysis viewer. It holds no view until its surface loads.
final class PrimerAnalysisHostingController: NSHostingController<PrimerAnalysisViewerView?> {
    var installationID = UUID()
}

/// The reviewed primer order viewer. It holds no view until its surface loads.
final class PrimerOrderHostingController: NSHostingController<PrimerOrderResultView?> {
    var installationID = UUID()
}

/// What a primer surface shows. The App builds `rootView` with callbacks that act
/// only while the installed controller carries `installationID`, and `onDismiss`
/// runs when the host removes the viewer.
struct PrimerSurfaceInput<Content: View> {
    let installationID: UUID
    let rootView: Content
    let onDismiss: @MainActor () -> Void
}

/// A saved primer analysis as a ``ResultViewport``. It is the exemplar of a surface
/// with no leaf module, so its factory stays in the App, registered in
/// ViewerViewController+Surfaces.swift.
@MainActor
final class PrimerAnalysisSurface: ResultViewport {
    let controller = PrimerAnalysisHostingController(rootView: nil)
    private var onDismiss: (@MainActor () -> Void)?

    init() {
        // The viewport sizes the content, never the reverse. With the default
        // sizing options the hosting view turned SwiftUI's ideal width (long
        // captions measured as one line) into constraints that outranked the
        // window's own size, so opening an analysis widened a 1400pt window
        // to 1535pt.
        controller.sizingOptions = []
    }

    var viewController: NSViewController { controller }

    var surfaceKind: SurfaceKind { .bundle(.primerAnalysis) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let input = try expectInput(input, as: PrimerSurfaceInput<PrimerAnalysisViewerView>.self)
        controller.installationID = input.installationID
        controller.rootView = input.rootView
        onDismiss = input.onDismiss
    }

    func willDeactivate(replacedBy next: SurfaceKind?) {
        onDismiss?()
    }
}

/// A reviewed primer order as a ``ResultViewport``, registered beside
/// ``PrimerAnalysisSurface``.
@MainActor
final class PrimerOrderSurface: ResultViewport {
    let controller = PrimerOrderHostingController(rootView: nil)
    private var onDismiss: (@MainActor () -> Void)?

    init() {
        // The viewport sizes the content, as for PrimerAnalysisSurface.
        controller.sizingOptions = []
    }

    var viewController: NSViewController { controller }

    var surfaceKind: SurfaceKind { .analysis(.primerOrder) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let input = try expectInput(input, as: PrimerSurfaceInput<PrimerOrderResultView>.self)
        controller.installationID = input.installationID
        controller.rootView = input.rootView
        onDismiss = input.onDismiss
    }

    func willDeactivate(replacedBy next: SurfaceKind?) {
        onDismiss?()
    }
}
