// MainSplitViewController.swift - Three-panel split view controller
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for main split view operations
internal let mainSplitLogger = Logger(subsystem: LogSubsystem.app, category: "MainSplitViewController")

/// Dispatches a @MainActor block on the GCD main queue using assumeIsolated.
/// Needed in Task.detached contexts where cooperative executor scheduling is unreliable.
internal func mainSplitPerformOnMainRunLoop(_ block: @escaping @MainActor @Sendable () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            block()
        }
    }
}

extension FASTQOperationLaunchRequest {
    var primaryInputURL: URL? {
        switch self {
        case .refreshQCSummary(let inputURLs):
            return inputURLs.first
        case .derivative(_, let inputURLs, _):
            return inputURLs.first
        case .ontFluidigmSampleSplit(let inputFASTQURL, _, _),
             .ontPacBioBarcodeDemux(let inputFASTQURL, _, _, _, _, _):
            return inputFASTQURL
        case .map(let inputURLs, _, _):
            return inputURLs.first
        case .assemble(let request, _):
            return request.inputURLs.first
        case .classify(_, let inputURLs, _, _):
            return inputURLs.first
        case .pbaa(let request):
            return request.inputFASTQURL
        case .ontGenotyping(let request):
            return request.inputFASTQURL
        }
    }

    var outputMode: FASTQOperationOutputMode {
        switch self {
        case .refreshQCSummary:
            return .fixedBatch
        case .derivative(_, _, let outputMode):
            return outputMode
        case .ontFluidigmSampleSplit, .ontPacBioBarcodeDemux:
            return .fixedBatch
        case .map(_, _, let outputMode):
            return outputMode
        case .assemble(_, let outputMode):
            return outputMode
        case .classify:
            return .fixedBatch
        case .pbaa:
            return .perInput
        case .ontGenotyping:
            return .fixedBatch
        }
    }

    var isDemultiplexRequest: Bool {
        if case .derivative(let request, _, _) = self, case .demultiplex = request {
            return true
        }
        if case .ontFluidigmSampleSplit = self {
            return true
        }
        if case .ontPacBioBarcodeDemux = self {
            return true
        }
        return false
    }

    var operationDisplayTitle: String {
        switch self {
        case .refreshQCSummary:
            return "FASTQ QC Summary"
        case .derivative(let request, _, _):
            return request.operationLabel
        case .ontFluidigmSampleSplit:
            return "ONT Fluidigm Sample Split"
        case .ontPacBioBarcodeDemux:
            return "ONT PacBio Barcode Demultiplex"
        case .map:
            return "Map Reads"
        case .assemble(let request, _):
            return request.tool.displayName
        case .classify(let tool, _, _, _):
            return tool.title
        case .pbaa:
            return "pbAA Amplicon Clustering"
        case .ontGenotyping:
            return "miSeq amplicon ONT MHC genotyping"
        }
    }
}

/// Options for handling duplicate files during import
enum DuplicateResolution {
    case replace    // Replace the existing file
    case keepBoth   // Keep both files (rename the new one)
    case skip       // Skip importing, use existing file
}

/// The main split view controller managing sidebar, viewer, and inspector panels.
///
/// Layout:
/// ```
/// +------------+----------------------------+----------+
/// |  Sidebar   |         Viewer             | Inspector|
/// |  (toggle)  |    (always visible)        | (toggle) |
/// +------------+----------------------------+----------+
/// |            Activity Indicator Bar                   |
/// +-----------------------------------------------------+
/// ```
@MainActor
public class MainSplitViewController: NSSplitViewController {
    nonisolated static let legacyShellAutosaveName = "MainSplitView"
    nonisolated static let sidebarCollapsedDefaultsKey = "SidebarCollapsed"
    nonisolated static let inspectorCollapsedDefaultsKey = "InspectorCollapsed"
    nonisolated static let sidebarWidthDefaultsKey = "WorkspaceShellSidebarWidth"
    nonisolated static let inspectorWidthDefaultsKey = "WorkspaceShellInspectorWidth"

    // MARK: - Child View Controllers

    /// The sidebar panel (project/file navigation)
    public private(set) var sidebarController: SidebarViewController!

    /// The main viewer panel (sequence/tracks)
    public private(set) var viewerController: ViewerViewController!

