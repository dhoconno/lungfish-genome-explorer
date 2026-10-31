// EsVirituSurface.swift - The EsViritu result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The EsViritu result viewer as a ``ResultViewport``.
///
/// Its input is the ``EsVirituResultViewController`` the App has made, wired and configured
/// from the result's database before the show. The load adopts that controller and does not
/// suspend, so the host installs it before `show` returns. The App registers ``factory()``
/// for `.analysis(.esviritu)`.
@MainActor
public final class EsVirituSurface: ResultViewport {
    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: EsVirituResultViewController?

    /// Called whenever the host removes this viewer, so the App can take the EsViritu
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
        { EsVirituSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .analysis(.esviritu) }

    /// Clears the viewer's detached alignment evidence and runs ``onWillDeactivate``,
    /// whatever kind takes this viewer's place.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        controller?.clearClassifierAlignmentEvidence()
        onWillDeactivate?()
    }

    /// Adopts the controller the App passed as `input`.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller = try expectInput(input, as: EsVirituResultViewController.self)
    }
}
