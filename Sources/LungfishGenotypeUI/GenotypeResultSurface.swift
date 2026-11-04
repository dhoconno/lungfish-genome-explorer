// GenotypeResultSurface.swift - The genotype result viewer as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The genotype result viewer as a ``ResultViewport``.
///
/// Its input is the ``GenotypeResultViewController`` the App has made and configures after the show.
/// The load adopts that controller and does not suspend, so the host installs it before `show`
/// returns. The App registers ``factory()`` for `.bundle(.genotypeResult)`.
@MainActor
public final class GenotypeResultSurface: ResultViewport {
    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: GenotypeResultViewController?

    /// Called first whenever the host removes this viewer, so the App can keep a controller whose
    /// matrix edits still wait to be saved. It runs for its own kind too.
    public var onWillDeactivate: (@MainActor (GenotypeResultViewController) -> Void)?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    public init() {}

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory() -> SurfaceRegistry.Factory {
        { GenotypeResultSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .bundle(.genotypeResult) }

    /// The removal's work, whatever kind takes this viewer's place and before that kind loads. The
    /// host calls this while the view is still in its window. The window's undo manager does not
    /// retain its targets, and the viewer drops this controller (or keeps it only for its waiting
    /// matrix edits), so Undo must never reach it again. This covers the sample status and colour
    /// Undo the controller registers.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        guard let controller else { return }
        onWillDeactivate?(controller)
        controller.detachHostPresentationCallbacks()
        controller.view.window?.undoManager?.removeAllActions(withTarget: controller)
    }

    /// Adopts the controller the App passed as `input`.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller = try expectInput(input, as: GenotypeResultViewController.self)
    }
}