    /// The inspector panel (selection details)
    public private(set) var inspectorController: InspectorViewController!

    /// The shared activity indicator for showing progress across the app
    public private(set) var activityIndicator: ActivityIndicatorView!

    /// Window-owned project/session state.
    public private(set) var projectSession: ProjectSession

    var onProjectOpenWarningStateChanged: ((ProjectOpenWarningState) -> Void)?

    // MARK: - Split View Items

    var sidebarItem: NSSplitViewItem!
    var viewerItem: NSSplitViewItem!
    var inspectorItem: NSSplitViewItem!
    var sidebarWidthConstraint: NSLayoutConstraint?
    var inspectorWidthConstraint: NSLayoutConstraint?
    var sidebarContainerView: NSView? { sidebarController?.view.superview }
    var viewerContainerView: NSView? { viewerController?.view.superview }
    var inspectorContainerView: NSView? { inspectorController?.view.superview }

    // MARK: - Inspector Toggle State

    /// True while an inspector collapse/expand animation is in progress.
    var inspectorTransitionInFlight = false

    /// Queued collapsed state requested while an animation is running.
    var queuedInspectorCollapsedState: Bool?

    /// Monotonic serial for guarding completion/fallback callbacks.
    var inspectorTransitionSerial: Int = 0

    /// Uptime timestamp when the current inspector transition began.
    var inspectorTransitionStartTime: TimeInterval = 0

    /// Collapsed target for the active inspector transition.
    var inspectorTransitionTargetCollapsedState: Bool?

    /// True once the initial persisted shell widths have been re-applied after layout.
    var hasAppliedInitialShellLayout = false

    // MARK: - Selection State

    /// Monotonic generation counter for sidebar selection changes.
    ///
    /// Incremented every time a new sidebar item is selected. Background tasks
    /// capture this value and check it before updating the UI, discarding stale
    /// results when the user has moved on to a different selection.
    var selectionGeneration: Int = 0

    /// Debounce work item for rapid sidebar selection changes.
    ///
    /// When the user clicks quickly through sidebar items (< 150ms between clicks),
    /// only the final selection is processed. This prevents unnecessary background
    /// loads and reduces main thread contention during rapid browsing.
    var selectionDebounceWorkItem: DispatchWorkItem?

    /// Background task for multi-selection document loading.
    ///
    /// Cancelled whenever the selection moves on so stale collection loads
    /// cannot repaint the viewport after a tool result is displayed.
    var multiDocumentLoadTask: Task<Void, Never>?

    var windowStateScope: WindowStateScope {
        projectSession.windowStateScope
    }
    var operationRouteContext: OperationRouteContext {
        OperationRouteContext(
            projectURL: projectSession.projectURL ?? sidebarController.currentProjectURL,
            windowStateScope: windowStateScope
        )
    }
    var activeContentSelectionIdentity: ContentSelectionIdentity?
    var displayRequestGate = AsyncRequestGate<ContentSelectionIdentity>()

    // MARK: - FASTQ Loading State

    /// Background task for FASTQ statistics/sample loading.
    ///
    /// Cancelled whenever selection changes away from FASTQ content so stale
    /// progress updates cannot overwrite the active view.
    var fastqLoadTask: Task<Void, Never>?

    /// Monotonic generation used to discard stale async FASTQ updates.
    var fastqLoadGeneration: Int = 0

    /// FASTQ URL currently targeted by the active background load.
    var activeFASTQLoadURL: URL?
    /// Original selected FASTQ source URL (bundle or raw FASTQ path).
    var activeFASTQSourceURL: URL?

    // MARK: - Configuration

    /// Minimum sidebar width
    let sidebarMinWidth: CGFloat = 180
    /// Default sidebar width
    let sidebarDefaultWidth: CGFloat = 240
    /// Maximum sidebar width
    let sidebarMaxWidth: CGFloat = 720

    /// Minimum inspector width
    let inspectorMinWidth: CGFloat = 260
    /// Default inspector width
    let inspectorDefaultWidth: CGFloat = 340
    /// Maximum inspector width
    let inspectorMaxWidth: CGFloat = 720

    /// Minimum viewer width
    let viewerMinWidth: CGFloat = 400

