// QuickLookPreviewSurface.swift - The preview of a file as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The preview of a file as a ``ResultViewport``. It lives in the App because its controller does.
///
/// The display builds the controller and passes it in ``Input``. ``load(input:token:)`` reads the person's file on the
/// main actor and does not suspend, so the host installs the preview before `show` returns, and a file that does not
/// read throws its own error. A Quick Look view can play a movie or a sound, so every removal closes it.
@MainActor
final class QuickLookPreviewSurface: ResultViewport {
    /// What the display passes as `input`.
    struct Input {
        /// The preview to fill. It reaches ``controller`` only when the file reads.
        let controller: QuickLookPreviewController
    }

    /// The preview the host installs, once the load has read its file.
    private(set) var controller: QuickLookPreviewController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }

    var surfaceKind: SurfaceKind { .view(.quickLook) }

    /// A preview has no toolbar space of its own, so it starts below the window's toolbar, as the old display did.
    var pinsTopToSafeArea: Bool { true }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        try request.controller.readFile()
        controller = request.controller
    }

    func willDeactivate(replacedBy next: SurfaceKind?) {
        controller?.closePreview()
    }
}
