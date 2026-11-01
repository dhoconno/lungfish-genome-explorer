// TaxTriageSurface.swift - The TaxTriage result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The TaxTriage result viewer as a ``ResultViewport``.
///
/// Its input is the ``TaxTriageResultViewController`` the App has made, wired and configured
/// from the result's database before the show. The load adopts that controller and does not
/// suspend, so the host installs it before `show` returns. Its drawer is the viewer's BLAST
/// results drawer, which View > Show Drawer and the toolbar button reach through the host.
/// The App registers ``factory()`` for `.analysis(.taxtriage)`.
@MainActor
public final class TaxTriageSurface: ResultViewport {
    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: TaxTriageResultViewController?

    /// Called whenever the host removes this viewer, so the App can take the TaxTriage
    /// block out of the Inspector. It runs for its own kind too: the App gives the
    /// Inspector a new result's block only after that result's show.
    public var onWillDeactivate: (@MainActor () -> Void)?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    public init() {}

    /// The factory the App registers, which makes a new surface for each show.
    public static func factory() -> SurfaceRegistry.Factory {
        { TaxTriageSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .analysis(.taxtriage) }

    /// Whether the viewer's BLAST results drawer is open.
    public var isDrawerOpen: Bool { controller?.isBlastDrawerOpen ?? false }

    /// Opens or closes the viewer's BLAST results drawer, as its BLAST Results button does.
    public func toggleDrawer() {
        controller?.toggleBlastDrawer()
    }

    /// Clears the viewer's detached alignment evidence and runs ``onWillDeactivate``,
    /// whatever kind takes this viewer's place.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        controller?.clearClassifierAlignmentEvidence()
        onWillDeactivate?()
    }

    /// Adopts the controller the App passed as `input` and makes its root view, which carries
    /// `taxtriage-result-view`, an accessibility group. AppKit leaves a plain NSView out of the
    /// accessibility tree, identifier or not, so the view switch smoke could not find it.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let adopted = try expectInput(input, as: TaxTriageResultViewController.self)
        adopted.view.setAccessibilityElement(true)
        adopted.view.setAccessibilityRole(.group)
        controller = adopted
    }
}