    var pendingShellResizeEvent: WorkspaceShellLayoutCoordinator.Event = .shellDidResize
    var isApplyingProgrammaticShellDividerMove = false
    var programmaticShellResizeSuppressionDepth = 0
    var pendingSidebarRevealRestore = false
    var pendingInspectorRevealRestore = false
    var pendingSidebarRevealWidth: CGFloat?
    var pendingInspectorRevealWidth: CGFloat?
    var lastObservedShellContentWidth: CGFloat?

    lazy var shellLayoutCoordinator = WorkspaceShellLayoutCoordinator(
        sidebarMinWidth: sidebarMinWidth,
        sidebarMaxWidth: sidebarMaxWidth,
        inspectorMinWidth: inspectorMinWidth,
        inspectorMaxWidth: inspectorMaxWidth,
        viewerMinWidth: viewerMinWidth
    )

    /// Tracks sidebar width recommendations versus explicit user drags.
    let sidebarWidthCoordinator = SplitShellWidthCoordinator()

    // MARK: - Initialization

    public init(projectSession: ProjectSession = ProjectSession()) {
        self.projectSession = projectSession
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MainSplitViewController does not support storyboard initialization")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        mainSplitLogger.info("viewDidLoad: MainSplitViewController loading")
        configureSplitView()
        configureChildControllers()
        configureActivityIndicator()
        configureNotifications()
        restorePanelState()
        // One-time migration: clear stale split view autosave from broken TARIC configuration
        let autosaveMigrationKey = "com.lungfish.splitview.autosave.v2.migrated"
        if !UserDefaults.standard.bool(forKey: autosaveMigrationKey) {
            UserDefaults.standard.removeObject(
                forKey: "NSSplitView Subview Frames \(Self.legacyShellAutosaveName)"
            )
            UserDefaults.standard.set(true, forKey: autosaveMigrationKey)
        }

        mainSplitLogger.info("viewDidLoad: MainSplitViewController setup complete")
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        guard !hasAppliedInitialShellLayout else { return }
        hasAppliedInitialShellLayout = true
        mainSplitPerformOnMainRunLoop { [weak self] in
            self?.restorePersistedShellLayout()
        }
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        invalidatePendingSelectionDebounce(reason: "controller teardown")
        cancelMultiDocumentLoadIfNeeded(hideProgress: false, reason: "controller teardown")
        cancelFASTQLoadIfNeeded(hideProgress: false, reason: "controller teardown")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Configuration

    func configureSplitView() {
        // Use thin dividers for modern look
        splitView.dividerStyle = .thin

        // Vertical splits (side by side)
        splitView.isVertical = true

        // Shell widths are user-owned and persisted explicitly rather than via NSSplitView autosave.
        splitView.autosaveName = nil
    }

    func configureActivityIndicator() {
        // Floating activity indicator positioned above the bottom of the viewer area.
        // Uses z-order above split view content to avoid NSSplitView clipping on macOS 26.
        activityIndicator = ActivityIndicatorView()
        view.addSubview(activityIndicator, positioned: .above, relativeTo: nil)

        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -40),
            activityIndicator.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
            activityIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])

        mainSplitLogger.info("configureActivityIndicator: Activity indicator configured")
    }

    func configureChildControllers() {
        // Create child view controllers
        sidebarController = SidebarViewController()
        viewerController = ViewerViewController()
        inspectorController = InspectorViewController()
        viewerController.windowStateScope = windowStateScope
        _ = inspectorController.view
        let sidebarView = sidebarController.view
        sidebarView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sidebarView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mainSplitLogger.info("configureChildControllers: Created all three view controllers")

        // Set up delegate for direct selection handling (avoids async Task issues)
        sidebarController.selectionDelegate = self
        sidebarController.windowStateScope = windowStateScope
        inspectorController.windowStateScope = windowStateScope

        // Create split view items with appropriate behaviors

        // Sidebar: collapsible, sidebar behavior for vibrancy
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = sidebarMinWidth
        sidebarItem.maximumThickness = sidebarMaxWidth
        sidebarItem.preferredThicknessFraction = 0.15
        sidebarItem.holdingPriority = .defaultLow + 1
        sidebarItem.collapseBehavior = .preferResizingSplitViewWithFixedSiblings

        // Viewer: always visible, takes remaining space
        viewerItem = NSSplitViewItem(viewController: viewerController)
        viewerItem.canCollapse = false
        viewerItem.minimumThickness = viewerMinWidth
        viewerItem.holdingPriority = .defaultLow

        // Inspector: collapsible trailing panel with the same user-owned resize
        // semantics as the project sidebar.
        inspectorItem = NSSplitViewItem(viewController: inspectorController)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = inspectorMinWidth
        inspectorItem.maximumThickness = inspectorMaxWidth
        inspectorItem.preferredThicknessFraction = 0.2
        inspectorItem.holdingPriority = .defaultLow + 1
        inspectorItem.collapseBehavior = .default

        // Add items in order: sidebar, viewer, inspector
        addSplitViewItem(sidebarItem)
        addSplitViewItem(viewerItem)
        addSplitViewItem(inspectorItem)
        sidebarWidthCoordinator.noteObservedWidth(sidebarDefaultWidth)
        mainSplitLogger.info("configureChildControllers: Added all three split view items, count=\(self.splitViewItems.count)")

        ensureShellWidthConstraints()

        // Inspector starts visible by default
        inspectorItem.isCollapsed = false
        mainSplitLogger.info("configureChildControllers: Inspector initial state isCollapsed=\(self.inspectorItem.isCollapsed)")
    }

    func configureNotifications() {
        // Listen for sidebar selection changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarSelectionChanged(_:)),
            name: .sidebarSelectionChanged,
            object: nil
        )

        // Listen for document loaded notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDocumentLoaded(_:)),
            name: DocumentManager.documentLoadedNotification,
            object: nil
        )

        // Listen for project opened notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProjectOpened(_:)),
            name: DocumentManager.projectOpenedNotification,
            object: nil
        )

        // Listen for show inspector requests (e.g., from edit annotation action)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInspector(_:)),
            name: .showInspectorRequested,
            object: nil
        )

        // Listen for file drops on the sidebar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarFileDropped(_:)),
            name: .sidebarFileDropped,
            object: nil
        )

        // Listen for sidebar width recommendations based on current filename lengths.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSidebarPreferredWidthRecommended(_:)),
            name: .sidebarPreferredWidthRecommended,
            object: nil
        )

        // Show inspector when a reference bundle is loaded
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleDidLoad(_:)),
            name: .bundleDidLoad,
            object: nil
        )

        // Show inspector with chromosome details when requested from chromosome navigator
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromosomeInspectorRequested(_:)),
            name: .chromosomeInspectorRequested,
            object: nil
        )

        mainSplitLogger.info("configureNotifications: Registered for sidebar, document, file drop, bundle, inspector, and chromosome inspector notifications")
        mainSplitLogger.info("configureNotifications: sidebarFileDropped observer registered for name '\(Notification.Name.sidebarFileDropped.rawValue)'")
    }

    @objc func handleShowInspector(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let tab = notification.userInfo?[NotificationUserInfoKey.inspectorTab] as? String
        mainSplitLogger.info("handleShowInspector: Showing inspector panel, tab=\(tab ?? "default", privacy: .public)")
        setInspectorVisible(true, animated: false, source: "notification.showInspectorRequested")
        // Tab switching is handled by InspectorViewController observing the same notification
    }

    func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        return notificationScope == windowStateScope
    }

    @objc func handleBundleDidLoad(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        mainSplitLogger.info("handleBundleDidLoad: Bundle loaded, ensuring inspector is visible")
        setInspectorVisible(true, animated: false, source: "notification.bundleDidLoad")
    }

    @objc func handleChromosomeInspectorRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        mainSplitLogger.info("handleChromosomeInspectorRequested: Showing inspector for chromosome")
        setInspectorVisible(true, animated: false, source: "notification.chromosomeInspectorRequested")
        // Chromosome details are handled by InspectorViewController observing the same notification
    }

    @objc func handleSidebarSelectionChanged(_ notification: Notification) {
        // NOTE: Document loading is now handled by SidebarSelectionDelegate (sidebarDidSelectItem).
        // This notification handler is kept only for other observers (e.g., InspectorViewController)
        // that may need to know about selection changes but don't load documents.
        //
        // DO NOT add document loading code here - it will cause Swift Task execution issues.
        // See SWIFT-CONCURRENCY-APPKIT-MODAL.md for details.

        mainSplitLogger.debug("handleSidebarSelectionChanged: Notification received (delegate handles loading)")
    }
}
