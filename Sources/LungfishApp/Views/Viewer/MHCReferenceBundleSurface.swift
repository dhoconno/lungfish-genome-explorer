// MHCReferenceBundleSurface.swift - The MHC amplicon reference viewer as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishIO
import LungfishKit

/// The MHC amplicon reference bundle viewer as a ``ResultViewport``. It has no leaf module, so
/// its factory stays in the App, registered in ViewerViewController+Surfaces.swift.
///
/// Its input is the hosting controller the display builds from the loaded model, with the
/// route's callbacks inside its root view. The load adopts that controller and does not
/// suspend, so the host installs it before `show` returns. The controller is the plain generic
/// hosting class on purpose, since the view-switch matrix names the viewer by that class.
@MainActor
final class MHCReferenceBundleSurface: ResultViewport {
    typealias Controller = NSHostingController<MHCReferenceBundleViewport>

    /// The viewer the host installs, the one the load adopted.
    private(set) var controller: Controller?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }

    var surfaceKind: SurfaceKind { .bundle(.mhcReference) }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        controller = try expectInput(input, as: Controller.self)
    }
}
