// FASTQDatasetSurface.swift - The FASTQ dataset dashboard as a ViewportHost surface
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

/// Why a FASTQ dataset did not open, in words a person can act on.
enum FASTQDatasetOpenError: LocalizedError {
    case gone(fileName: String)
    case locked(fileName: String)

    var errorDescription: String? {
        switch self {
        case .gone(let fileName): "\(fileName) is no longer where it was saved."
        case .locked(let fileName): "This Mac does not allow \(fileName) to be read."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .gone: "Check that the file is still in the project folder and that its drive is connected, then select it again."
        case .locked: "Check the file's permissions in Finder, then select it again."
        }
    }

    /// Asks the file system whether the file is there and can be read. It opens nothing and reads no reads, so its cost
    /// on the main actor is the `stat` the route already makes.
    static func check(_ fileURL: URL) throws {
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path) else { throw gone(fileName: fileURL.lastPathComponent) }
        guard files.isReadableFile(atPath: fileURL.path) else { throw locked(fileName: fileURL.lastPathComponent) }
    }
}

/// What the host installs for a FASTQ dashboard. The host pins this controller's view on all four sides and gives no
/// handle to its bottom pin, and the metadata drawer shrinks the dashboard by moving the dashboard's bottom. So this
/// controller holds the dashboard as its one child and owns that constraint.
@MainActor
final class FASTQDatasetContainerController: NSViewController {
    let dashboard: FASTQDatasetViewController
    private var dashboardBottom: NSLayoutConstraint?

    init(dashboard: FASTQDatasetViewController) {
        self.dashboard = dashboard
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        view = NSView()
        addChild(dashboard)
        let dashboardView = dashboard.view
        dashboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dashboardView)
        let bottom = dashboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            dashboardView.topAnchor.constraint(equalTo: view.topAnchor),
            dashboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dashboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
        ])
        dashboardBottom = bottom
    }

    /// Ends the dashboard at `anchor`, which the viewer's drawer gives when it is first made. The drawer sits below
    /// the viewer's edge when closed, so its top is this view's bottom, and the dashboard fills the view.
    func endDashboard(at anchor: NSLayoutYAxisAnchor) {
        dashboardBottom?.isActive = false
        let bottom = dashboard.view.bottomAnchor.constraint(equalTo: anchor)
        bottom.isActive = true
        dashboardBottom = bottom
    }
}

/// The FASTQ dataset dashboard as a ``ResultViewport``. It lives in the App because its controller does.
///
/// The display builds the dashboard, wires its callbacks and passes it in ``Input``. ``load(input:token:)`` checks that
/// the person's file can be read and configures the dashboard, and it does not suspend, so the host installs it before
/// `show` returns. The drawer stays on the viewer, so this surface answers for it and takes it away on every removal.
@MainActor
final class FASTQDatasetSurface: ResultViewport {
    /// What the display passes as `input`.
    struct Input {
        /// The dashboard to configure. It reaches ``container`` only when the load succeeds.
        let dashboard: FASTQDatasetViewController
        let statistics: FASTQDatasetStatistics
        let records: [FASTQRecord]
        /// Nil for a virtual derived bundle, which has no file of its own to check.
        let fastqURL: URL?
        let sourceURL: URL?
        let derivativeManifest: FASTQDerivedBundleManifest?
    }

    private weak var viewer: ViewerViewController?

    /// The container the host installs, once the load has configured its dashboard.
    private(set) var container: FASTQDatasetContainerController?

    /// What `viewController` answers before a load, which the host never reads.
    private lazy var unloaded: NSViewController = {
        let empty = NSViewController()
        empty.view = NSView()
        return empty
    }()

    init(viewer: ViewerViewController?) {
        self.viewer = viewer
    }

    var viewController: NSViewController { container ?? unloaded }

    var surfaceKind: SurfaceKind { .bundle(.fastq) }

    /// The dashboard's summary bar sits at the top of its own view, so it starts below the window's toolbar. The old
    /// display pinned it to the safe area, and the host's edge pin would put it under the toolbar.
    var pinsTopToSafeArea: Bool { true }

    var isDrawerOpen: Bool { viewer?.isFASTQMetadataDrawerOpen ?? false }

    func toggleDrawer() {
        viewer?.toggleFASTQMetadataDrawer()
    }

    func load(input: Any, token: AsyncRequestToken<SurfaceRequest>) async throws {
        let request = try expectInput(input, as: Input.self)
        if let fastqURL = request.fastqURL { try FASTQDatasetOpenError.check(fastqURL) }
        let container = FASTQDatasetContainerController(dashboard: request.dashboard)
        // The dashboard's view is loaded before it is configured, as the old display had it.
        _ = container.view
        request.dashboard.configure(
            statistics: request.statistics,
            records: request.records,
            fastqURL: request.fastqURL,
            sourceURL: request.sourceURL,
            derivativeManifest: request.derivativeManifest
        )
        self.container = container
    }

    /// The drawer is a person's open pane over this dashboard, so it goes with it. An edit not saved in it goes too.
    func willDeactivate(replacedBy next: SurfaceKind?) {
        viewer?.releaseFASTQDashboardState()
    }
}
