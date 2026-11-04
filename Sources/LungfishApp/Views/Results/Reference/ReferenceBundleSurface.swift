// ReferenceBundleSurface.swift - The reference bundle and the mapping result on the surface host
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit

/// One surface for a `.lungfishref` and a mapping result, since the two run one display, one class and one loading state.
/// The viewport shows before the file that names its mapper is decoded, and it is then filled in place, so its kind cannot
/// be a kind per tool.
///
/// The load adopts the controller the route built and does not configure it. `configure` selects the first row, opens the
/// viewer on it and reads the window, so the route calls it after the install, with the view in the window and the slot
/// answering.
@MainActor
final class ReferenceBundleSurface: ResultViewport {
    private(set) var controller: ReferenceBundleViewportController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }
    var surfaceKind: SurfaceKind { .bundle(.reference) }

    /// The controller for the reference slot. `MappingResultViewController` is a subclass with a slot of its own, so a plain
    /// cast would answer both slots and show every reader of this one the wrong viewer.
    var plainViewport: ReferenceBundleViewportController? { controller is MappingResultViewController ? nil : controller }

    /// The embedded viewer owns the drawer a person sees. It has no surface of its own, so its toggle reaches its own drawer.
    var isDrawerOpen: Bool { controller?.isEmbeddedAnnotationDrawerOpen ?? false }
    func toggleDrawer() { controller?.toggleEmbeddedAnnotationDrawer() }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller = try expectInput(input, as: ReferenceBundleViewportController.self)
    }

    func willDeactivate(replacedBy next: SurfaceKind?) { controller?.stopWorkForRemoval() }
}
