// VCFDatasetSurface.swift - The VCF dataset dashboard as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit

/// The VCF dataset dashboard as a ``ResultViewport``. It lives in the App because its controller does.
///
/// The display builds the controller, wires its download callback and passes it in ``Input`` with the summary and
/// variants a caller has already read. ``load(input:token:)`` configures the controller and does not suspend, so the
/// host installs the dashboard before `show` returns. The dashboard holds a filter, a sort and a selection in memory
/// and saves nothing, so there is nothing to stop or save when the host removes it.
@MainActor
final class VCFDatasetSurface: ResultViewport {
    /// What the display passes as `input`.
    struct Input {
        /// The dashboard to configure. It reaches ``controller`` only when the load succeeds.
        let controller: VCFDatasetViewController
        let summary: LungfishIO.VCFSummary
        let variants: [LungfishIO.VCFVariant]
    }

    /// The dashboard the host installs, once the load has configured it.
    private(set) var controller: VCFDatasetViewController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    var viewController: NSViewController { controller ?? unloaded }

    var surfaceKind: SurfaceKind { .view(.vcfDataset) }

    /// The dashboard's summary bar sits at the top of its own view, so it starts below the window's toolbar. The
    /// old display pinned it to the safe area, and the host's edge pin would put it under the toolbar.
    var pinsTopToSafeArea: Bool { true }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        request.controller.configure(summary: request.summary, variants: request.variants)
        controller = request.controller
    }
}
