// MultipleSequenceAlignmentSurface.swift - The multiple sequence alignment viewer as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The multiple sequence alignment viewer as a ``ResultViewport``. It lives in the App because its controller does.
///
/// This is the one load that suspends: `displayBundle` reads the alignment file off the main actor. The display builds
/// the controller and passes it in ``Input``, and the viewer calls `showSurfaceAfterLoad`, which awaits the load. The
/// host installs the viewer only while its token is current, and `canCommit` stops the commit as soon as a newer
/// selection begins, which can be before that selection's route reaches the host. The route wires the callbacks after
/// the show returns, so a load that was superseded never has one to fire. Not `final`, since the route tests hold a
/// load in flight by overriding ``load(input:token:)``.
@MainActor
class MultipleSequenceAlignmentSurface: ResultViewport {
    /// What the display passes as `input`.
    struct Input {
        /// The viewer to read the bundle into. It reaches ``controller`` only when the read commits.
        let controller: MultipleSequenceAlignmentViewController
        /// The alignment bundle.
        let url: URL
        /// The caller's display guard, read after the file read and before any state of the viewer changes.
        let canCommit: @MainActor () -> Bool
    }

    /// The viewer the host installs, once the load has read the bundle into it.
    private(set) var controller: MultipleSequenceAlignmentViewController?

    /// Called whenever the host removes this viewer, so the App can take the alignment's blocks out of the Inspector.
    /// It runs for its own kind too: the App gives the Inspector a new alignment's blocks only after that show.
    var onWillDeactivate: (@MainActor () -> Void)?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }

    var surfaceKind: SurfaceKind { .bundle(.multipleSequenceAlignment) }

    /// The viewer's bottom pane is this surface's drawer.
    var isDrawerOpen: Bool { controller?.isBottomPaneOpen ?? false }

    func toggleDrawer() {
        controller?.toggleBottomPane()
    }

    /// Cuts every callback the App wired on the viewer, so a controller that something else still holds, such as a
    /// command's refresh, reaches nothing, then runs ``onWillDeactivate``. It runs for every kind that takes this
    /// viewer's place, its own kind included. The viewer's pane flag and sizes were saved when the person set them,
    /// and annotations are written by the CLI, so there is nothing to save here.
    func willDeactivate(replacedBy next: SurfaceKind?) {
        if let controller {
            controller.onExtractSequenceRequested = nil
            controller.onExtractAnnotatedSequenceRequested = nil
            controller.onExportFASTARequested = nil
            controller.onExportMSASelectionRequested = nil
            controller.onCopyMSASelectionRequested = nil
            controller.onReferenceRowChanged = nil
            controller.onConsensusComparisonRequested = nil
            controller.onExportAlignmentRequested = nil
            controller.onCreateBundleRequested = nil
            controller.onCreateAnnotatedBundleRequested = nil
            controller.onRunOperationRequested = nil
            controller.onInferTreeRequested = nil
            controller.onAddAnnotationRequested = nil
            controller.onProjectAnnotationRequested = nil
            controller.onSelectionStateChanged = nil
            controller.onExportDistanceMatrixRequested = nil
            controller.onFocusedDistancePairChanged = nil
            controller.onBottomPaneStateChanged = nil
        }
        onWillDeactivate?()
    }

    /// Reads the bundle into the viewer the display built. A file that does not read throws that file's own error. A
    /// load that a newer show or selection overtook throws `CancellationError` before the viewer's state changes, and
    /// `showSurfaceAfterLoad` says nothing about it.
    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        let committed = try await request.controller.displayBundle(at: request.url) {
            !Task.isCancelled && request.canCommit()
        }
        guard committed else { throw CancellationError() }
        controller = request.controller
    }
}
