// NaoMgsSurface.swift - The NAO-MGS result as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The NAO-MGS result viewer as a ``ResultViewport``.
///
/// Its input is the ``NaoMgsResultViewController`` the App has made and fills after the
/// show, in phases its own display request gates. The load adopts that controller and
/// does not suspend, so the host installs it before `show` returns. The App registers
/// ``factory()`` for `.analysis(.naomgs)`.
@MainActor
public final class NaoMgsSurface: ResultViewport {
    /// The result viewer the host installs, the one the load adopted.
    public private(set) var controller: NaoMgsResultViewController?

    /// Called whenever the host removes this viewer, so the App can take the NAO-MGS
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
        { NaoMgsSurface() }
    }

    public var viewController: NSViewController { controller ?? unloaded }

    public var surfaceKind: SurfaceKind { .analysis(.naomgs) }

    /// Runs ``onWillDeactivate``, whatever kind takes this viewer's place.
    public func willDeactivate(replacedBy next: SurfaceKind?) {
        onWillDeactivate?()
    }

    /// Adopts the controller the App passed as `input`.
    public func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller = try expectInput(input, as: NaoMgsResultViewController.self)
    }
}
