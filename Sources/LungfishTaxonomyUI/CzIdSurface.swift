// CzIdSurface.swift - The CZ-ID imported result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The CZ-ID imported result viewer as a ``ResultViewport``.
///
/// Its input is the ``CzIdResultViewController`` the App has made, wired and configured from the
/// import before the show. The load adopts that controller and does not suspend, so the host
/// installs it before `show` returns. Its drawer is the Collections and BLAST Results drawer of the
/// embedded taxonomy view, which View > Show Drawer and the toolbar button reach through the host.
/// A CZ-ID import gives the Inspector no block of its own, so the surface has nothing to take out
/// when it leaves. The App registers ``factory()`` for `.analysis(.czId)`.
@MainActor
public final class CzIdSurface: ResultViewport {
    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: CzIdResultViewController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    public init() {}

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory() -> SurfaceRegistry.Factory {
        { CzIdSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .analysis(.czId) }

    /// Whether the embedded taxonomy view's Collections and BLAST Results drawer is open.
    public var isDrawerOpen: Bool { controller?.taxonomyViewController.isTaxaCollectionsDrawerOpen ?? false }

    /// Opens or closes the embedded taxonomy view's drawer, as its Collections button does.
    public func toggleDrawer() {
        controller?.taxonomyViewController.toggleTaxaCollectionsDrawer()
    }

    /// Adopts the controller the App passed as `input` and makes its root view, the one that carries
    /// `czid-result-view`, an accessibility group. AppKit leaves a plain NSView out of the
    /// accessibility tree, identifier or not, so the view switch smoke could not find the viewer.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let adopted = try expectInput(input, as: CzIdResultViewController.self)
        adopted.view.setAccessibilityElement(true)
        adopted.view.setAccessibilityRole(.group)
        controller = adopted
    }
}
