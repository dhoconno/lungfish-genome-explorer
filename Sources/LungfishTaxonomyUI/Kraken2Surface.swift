// Kraken2Surface.swift - The Kraken2 result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The Kraken2 result viewer as a ``ResultViewport``.
///
/// Its input is the ``TaxonomyViewController`` the App has made, wired and configured from the
/// result before the show. The load adopts that controller and does not suspend, so the host
/// installs it before `show` returns. Its drawer is the viewer's Collections and BLAST Results
/// drawer, which View > Show Drawer and the toolbar button reach through the host. The App
/// registers ``factory()`` for `.analysis(.kraken2)`.
@MainActor
public final class Kraken2Surface: ResultViewport {
    /// The identifier the adopted view carries, which the view switch smoke test finds. The CZ-ID
    /// view embeds the same controller and does not carry it.
    public static let viewIdentifier = "kraken2-result-view"

    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: TaxonomyViewController?

    /// Called whenever the host removes this viewer, so the App can take the Kraken2 block out
    /// of the Inspector. It runs for its own kind too: the App gives the Inspector a new
    /// result's block only after that result's show.
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
        { Kraken2Surface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .analysis(.kraken2) }

    /// Whether the viewer's Collections and BLAST Results drawer is open.
    public var isDrawerOpen: Bool { controller?.isTaxaCollectionsDrawerOpen ?? false }

    /// Opens or closes the viewer's Collections and BLAST Results drawer, as its Collections
    /// button does.
    public func toggleDrawer() {
        controller?.toggleTaxaCollectionsDrawer()
    }

    /// Runs ``onWillDeactivate``, whatever kind takes this viewer's place.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        onWillDeactivate?()
    }

    /// Adopts the controller the App passed as `input`, gives its view the Kraken2 identifier and makes that view an
    /// accessibility group. AppKit leaves a plain NSView out of the accessibility tree, identifier or not, so the
    /// view switch smoke could not find the viewer.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let adopted = try expectInput(input, as: TaxonomyViewController.self)
        adopted.view.setAccessibilityIdentifier(Self.viewIdentifier)
        adopted.view.setAccessibilityElement(true)
        adopted.view.setAccessibilityRole(.group)
        controller = adopted
    }
}
