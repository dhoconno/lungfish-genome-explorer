// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Combine
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log
import UniformTypeIdentifiers

/// Logger for inspector operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "InspectorViewController")

struct InspectorWorkflowAlert: Equatable {
    let title: String
    let message: String
}

enum FilteredAlignmentWorkflowReloadTarget: Equatable {
    case mappingViewer
    case bundleViewer

    var failureAlertTitle: String {
        switch self {
        case .mappingViewer:
            return "Mapping Viewer Reload Failed"
        case .bundleViewer:
            return "Reload Failed"
        }
    }
}

struct FilteredAlignmentWorkflowReloadActions {
    let reloadMappingViewerBundle: () throws -> Void
    let displayBundle: (URL) throws -> Void
}

struct FilteredAlignmentWorkflowLaunchContext: Equatable {
    let bundleURL: URL
    let serviceTarget: AlignmentFilterTarget
    let reloadTarget: FilteredAlignmentWorkflowReloadTarget

    var reloadFailureAlertTitle: String {
        reloadTarget.failureAlertTitle
    }

    func reload(using actions: FilteredAlignmentWorkflowReloadActions) throws {
        switch reloadTarget {
        case .mappingViewer:
            try actions.reloadMappingViewerBundle()
        case .bundleViewer:
            try actions.displayBundle(bundleURL)
        }
    }
}

enum FilteredAlignmentWorkflowStartOutcome: Equatable {
    case launch(FilteredAlignmentWorkflowLaunchContext)
    case blocked(InspectorWorkflowAlert)
}

// MARK: - InspectorTab

/// Tab selection for the inspector panel's segmented control.
///
/// The inspector supports multiple tabs whose availability varies by
/// ``ViewportContentMode``. The ``InspectorViewModel/availableTabs``
/// computed property returns only the tabs relevant to the current mode.
enum InspectorTab: String, CaseIterable {
    /// Bundle metadata and source information.
    case bundle = "document"
    /// Selected object details.
    case selectedItem = "selection"
    /// Reversible view and layout settings.
    case view
    /// Durable output-creating workflows.
    case analysis = "derive"
    /// Embedded AI assistant (genomics mode).
    case ai
    /// FASTQ sample metadata editing (FASTQ mode).
    case fastqMetadata
    /// Metagenomics result summary (metagenomics mode).
    case resultSummary
}

/// Controller for the inspector panel showing selection details.
///
/// Uses SwiftUI via NSHostingView for modern, declarative UI.
/// Integrates with the annotation system to display and edit selected annotations.
///
/// Note: Document loading is handled exclusively by MainSplitViewController.
/// This controller only updates its UI state in response to sidebar selection changes.
@MainActor
public class InspectorViewController: NSViewController {

    // MARK: - Properties

    /// The SwiftUI hosting view
    private var hostingView: NSHostingView<InspectorView>!

    /// View model for the inspector.
    /// Internal (not private) to allow @testable test access.
    var viewModel = InspectorViewModel()

    /// Public access to the selection section view model for wiring enrichment data.
    public var selectionSectionViewModel: SelectionSectionViewModel {
        viewModel.selectionSectionViewModel
    }

    /// Public access to the annotation section view model for wiring variant types.
    public var annotationSectionViewModel: AnnotationSectionViewModel {
        viewModel.annotationSectionViewModel
    }

    /// Public access to the variant section view model for wiring variant detail.
    public var variantSectionViewModel: VariantSectionViewModel {
        viewModel.variantSectionViewModel
    }

    /// Public access to the sample section view model for wiring sample data.
    public var sampleSectionViewModel: SampleSectionViewModel {
        viewModel.sampleSectionViewModel
    }

    /// Public access to the read style section view model for wiring alignment data.
    public var readStyleSectionViewModel: ReadStyleSectionViewModel {
        viewModel.readStyleSectionViewModel
    }

    /// Public access to the FASTQ metadata section view model.
    public var fastqMetadataSectionViewModel: FASTQMetadataSectionViewModel {
        viewModel.fastqMetadataSectionViewModel
    }

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Prevents duplicate NotificationCenter observer registration.
    private var hasRegisteredNotificationObservers = false

    /// Tracks last split-view visibility reported by MainSplitViewController.
    private var wasInspectorVisible = true

    var windowStateScope: WindowStateScope? {
        didSet {
            viewModel.windowStateScope = windowStateScope
        }
    }
    private var activeContentSelectionIdentity: ContentSelectionIdentity?

    // MARK: - Lifecycle

    public override func loadView() {
        let inspectorView = InspectorView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: inspectorView)
        // Give an initial frame so split view has something to work with
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        ensureInspectorWiring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetadataImportRequested),
            name: .metagenomicsMetadataImportRequested,
            object: nil
        )
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        logger.info("viewWillAppear: Inspector view appearing")
        wasInspectorVisible = true
        ensureInspectorWiring()
        syncAnnotationStateToViewer()
    }

    // MARK: - Hosting View Refresh

    /// Forces SwiftUI to re-establish @Bindable observation tracking after the
    /// inspector is uncollapsed from an NSSplitViewItem hide/show cycle.
    ///
    /// When the inspector's NSSplitViewItem is collapsed, the @Bindable wrappers
    /// in section views (AppearanceSection, AnnotationSection, etc.) can lose
    /// their two-way binding connections to @Observable view models. Reassigning
    /// rootView creates a fresh SwiftUI view tree that re-binds to the same
    /// view model instances, restoring slider/toggle/picker interactivity.
    public func refreshHostingView() {
        hostingView.rootView = InspectorView(viewModel: viewModel)
    }

    var testingWindowStateScope: WindowStateScope? {
        get { windowStateScope }
        set { windowStateScope = newValue }
    }

    func testingHandleSidebarSelectionChanged(_ notification: Notification) {
        selectionDidChange(notification)
    }

    func testingHandleBatchManifestCached(_ notification: Notification) {
        handleBatchManifestCached(notification)
    }

    // MARK: - Setup

    /// Sets up notification observers for annotation and appearance changes.
    private func setupNotificationObservers() {
        guard !hasRegisteredNotificationObservers else { return }

        // Listen for sidebar selection changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: .sidebarSelectionChanged,
            object: nil
        )

        // Listen for annotation selection from viewer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAnnotationSelected(_:)),
            name: .annotationSelected,
            object: nil
        )

        // Listen for explicit variant selections that include track/row identity.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVariantSelected(_:)),
            name: .variantSelected,
            object: nil
        )

        // Listen for read selections from viewer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReadSelected(_:)),
            name: .readSelected,
            object: nil
        )

        // Listen for bundle loads to update Document tab
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBundleDidLoad(_:)),
            name: .bundleDidLoad,
            object: nil
        )

        // Listen for explicit inspector show requests with tab targeting.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowInspectorRequested(_:)),
            name: .showInspectorRequested,
            object: nil
        )

        // Listen for chromosome inspector requests from the navigator context menu.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleChromosomeInspectorRequested(_:)),
            name: .chromosomeInspectorRequested,
            object: nil
        )

        // Listen for FASTQ dataset loaded to show statistics in Document tab.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFASTQDatasetLoaded(_:)),
            name: .fastqDatasetLoaded,
            object: nil
        )

        // Listen for viewport content mode changes to adapt inspector tabs/sections.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentModeChanged(_:)),
            name: .viewportContentModeDidChange,
            object: nil
        )

        // Listen for batch manifest saved — transitions the status indicator from .building to .cached.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBatchManifestCached(_:)),
            name: .batchManifestCached,
            object: nil
        )

        hasRegisteredNotificationObservers = true
    }

    /// Sets up callbacks for view model section changes.
    private func setupViewModelCallbacks() {
        // Selection section callbacks
        viewModel.selectionSectionViewModel.onAnnotationUpdated = { [weak self] annotation in
            self?.handleAnnotationUpdatedFromInspector(annotation)
        }

        viewModel.selectionSectionViewModel.onAnnotationDeleted = { [weak self] annotationID in
            self?.handleAnnotationDeletedFromInspector(annotationID)
        }

        viewModel.selectionSectionViewModel.onApplyColorToAllOfType = { [weak self] annotationType, color in
            self?.handleApplyColorToAllOfType(annotationType, color: color)
        }
        viewModel.selectionSectionViewModel.onAddAnnotationRequested = { [weak self] in
            self?.handleAddAnnotationRequested()
        }
        viewModel.selectionSectionViewModel.onShowTranslation = { [weak self] annotation in
            self?.handleShowTranslationRequested(annotation)
        }
        viewModel.selectionSectionViewModel.onExtractSequence = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .extractSequenceRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onCopyAsFASTA = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationAsFASTARequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onCopyTranslationAsFASTA = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .copyTranslationAsFASTARequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onCopySequence = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationSequenceRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onCopyReverseComplement = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationReverseComplementRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onRunFASTAOperation = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .runFASTAOperationOnAnnotationRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }
        viewModel.selectionSectionViewModel.onZoomToAnnotation = { [weak self] annotation in
            NotificationCenter.default.post(
                name: .zoomToAnnotationRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }

        // Appearance section callbacks
        viewModel.appearanceSectionViewModel.onSettingsChanged = { [weak self] in
            self?.handleAppearanceChanged()
        }

        // Appearance section reset callback - coordinates resetting ALL appearance settings
        viewModel.appearanceSectionViewModel.onResetToDefaults = { [weak self] in
            self?.resetAllAppearanceSettings()
        }

        // Quality section callbacks
        viewModel.qualitySectionViewModel.onOverlayToggleChanged = { [weak self] enabled in
            self?.handleQualityOverlayToggled(enabled)
        }

        // Variant section callbacks
        viewModel.variantSectionViewModel.onZoomToVariant = { [weak self] variant in
            // Create a SequenceAnnotation from the variant for zoom navigation
            let annotation = SequenceAnnotation(
                type: .snp,
                name: variant.name,
                chromosome: variant.chromosome,
                start: variant.start,
                end: variant.end,
                strand: .unknown
            )
            NotificationCenter.default.post(
                name: .zoomToAnnotationRequested,
                object: nil,
                userInfo: self?.windowScopedUserInfo([NotificationUserInfoKey.annotation: annotation])
            )
        }

        viewModel.variantSectionViewModel.onCopyVariantInfo = { info in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }

        // Sample section callbacks
        viewModel.sampleSectionViewModel.onDisplayStateChanged = { [weak self] state in
            self?.handleSampleDisplayStateChanged(state)
        }

        // Annotation section callbacks
        viewModel.annotationSectionViewModel.onSettingsChanged = { [weak self] in
            self?.handleAnnotationSettingsChanged()
        }

        viewModel.annotationSectionViewModel.onFilterChanged = { [weak self] visibleTypes, filterText in
            self?.handleAnnotationFilterChanged(visibleTypes: visibleTypes, filterText: filterText)
        }
    }

    /// Ensures notification observers and section callbacks are bound.
    ///
    /// Rebinding callbacks on appearance keeps inspector controls active across
    /// inspector show/hide and view lifecycle transitions.
    private func ensureInspectorWiring() {
        setupNotificationObservers()
        setupViewModelCallbacks()
        logger.debug(
            "ensureInspectorWiring: callbacks settings=\(self.viewModel.annotationSectionViewModel.onSettingsChanged == nil ? "nil" : "set", privacy: .public) filter=\(self.viewModel.annotationSectionViewModel.onFilterChanged == nil ? "nil" : "set", privacy: .public)"
        )
    }

    /// Broadcasts current annotation inspector state to viewers.
    ///
    /// Keeps viewer rendering synchronized when switching content and when the
    /// inspector panel is re-shown.
    private func syncAnnotationStateToViewer() {
        handleAnnotationSettingsChanged()
        handleAnnotationFilterChanged(
            visibleTypes: viewModel.annotationSectionViewModel.visibleTypes,
            filterText: viewModel.annotationSectionViewModel.filterText
        )
    }

    /// Handles annotation display settings changes.
    private func handleAnnotationSettingsChanged() {
        logger.info("handleAnnotationSettingsChanged: Annotation settings changed")

        // Notify viewers to update annotation display
        NotificationCenter.default.post(
            name: .annotationSettingsChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "showAnnotations": viewModel.annotationSectionViewModel.showAnnotations,
                "annotationHeight": viewModel.annotationSectionViewModel.annotationHeight,
                "annotationSpacing": viewModel.annotationSectionViewModel.annotationSpacing
            ])
        )
    }

    /// Handles annotation filter changes.
    private func handleAnnotationFilterChanged(visibleTypes: Set<AnnotationType>, filterText: String) {
        logger.info("handleAnnotationFilterChanged: Filter updated - types=\(visibleTypes.count) text='\(filterText, privacy: .public)'")

        // Notify viewers to update annotation filtering
        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "visibleTypes": visibleTypes,
                "filterText": filterText
            ])
        )
    }

    // MARK: - Notification Handlers

    /// Handles sidebar selection changes to update inspector UI state.
    ///
    /// Note: This method only updates the inspector's display state (selected item name/type).
    /// Document loading is handled exclusively by MainSplitViewController to avoid race conditions
    /// where both controllers attempt to load the same document concurrently.
    @objc private func selectionDidChange(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }

        // Handle empty selection (items array is empty, no "item" key)
        if let items = notification.userInfo?["items"] as? [SidebarItem], items.isEmpty {
            activeContentSelectionIdentity = nil
            clearTransientSelectionState()
            return
        }

        guard let item = notification.userInfo?["item"] as? SidebarItem else { return }
        activeContentSelectionIdentity = notification.userInfo?[NotificationUserInfoKey.contentSelectionIdentity]
            as? ContentSelectionIdentity

        // Update UI state only - document loading is handled by MainSplitViewController
        viewModel.selectedItem = item.title
        viewModel.selectedType = item.type.description

        if item.type == .sequence || item.type == .annotation || item.type == .alignment || item.type == .referenceBundle {
            syncAnnotationStateToViewer()
        }

        logger.debug("selectionDidChange: Updated inspector state for '\(item.title, privacy: .public)' type=\(item.type.description, privacy: .public)")
    }

    /// Clears all selection state in the inspector, resetting it to "No Selection".
    ///
    /// Called when the sidebar selection is emptied (clicking empty space, deselecting).
    /// Resets the sidebar item display, annotation selection, variant details, document
    /// metadata, and read selection to their default empty states.
    private func clearTransientSelectionState() {
        activeContentSelectionIdentity = nil
        // Clear sidebar selection display
        viewModel.selectedItem = nil
        viewModel.selectedType = nil

        // Clear annotation selection
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(annotation: nil)

        // Clear variant details
        viewModel.variantSectionViewModel.clear()

        // Clear read selection
        viewModel.readStyleSectionViewModel.selectedRead = nil
    }

    public func clearSelection() {
        logger.info("clearSelection: Resetting inspector to empty state")

        clearTransientSelectionState()
        viewModel.selectionSectionViewModel.referenceBundle = nil
        viewModel.readStyleSectionViewModel.clear()
        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = nil
        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = nil
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil

        // Clear document section (bundle metadata, FASTQ stats, etc.)
        viewModel.documentSectionViewModel.update(manifest: nil, bundleURL: nil)
        viewModel.documentSectionViewModel.fastqStatistics = nil
        viewModel.documentSectionViewModel.sraRunInfo = nil
        viewModel.documentSectionViewModel.enaReadRecord = nil
        viewModel.documentSectionViewModel.ingestionMetadata = nil
        viewModel.documentSectionViewModel.fastqDerivativeManifest = nil
        viewModel.documentSectionViewModel.analysisManifestEntries = []
        viewModel.documentSectionViewModel.updateMappingDocument(nil)
        viewModel.documentSectionViewModel.updateAssemblyDocument(nil)
        viewModel.documentSectionViewModel.navigateToSourceData = nil

        // Clear sample section
        viewModel.sampleSectionViewModel.clear()

        // Clear FASTQ metadata section
        viewModel.fastqMetadataSectionViewModel.clear()

        logger.info("clearSelection: Inspector reset to empty state")
    }

    /// Handles annotation selection from the viewer.
    ///
    /// Updates the selection section with the newly selected annotation.
    /// Passing nil in userInfo clears the selection.
    @objc private func handleAnnotationSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let selectedAnnotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation

        // Translation track persists across annotation selection changes.
        // The inspector button state resets in SelectionSectionViewModel.select(),
        // but we do NOT post a hide-translation notification to the viewer.
        // The user must explicitly hide the translation via the inspector button.

        if let annotation = selectedAnnotation {
            viewModel.selectedAnnotation = annotation
            viewModel.selectionSectionViewModel.select(annotation: annotation)
            if annotation.type != .snp && annotation.type != .insertion && annotation.type != .deletion && annotation.type != .variation {
                viewModel.variantSectionViewModel.clear()
            }
            // Auto-switch to Selected Item when an annotation is selected.
            viewModel.selectedTab = .selectedItem
        } else {
            // Deselection - clear the annotation
            viewModel.selectedAnnotation = nil
            viewModel.selectionSectionViewModel.select(annotation: nil)
            viewModel.variantSectionViewModel.clear()
            applyInspectorTabSelection(from: notification)
        }
    }

    /// Handles variant selection notifications carrying row/track identity.
    @objc private func handleVariantSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let result = notification.userInfo?[NotificationUserInfoKey.searchResult] as? AnnotationSearchIndex.SearchResult else {
            viewModel.variantSectionViewModel.clear()
            return
        }
        viewModel.variantSectionViewModel.select(variant: result)
        viewModel.selectedTab = .selectedItem
    }

    /// Handles read selection from the viewer.
    @objc private func handleReadSelected(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let read = notification.userInfo?[NotificationUserInfoKey.alignedRead] as? AlignedRead
        viewModel.readStyleSectionViewModel.selectedRead = read
        if read != nil {
            viewModel.selectedTab = .selectedItem
        }
    }

    /// Handles bundle load notifications to update the Document tab.
    ///
    /// Extracts the manifest and bundle URL from the notification's userInfo
    /// and updates the document section view model.
    @objc private func handleBundleDidLoad(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let userInfo = notification.userInfo else { return }

        let bundleURL = userInfo[NotificationUserInfoKey.bundleURL] as? URL
        let manifest = userInfo[NotificationUserInfoKey.manifest] as? BundleManifest

        logger.info("handleBundleDidLoad: Updating document tab with manifest=\(manifest != nil), bundleURL=\(bundleURL?.lastPathComponent ?? "nil", privacy: .public)")

        let bundle = userInfo[NotificationUserInfoKey.referenceBundle] as? ReferenceBundle
        updateReferenceBundleDocumentState(manifest: manifest, bundleURL: bundleURL, bundle: bundle)

        if let bundle {
            updateAlignmentSection(from: bundle)
        }
    }

    /// Handles requests to show/focus inspector with a specific tab.
    @objc private func handleShowInspectorRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        applyInspectorTabSelection(from: notification)
    }

    /// Handles chromosome inspector requests and updates chromosome details state.
    ///
    /// Always switches to the Bundle tab when a chromosome is selected so the
    /// chromosome metadata is immediately visible in the inspector.
    @objc private func handleChromosomeInspectorRequested(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        let chromosome = notification.userInfo?[NotificationUserInfoKey.chromosome] as? ChromosomeInfo
        updateSelectedChromosome(chromosome)
        if chromosome != nil {
            viewModel.selectedTab = .bundle
        }
    }

    @objc private func handleFASTQDatasetLoaded(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let stats = notification.userInfo?["statistics"] as? FASTQDatasetStatistics else { return }
        viewModel.documentSectionViewModel.updateFASTQStatistics(stats)

        let sra = notification.userInfo?["sraRunInfo"] as? SRARunInfo
        let ena = notification.userInfo?["enaReadRecord"] as? ENAReadRecord
        if sra != nil || ena != nil {
            viewModel.documentSectionViewModel.updateSRAMetadata(sra: sra, ena: ena)
        }

        let ingestion = notification.userInfo?["ingestionMetadata"] as? IngestionMetadata
        viewModel.documentSectionViewModel.updateIngestionMetadata(ingestion)
        let derivative = notification.userInfo?["fastqDerivativeManifest"] as? FASTQDerivedBundleManifest
        viewModel.documentSectionViewModel.updateFASTQDerivativeMetadata(derivative)

        // Load FASTQ sample metadata and analysis manifest if bundle URL is provided
        if let bundleURL = notification.userInfo?["bundleURL"] as? URL {
            viewModel.fastqMetadataSectionViewModel.load(from: bundleURL)
            let projectURL = DocumentManager.shared.activeProject?.url
            viewModel.documentSectionViewModel.updateAnalysisManifest(
                bundleURL: bundleURL,
                projectURL: projectURL
            )

            // Wire navigation callback so clicking an analysis entry in the
            // Inspector opens it in the viewer via the sidebar selection path.
            viewModel.documentSectionViewModel.navigateToAnalysis = { [weak self] entry in
                guard let projectURL = DocumentManager.shared.activeProject?.url else { return }
                let analysisURL = projectURL
                    .appendingPathComponent(AnalysesFolder.directoryName)
                    .appendingPathComponent(entry.analysisDirectoryName)
                guard FileManager.default.fileExists(atPath: analysisURL.path) else {
                    // Stale entry — prune and refresh
                    self?.viewModel.documentSectionViewModel.updateAnalysisManifest(
                        bundleURL: bundleURL,
                        projectURL: projectURL
                    )
                    return
                }
                // Select the analysis in the sidebar, which triggers displayContent
                AppDelegate.shared?.mainWindowController?.mainSplitViewController?
                    .sidebarController.selectItem(forURL: analysisURL)
            }
        }

        viewModel.selectedTab = .bundle
    }

    /// Handles viewport content mode changes.
    ///
    /// Updates the view model's content mode and ensures the selected tab is valid
    /// for the new mode. If the current tab is no longer available, switches to the
    /// first available tab.
    @objc private func handleContentModeChanged(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        guard let rawMode = notification.userInfo?[NotificationUserInfoKey.contentMode] as? String,
              let mode = ViewportContentMode(rawValue: rawMode) else { return }

        logger.info("handleContentModeChanged: mode=\(rawMode, privacy: .public)")
        viewModel.contentMode = mode

        // If the currently selected tab is not available in the new mode, switch to the first available tab.
        let available = viewModel.availableTabs
        if !available.contains(viewModel.selectedTab), let first = available.first {
            viewModel.selectedTab = first
        }
    }

    /// Handles the `.batchManifestCached` notification.
    ///
    /// When a batch aggregated manifest is saved to disk (first-load slow path), this transitions
    /// the Inspector status indicator from `.building` to `.cached`.
    @objc private func handleBatchManifestCached(_ notification: Notification) {
        guard shouldAcceptScopedNotification(notification) else { return }
        if viewModel.documentSectionViewModel.batchManifestStatus == .building {
            viewModel.documentSectionViewModel.batchManifestStatus = .cached
        }
    }

    /// Applies inspector tab selection from notification userInfo if provided.
    private func applyInspectorTabSelection(from notification: Notification) {
        guard let tabName = notification.userInfo?[NotificationUserInfoKey.inspectorTab] as? String,
              let tab = InspectorTab(rawValue: tabName) else {
            return
        }
        viewModel.selectedTab = tab
    }

    private func shouldAcceptScopedNotification(_ notification: Notification) -> Bool {
        guard let notificationScope = notification.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope else {
            return true
        }
        guard let windowStateScope else { return true }
        return notificationScope == windowStateScope
    }

    private func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    // MARK: - Annotation Editing Handlers

    /// Handles annotation updates from the SelectionSection.
    ///
    /// Posts an `annotationUpdated` notification so the viewer and document
    /// can respond to the changes.
    private func handleAnnotationUpdatedFromInspector(_ annotation: SequenceAnnotation) {
        viewModel.selectedAnnotation = annotation

        NotificationCenter.default.post(
            name: .annotationUpdated,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector"
            ])
        )
    }

    /// Handles annotation deletion from the SelectionSection.
    ///
    /// Posts an `annotationDeleted` notification and clears the selection.
    private func handleAnnotationDeletedFromInspector(_ annotationID: UUID) {
        // Get the annotation before clearing
        let deletedAnnotation = viewModel.selectedAnnotation

        // Clear selection
        viewModel.selectedAnnotation = nil

        // Post deletion notification
        if let annotation = deletedAnnotation {
            NotificationCenter.default.post(
                name: .annotationDeleted,
                object: self,
                userInfo: windowScopedUserInfo([
                    NotificationUserInfoKey.annotation: annotation,
                    NotificationUserInfoKey.changeSource: "inspector"
                ])
            )
        }
    }

    /// Handles applying a color to all annotations of a specific type.
    ///
    /// Posts an `annotationColorAppliedToType` notification so the viewer and document
    /// can update all annotations of the given type.
    private func handleApplyColorToAllOfType(_ annotationType: AnnotationType, color: AnnotationColor) {
        logger.info("handleApplyColorToAllOfType: Applying color to all \(annotationType.rawValue, privacy: .public) annotations")

        NotificationCenter.default.post(
            name: .annotationColorAppliedToType,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotationType: annotationType,
                NotificationUserInfoKey.annotationColor: color,
                NotificationUserInfoKey.changeSource: "inspector"
            ])
        )
    }

    /// Handles show/hide translation request from the Selection section.
    ///
    /// Toggles `isTranslationVisible` and posts a notification so the viewer
    /// can show or hide the CDS translation track.
    private func handleShowTranslationRequested(_ annotation: SequenceAnnotation) {
        let vm = viewModel.selectionSectionViewModel
        vm.isTranslationVisible.toggle()

        NotificationCenter.default.post(
            name: .showCDSTranslationRequested,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.annotation: annotation,
                "visible": vm.isTranslationVisible,
            ])
        )
    }

    /// Opens add-annotation flow for the current sequence selection.
    private func handleAddAnnotationRequested() {
        _ = NSApp.sendAction(#selector(AppDelegate.addAnnotation(_:)), to: nil, from: self)
    }

    // MARK: - Appearance Handlers

    /// Handles appearance setting changes.
    ///
    /// Saves the appearance settings and posts an `appearanceChanged` notification
    /// so the viewer can update its rendering.
    private func handleAppearanceChanged() {
        logger.info("handleAppearanceChanged: Appearance change detected")

        var appearance = viewModel.appearance
        appearance.trackHeight = CGFloat(viewModel.appearanceSectionViewModel.trackHeight)
        logger.info("handleAppearanceChanged: Track height = \(appearance.trackHeight, privacy: .public)")

        AppSettings.shared.sequenceAppearance = appearance
        AppSettings.shared.save()
        viewModel.appearance = appearance

        logger.info("handleAppearanceChanged: Appearance persisted")
    }

    /// Handles quality overlay toggle changes.
    ///
    /// Updates appearance settings and posts notification.
    private func handleQualityOverlayToggled(_ enabled: Bool) {
        var appearance = viewModel.appearance
        appearance.showQualityOverlay = enabled
        AppSettings.shared.sequenceAppearance = appearance
        AppSettings.shared.save()
        viewModel.appearance = appearance

        // AppSettings.save() posts .appearanceChanged
    }

    /// Handles sample display state changes from the SampleSection.
    ///
    /// Posts a `sampleDisplayStateChanged` notification so the viewer
    /// can update genotype row rendering.
    private func handleSampleDisplayStateChanged(_ state: SampleDisplayState) {
        logger.info("handleSampleDisplayStateChanged: showRows=\(state.showGenotypeRows) rowHeight=\(state.rowHeight) hidden=\(state.hiddenSamples.count)")

        NotificationCenter.default.post(
            name: .sampleDisplayStateChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                NotificationUserInfoKey.sampleDisplayState: state
            ])
        )
    }

    /// Handles resetting ALL appearance settings to their defaults.
    ///
    /// This is called when the "Reset to Defaults" button is pressed in the
    /// Appearance section. It coordinates resetting all appearance-related
    /// settings across multiple section view models:
    /// - Base colors (A, T, G, C, N)
    /// - Track height
    /// - Quality overlay
    /// - Annotation height, spacing, visibility, and filters
    ///
    /// After resetting, it clears persisted settings and posts notifications
    /// so the viewer updates immediately.
    public func resetAllAppearanceSettings() {
        logger.info("handleResetAllAppearanceSettings: Resetting ALL appearance settings to defaults")

        // 1. Reset the appearance section view model (base colors, track height)
        viewModel.appearanceSectionViewModel.resetToDefaults()

        // 2. Reset the quality section view model (quality overlay)
        viewModel.qualitySectionViewModel.resetToDefaults()

        // 3. Reset the annotation section view model (height, spacing, visibility, filters)
        viewModel.annotationSectionViewModel.resetToDefaults()

        // 4. Reset the core appearance model in AppSettings
        let defaultAppearance = SequenceAppearance.default
        AppSettings.shared.sequenceAppearance = defaultAppearance
        AppSettings.shared.save()
        viewModel.appearance = defaultAppearance
        logger.info("handleResetAllAppearanceSettings: Reset persisted settings to defaults")

        // 5. Post annotation notifications so the viewer updates
        NotificationCenter.default.post(
            name: .annotationSettingsChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "showAnnotations": viewModel.annotationSectionViewModel.showAnnotations,
                "annotationHeight": viewModel.annotationSectionViewModel.annotationHeight,
                "annotationSpacing": viewModel.annotationSectionViewModel.annotationSpacing
            ])
        )

        // Post annotation filter changed notification
        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: windowScopedUserInfo([
                "visibleTypes": viewModel.annotationSectionViewModel.visibleTypes,
                "filterText": viewModel.annotationSectionViewModel.filterText
            ])
        )

        // 6. Reset bundle view state (type color overrides, navigation, etc.)
        NotificationCenter.default.post(
            name: .bundleViewStateResetRequested,
            object: self,
            userInfo: windowScopedUserInfo()
        )

        logger.info("handleResetAllAppearanceSettings: Posted all notifications for viewer update")
    }

    // MARK: - Public API

    /// Updates the document tab with bundle metadata from a loaded reference bundle.
    ///
    /// - Parameters:
    ///   - manifest: The bundle manifest to display, or nil to clear
    ///   - bundleURL: The URL of the loaded bundle
    public func updateBundleMetadata(manifest: BundleManifest?, bundleURL: URL?) {
        viewModel.documentSectionViewModel.update(manifest: manifest, bundleURL: bundleURL)
    }

    private func updateReferenceBundleDocumentState(
        manifest: BundleManifest?,
        bundleURL: URL?,
        bundle: ReferenceBundle?
    ) {
        updateBundleMetadata(manifest: manifest, bundleURL: bundleURL)

        if let bundle {
            viewModel.selectionSectionViewModel.referenceBundle = bundle
            viewModel.documentSectionViewModel.referenceTrackCapabilities =
                ReferenceBundleTrackCapabilities(bundle: bundle)
            updateSampleSection(from: bundle)
        }

        // Auto-select the first chromosome so the Chromosome section is visible immediately.
        if let chromosomes = manifest?.genome?.chromosomes, !chromosomes.isEmpty {
            let sorted = naturalChromosomeSort(chromosomes)
            updateSelectedChromosome(sorted.first)
        }
    }

    /// Updates the Document inspector with assembly provenance, source inputs, and artifact links.
    public func updateAssemblyDocument(
        result: AssemblyResult,
        provenance: AssemblyProvenance?,
        projectURL: URL?
    ) {
        let sourceRows = provenance.map {
            AssemblyInspectorSourceResolver.resolve(provenanceInputs: $0.inputs, projectURL: projectURL)
        } ?? []

        let state = AssemblyDocumentState(
            title: result.outputDirectory.lastPathComponent,
            subtitle: "\(result.tool.displayName) • \(result.readType.displayName)",
            sourceData: sourceRows,
            contextRows: assemblyContextRows(result: result, provenance: provenance),
            artifactRows: assemblyArtifactRows(result: result)
        )

        viewModel.documentSectionViewModel.navigateToSourceData = { [weak self] url in
            NotificationCenter.default.post(
                name: .navigateToSidebarItem,
                object: nil,
                userInfo: self?.windowScopedUserInfo(["url": url])
            )
        }
        viewModel.documentSectionViewModel.updateAssemblyDocument(state)
        viewModel.selectedTab = .bundle
    }

    /// Updates the Document inspector with a prebuilt mapping document state.
    func updateMappingDocument(_ state: MappingDocumentState?) {
        if state != nil {
            viewModel.documentSectionViewModel.navigateToSourceData = { [weak self] url in
                NotificationCenter.default.post(
                    name: .navigateToSidebarItem,
                    object: nil,
                    userInfo: self?.windowScopedUserInfo(["url": url])
                )
            }
        } else {
            viewModel.documentSectionViewModel.navigateToSourceData = nil
        }
        viewModel.documentSectionViewModel.updateMappingDocument(state)
        if state != nil {
            viewModel.selectedTab = .bundle
        }
    }

    /// Updates the chromosome selection in the Document tab.
    ///
    /// - Parameter chromosome: The chromosome to display details for, or nil to clear
    public func updateSelectedChromosome(_ chromosome: ChromosomeInfo?) {
        viewModel.documentSectionViewModel.selectChromosome(chromosome)
    }

    /// Updates the NAO-MGS manifest in the Document section.
    ///
    /// - Parameter manifest: The NAO-MGS manifest, or nil to clear
    public func updateNaoMgsManifest(_ manifest: NaoMgsManifest?) {
        viewModel.documentSectionViewModel.updateNaoMgsManifest(manifest)
    }

    /// Wires the shared classifier sample picker state for the Inspector-embedded sample selector.
    func updateClassifierSampleState(
        pickerState: ClassifierSamplePickerState,
        entries: [any ClassifierSampleEntry],
        strippedPrefix: String,
        metadata: SampleMetadataStore? = nil,
        attachments: BundleAttachmentStore? = nil
    ) {
        viewModel.documentSectionViewModel.classifierPickerState = pickerState
        viewModel.documentSectionViewModel.classifierSampleEntries = entries
        viewModel.documentSectionViewModel.classifierStrippedPrefix = strippedPrefix
        viewModel.documentSectionViewModel.sampleMetadataStore = metadata
        viewModel.documentSectionViewModel.bundleAttachmentStore = attachments
    }

    /// Updates the Inspector with batch operation details for display in the Result Summary tab.
    ///
    /// - Parameters:
    ///   - tool: Human-readable tool name (e.g. "Kraken2").
    ///   - parameters: Key-value pairs from the batch manifest (database, confidence, etc.).
    ///   - timestamp: Batch creation timestamp from the manifest header.
    ///   - sourceSamples: Pairs of sample IDs and their resolved bundle URLs (nil when not resolvable).
    func updateBatchOperationDetails(
        tool: String,
        parameters: [String: String],
        timestamp: Date?,
        sourceSamples: [(sampleId: String, bundleURL: URL?)]
    ) {
        viewModel.documentSectionViewModel.batchOperationTool = tool
        viewModel.documentSectionViewModel.batchOperationParameters = parameters
        viewModel.documentSectionViewModel.batchOperationTimestamp = timestamp
        viewModel.documentSectionViewModel.batchSourceSampleURLs = sourceSamples
    }

    /// Clears batch operation details from the Inspector.
    func clearBatchOperationDetails() {
        viewModel.documentSectionViewModel.batchOperationTool = nil
        viewModel.documentSectionViewModel.batchOperationParameters = [:]
        viewModel.documentSectionViewModel.batchOperationTimestamp = nil
        viewModel.documentSectionViewModel.batchSourceSampleURLs = []
    }

    // MARK: - Metadata Import

    @objc private func handleMetadataImportRequested() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Select a CSV or TSV file with sample metadata"

        guard let window = self.view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleMetadataImport(from: url)
                }
            }
        }
    }

    private func handleMetadataImport(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let knownIds = Set(viewModel.documentSectionViewModel.classifierSampleEntries.map(\.id))

        guard let scanResult = try? SampleMetadataStore.scanForSampleColumn(
            csvData: data,
            knownSampleIds: knownIds
        ) else { return }

        guard let best = scanResult.bestColumn else {
            let alert = NSAlert()
            alert.messageText = "No Sample Column Found"
            alert.informativeText = "No column in this file contains values matching the known sample IDs. Check that your metadata file includes a column with sample names."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = self.view.window {
                alert.beginSheetModal(for: window)
            }
            return
        }

        if best.matchCount == scanResult.totalRows {
            finishMetadataImport(
                data: data,
                scanResult: scanResult,
                sampleColumnIndex: best.index,
                knownSampleIds: knownIds
            )
        } else {
            let alert = NSAlert()
            alert.messageText = "Confirm Sample Column"
            alert.informativeText = "Column \"\(best.name)\" matched \(best.matchCount) of \(scanResult.totalRows) rows to sample IDs. Use this column?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Use \"\(best.name)\"")
            if scanResult.candidates.count > 1 {
                alert.addButton(withTitle: "Choose Another\u{2026}")
            }
            alert.addButton(withTitle: "Cancel")

            guard let window = self.view.window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        switch response {
                        case .alertFirstButtonReturn:
                            self.finishMetadataImport(
                                data: data,
                                scanResult: scanResult,
                                sampleColumnIndex: best.index,
                                knownSampleIds: knownIds
                            )
                        case .alertSecondButtonReturn where scanResult.candidates.count > 1:
                            self.showSampleColumnPicker(
                                data: data,
                                scanResult: scanResult,
                                knownSampleIds: knownIds
                            )
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    private func showSampleColumnPicker(
        data: Data,
        scanResult: MetadataColumnScanResult,
        knownSampleIds: Set<String>
    ) {
        let alert = NSAlert()
        alert.messageText = "Select Sample Column"
        alert.informativeText = "Choose which column contains sample IDs:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 25), pullsDown: false)
        for candidate in scanResult.candidates {
            popup.addItem(withTitle: "\(candidate.name) (\(candidate.matchCount) of \(scanResult.totalRows) matched)")
            popup.lastItem?.tag = candidate.index
        }
        alert.accessoryView = popup

        guard let window = self.view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, response == .alertFirstButtonReturn else { return }
                    let selectedIndex = popup.selectedItem?.tag ?? scanResult.candidates[0].index
                    self.finishMetadataImport(
                        data: data,
                        scanResult: scanResult,
                        sampleColumnIndex: selectedIndex,
                        knownSampleIds: knownSampleIds
                    )
                }
            }
        }
    }

    private func finishMetadataImport(
        data: Data,
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        knownSampleIds: Set<String>
    ) {
        let store = SampleMetadataStore(
            scanResult: scanResult,
            sampleColumnIndex: sampleColumnIndex,
            knownSampleIds: knownSampleIds
        )
        viewModel.documentSectionViewModel.sampleMetadataStore = store

        if let bundleURL = viewModel.documentSectionViewModel.bundleAttachmentStore?.bundleURL {
            try? store.persist(originalData: data, to: bundleURL)
            store.wireAutosave(bundleURL: bundleURL)
        }
    }

    /// Updates the NVD manifest in the Document section.
    ///
    /// - Parameter manifest: The NVD manifest, or nil to clear
    public func updateNvdManifest(_ manifest: NvdManifest?) {
        viewModel.documentSectionViewModel.updateNvdManifest(manifest)
    }

    private func assemblyContextRows(
        result: AssemblyResult,
        provenance: AssemblyProvenance?
    ) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Assembler", provenance?.assembler ?? result.tool.displayName),
            ("Read Type", result.readType.displayName),
        ]

        if let version = provenance?.assemblerVersion ?? result.assemblerVersion, !version.isEmpty {
            rows.append(("Version", version))
        }
        if let provenance {
            rows.append(("Execution Backend", provenance.executionBackend.rawValue))
            if let managedEnvironment = provenance.managedEnvironment, !managedEnvironment.isEmpty {
                rows.append(("Environment", managedEnvironment))
            }
            if let launcherCommand = provenance.launcherCommand, !launcherCommand.isEmpty {
                rows.append(("Launcher", launcherCommand))
            }
            rows.append(("Run Date", Self.assemblyDateFormatter.string(from: provenance.assemblyDate)))
            rows.append(("Host", "\(provenance.hostOS) • \(provenance.hostArchitecture)"))
            rows.append(("Lungfish", provenance.lungfishVersion))
            rows.append(("Mode", provenance.parameters.mode))
            rows.append(("K-mer Sizes", provenance.parameters.kmerSizes))
            rows.append(("Threads", String(provenance.parameters.threads)))
            rows.append(("Memory", "\(provenance.parameters.memoryGB) GB"))
            rows.append(("Minimum Contig Length", "\(provenance.parameters.minContigLength) bp"))
        }

        rows.append(("Wall Time", String(format: "%.1fs", result.wallTimeSeconds)))
        rows.append(("Contigs", "\(result.statistics.contigCount)"))
        rows.append(("Total Assembled bp", "\(result.statistics.totalLengthBP)"))
        rows.append(("N50", "\(result.statistics.n50) bp"))
        rows.append(("L50", "\(result.statistics.l50)"))
        rows.append(("Longest Contig", "\(result.statistics.largestContigBP) bp"))
        rows.append(("Global GC", String(format: "%.1f%%", result.statistics.gcPercent)))
        rows.append(("Command", provenance?.commandLine ?? result.commandLine))
        rows.append(("Output Directory", result.outputDirectory.path))

        return rows
    }

    private func assemblyArtifactRows(result: AssemblyResult) -> [AssemblyDocumentArtifactRow] {
        [
            .init(label: "Contigs FASTA", fileURL: result.contigsPath),
            .init(label: "Scaffolds FASTA", fileURL: result.scaffoldsPath),
            .init(label: "Graph", fileURL: result.graphPath),
            .init(label: "Log", fileURL: result.logPath),
            .init(label: "Parameters", fileURL: result.paramsPath),
            .init(
                label: "Provenance",
                fileURL: result.outputDirectory.appendingPathComponent(AssemblyProvenance.filename)
            ),
        ]
    }

    private static let assemblyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Injects the shared AI assistant service used by the embedded inspector tab.
    public func setAIAssistantService(_ service: AIAssistantService) {
        viewModel.aiAssistantService = service
    }

    /// Populates the sample section view model from the bundle's variant databases.
    ///
    /// Opens each variant database and aggregates sample names and metadata field names.
    private func updateSampleSection(from bundle: ReferenceBundle) {
        var allSampleNames: [String] = []
        var sampleNameSet = Set<String>()
        var allMetadataFields: Set<String> = []
        var allSampleMetadata: [String: [String: String]] = [:]
        var allSourceFiles: [String: String] = [:]
        var dbByTrackId: [String: VariantDatabase] = [:]
        var variantDBURLs: [URL] = []

        for vTrackId in bundle.variantTrackIds {
            guard let trackInfo = bundle.variantTrack(id: vTrackId),
                  let dbPath = trackInfo.databasePath else { continue }
            let dbURL = bundle.url.appendingPathComponent(dbPath)
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            do {
                let db = try VariantDatabase(url: dbURL)
                dbByTrackId[vTrackId] = db
                variantDBURLs.append(dbURL)
                for name in db.sampleNames() where sampleNameSet.insert(name).inserted {
                    allSampleNames.append(name)
                }
                let fields = db.metadataFieldNames()
                allMetadataFields.formUnion(fields)

                // Load per-sample metadata and source files
                for (name, metadata) in db.allSampleMetadata() {
                    allSampleMetadata[name] = metadata
                }
                let sources = db.allSourceFiles()
                for (name, file) in sources {
                    allSourceFiles[name] = file
                }
            } catch {
                logger.warning("updateSampleSection: Failed to open variant database '\(vTrackId, privacy: .public)': \(error.localizedDescription)")
            }
        }

        let sampleCount = allSampleNames.count
        viewModel.sampleSectionViewModel.update(
            sampleCount: sampleCount,
            sampleNames: allSampleNames,
            metadataFields: allMetadataFields.sorted(),
            sampleMetadata: allSampleMetadata,
            sourceFiles: allSourceFiles
        )

        // Wire save callback for metadata editing
        let capturedURLs = variantDBURLs
        viewModel.sampleSectionViewModel.onSaveMetadata = { sampleName, metadata in
            for dbURL in capturedURLs {
                do {
                    let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                    try rwDB.updateSampleMetadata(name: sampleName, metadata: metadata)
                    logger.info("updateSampleSection: Saved metadata for '\(sampleName)' to \(dbURL.lastPathComponent)")
                } catch {
                    logger.warning("updateSampleSection: Failed to save metadata: \(error.localizedDescription)")
                }
            }
        }

        // Wire import callback
        viewModel.sampleSectionViewModel.onImportMetadata = { [weak self] in
            self?.presentMetadataImportPanel(variantDBURLs: capturedURLs, bundle: bundle)
        }

        // Wire variant databases for track-aware genotype lookups.
        viewModel.variantSectionViewModel.variantDatabasesByTrackId = dbByTrackId

        logger.info("updateSampleSection: \(sampleCount) samples, \(allMetadataFields.count) metadata fields, \(allSourceFiles.count) source files")
    }

    /// Presents an open panel for importing sample metadata from TSV/CSV.
    private func presentMetadataImportPanel(variantDBURLs: [URL], bundle: ReferenceBundle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .init(filenameExtension: "tsv")!,
            .init(filenameExtension: "csv")!,
            .init(filenameExtension: "txt")!,
        ]
        panel.message = "Select a TSV or CSV file with sample metadata"
        panel.prompt = "Import"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let fileURL = panel.url else { return }
            let ext = fileURL.pathExtension.lowercased()
            let format: MetadataFormat = ext == "csv" ? .csv : .tsv

            var totalUpdated = 0
            for dbURL in variantDBURLs {
                do {
                    let rwDB = try VariantDatabase(url: dbURL, readWrite: true)
                    let count = try rwDB.importSampleMetadata(from: fileURL, format: format)
                    totalUpdated += count
                } catch {
                    logger.warning("importSampleMetadata: \(error.localizedDescription)")
                }
            }

            logger.info("importSampleMetadata: Updated \(totalUpdated) samples from \(fileURL.lastPathComponent)")
            // Refresh the sample section
            self?.updateSampleSection(from: bundle)
        }
    }

    private func makeReadDisplaySettingsPayload(from vm: ReadStyleSectionViewModel) -> [AnyHashable: Any] {
        [
            NotificationUserInfoKey.showReads: vm.showReads,
            NotificationUserInfoKey.maxReadRows: Int(vm.maxReadRows),
            NotificationUserInfoKey.limitReadRows: vm.limitReadRows,
            NotificationUserInfoKey.verticalCompressContig: vm.verticallyCompressContig,
            NotificationUserInfoKey.minMapQ: Int(vm.minMapQ),
            NotificationUserInfoKey.showMismatches: vm.showMismatches,
            NotificationUserInfoKey.showSoftClips: vm.showSoftClips,
            NotificationUserInfoKey.showIndels: vm.showIndels,
            NotificationUserInfoKey.showStrandColors: vm.showStrandColors,
            NotificationUserInfoKey.consensusMaskingEnabled: vm.consensusMaskingEnabled,
            NotificationUserInfoKey.consensusGapThresholdPercent: Int(vm.consensusGapThresholdPercent),
            NotificationUserInfoKey.consensusMinDepth: Int(vm.consensusMinDepth),
            NotificationUserInfoKey.consensusMaskingMinDepth: Int(vm.consensusMaskingMinDepth),
            NotificationUserInfoKey.consensusMinMapQ: Int(vm.consensusMinMapQ),
            NotificationUserInfoKey.consensusMinBaseQ: Int(vm.consensusMinBaseQ),
            NotificationUserInfoKey.showConsensusTrack: vm.showConsensusTrack,
            NotificationUserInfoKey.consensusMode: vm.consensusMode.rawValue,
            NotificationUserInfoKey.consensusUseAmbiguity: vm.consensusUseAmbiguity,
            NotificationUserInfoKey.excludeFlags: vm.computedExcludeFlags,
            NotificationUserInfoKey.selectedReadGroups: vm.selectedReadGroups,
            NotificationUserInfoKey.visibleAlignmentTrackID: vm.selectedVisibleAlignmentTrackID ?? "",
        ]
    }

    private func syncAlignmentTrackInventory(from bundle: ReferenceBundle) {
        viewModel.documentSectionViewModel.updateAlignmentTrackInventory(
            from: bundle,
            visibleTrackID: viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
        )
        viewModel.documentSectionViewModel.selectVisibleAlignmentTrack = { [weak self] trackID in
            self?.setVisibleAlignmentTrackSelection(trackID)
        }
        viewModel.documentSectionViewModel.removeDerivedAlignmentTrack = { [weak self] trackID in
            self?.removeDerivedAlignmentTrack(trackID)
        }
    }

    private func setVisibleAlignmentTrackSelection(_ trackID: String?) {
        viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID = trackID
        viewModel.documentSectionViewModel.visibleAlignmentTrackID = trackID
        viewModel.readStyleSectionViewModel.onSettingsChanged?()
    }

    private func removeDerivedAlignmentTrack(_ trackID: String) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before removing a derived alignment.")
            return
        }
        guard let row = viewModel.documentSectionViewModel.alignmentTrackRows.first(where: { $0.id == trackID }),
              row.isDerived else {
            presentSimpleAlert(title: "Source Alignment", message: "Only derived filtered alignments can be removed from this control.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        confirmRemoveDerivedAlignment(rowName: row.name) { [weak self] confirmed in
            guard confirmed, let self else { return }
            self.runRemoveDerivedAlignmentWorkflow(
                trackID: trackID,
                trackName: row.name,
                bundleURL: bundleURL,
                shouldReloadMappingViewer: split.viewerController.activeMappingViewportController != nil
            )
        }
    }

    private func confirmRemoveDerivedAlignment(
        rowName: String,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Remove Derived Alignment?"
        alert.informativeText = "This removes \"\(rowName)\" and its BAM, index, and metadata files from this bundle. The source alignment is not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }

    private func runRemoveDerivedAlignmentWorkflow(
        trackID: String,
        trackName: String,
        bundleURL: URL,
        shouldReloadMappingViewer: Bool
    ) {
        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        let operationID = OperationCenter.shared.start(
            title: "Remove Derived Alignment",
            detail: "Removing \(trackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )

        Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await BundleAlignmentTrackRemovalService()
                    .removeDerivedAlignmentTrack(bundleURL: bundleURL, trackID: trackID)

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }

                        split.sidebarController.reloadFromFilesystem()
                        do {
                            if self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID == result.removedTrack.id {
                                self.setVisibleAlignmentTrackSelection(nil)
                            }
                            if shouldReloadMappingViewer {
                                try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                            } else {
                                try split.viewerController.displayBundle(at: bundleURL)
                            }
                            OperationCenter.shared.complete(
                                id: operationID,
                                detail: "Removed derived alignment track \"\(result.removedTrack.name)\"."
                            )
                        } catch {
                            OperationCenter.shared.fail(id: operationID, detail: error.localizedDescription)
                            self.presentSimpleAlert(
                                title: shouldReloadMappingViewer ? "Mapping Viewer Reload Failed" : "Reload Failed",
                                message: "The derived alignment was removed, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: operationID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                        self?.presentSimpleAlert(
                            title: "Remove Derived Alignment Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    /// Populates the read style section with alignment statistics from the bundle's metadata DBs.
    private func updateAlignmentSection(from bundle: ReferenceBundle) {
        viewModel.documentSectionViewModel.referenceTrackCapabilities =
            ReferenceBundleTrackCapabilities(bundle: bundle)
        viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)
        syncAlignmentTrackInventory(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil

        // Wire the settings-changed callback to post notification
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            NotificationCenter.default.post(
                name: .readDisplaySettingsChanged,
                object: self,
                userInfo: self.windowScopedUserInfo(
                    self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel)
                )
            )
        }

        viewModel.readStyleSectionViewModel.onMarkDuplicatesRequested = { [weak self] in
            self?.runMarkDuplicatesWorkflow()
        }

        viewModel.readStyleSectionViewModel.onCreateDeduplicatedBundleRequested = { [weak self] in
            self?.runCreateDeduplicatedBundleWorkflow()
        }

        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = { [weak self] request in
            self?.runCreateFilteredAlignmentWorkflow(request)
        }

        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = { [weak self] request in
            self?.runConvertMappedReadsToAnnotationsWorkflow(request)
        }

        viewModel.readStyleSectionViewModel.onCallVariantsRequested = { [weak self] in
            self?.runCallVariantsWorkflow()
        }

        viewModel.readStyleSectionViewModel.onPrimerTrimRequested = { [weak self] in
            self?.runPrimerTrimWorkflow()
        }

        logger.info("updateAlignmentSection: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    func updateMappingAlignmentSection(
        from bundle: ReferenceBundle,
        applySettings: @escaping ([AnyHashable: Any]) -> Void
    ) {
        viewModel.selectionSectionViewModel.referenceBundle = bundle
        viewModel.documentSectionViewModel.bundleURL = bundle.url
        viewModel.documentSectionViewModel.referenceTrackCapabilities =
            ReferenceBundleTrackCapabilities(bundle: bundle)
        viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)
        syncAlignmentTrackInventory(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = true
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            applySettings(self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel))
        }
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = { [weak self] in
            guard let self,
                  let split = self.parent as? MainSplitViewController else { return }
            split.viewerController.presentMappingConsensusExtraction()
        }
        viewModel.readStyleSectionViewModel.onMarkDuplicatesRequested = { [weak self] in
            self?.runMarkDuplicatesWorkflow()
        }
        viewModel.readStyleSectionViewModel.onCreateDeduplicatedBundleRequested = { [weak self] in
            self?.runCreateDeduplicatedBundleWorkflow()
        }
        viewModel.readStyleSectionViewModel.onCreateFilteredAlignmentRequested = { [weak self] request in
            self?.runCreateFilteredAlignmentWorkflow(request)
        }
        viewModel.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested = { [weak self] request in
            self?.runConvertMappedReadsToAnnotationsWorkflow(request)
        }
        viewModel.readStyleSectionViewModel.onCallVariantsRequested = { [weak self] in
            self?.runCallVariantsWorkflow()
        }
        viewModel.readStyleSectionViewModel.onPrimerTrimRequested = { [weak self] in
            self?.runPrimerTrimWorkflow()
        }
        applySettings(makeReadDisplaySettingsPayload(from: viewModel.readStyleSectionViewModel))
        logger.info("updateMappingAlignmentSection: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    func updateReferenceBundleTrackSections(
        from bundle: ReferenceBundle,
        applySettings: @escaping ([AnyHashable: Any]) -> Void
    ) {
        updateReferenceBundleDocumentState(
            manifest: bundle.manifest,
            bundleURL: bundle.url,
            bundle: bundle
        )
        updateAlignmentSection(from: bundle)
        viewModel.readStyleSectionViewModel.supportsConsensusExtraction = false
        viewModel.readStyleSectionViewModel.onExtractConsensusRequested = nil
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            self.viewModel.documentSectionViewModel.visibleAlignmentTrackID =
                self.viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID
            applySettings(self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel))
        }
        applySettings(makeReadDisplaySettingsPayload(from: viewModel.readStyleSectionViewModel))
        logger.info("updateReferenceBundleTrackSections: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    // MARK: - Variant Calling Workflow

    func presentVariantCallingDialog(
        bundle explicitBundle: ReferenceBundle? = nil,
        preferredAlignmentTrackID: String? = nil
    ) {
        let bundle = explicitBundle ?? viewModel.selectionSectionViewModel.referenceBundle
        guard let bundle else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before calling variants.")
            return
        }

        let eligibleTracks = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        guard !eligibleTracks.isEmpty else {
            presentSimpleAlert(
                title: "No Analysis-Ready BAM Tracks",
                message: "This bundle has no analysis-ready BAM alignment tracks to call variants from."
            )
            return
        }

        guard OperationCenter.shared.canStartOperation(on: bundle.url) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundle.url) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let sidebarItems = await BAMVariantCallingCatalog().sidebarItems()
            guard let window = self.view.window ?? NSApp.keyWindow else { return }

            BAMVariantCallingDialogPresenter.present(
                from: window,
                bundle: bundle,
                preferredAlignmentTrackID: preferredAlignmentTrackID,
                sidebarItems: sidebarItems,
                onRun: { [weak self] state in
                    self?.launchVariantCallingOperation(state: state)
                }
            )
        }
    }

    private func runCallVariantsWorkflow() {
        presentVariantCallingDialog()
    }

    private func launchVariantCallingOperation(state: BAMVariantCallingDialogState) {
        let bundleURL = state.bundle.url

        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        guard let request = state.pendingRequest else {
            presentSimpleAlert(
                title: "Variant Calling Not Ready",
                message: state.readinessText
            )
            return
        }

        let cliArguments = CLIVariantCallingRunner.buildCLIArguments(request: request)
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "variants",
            args: Array(cliArguments.dropFirst())
        )
        let operationTitle = "Calling variants with \(state.selectedCaller.displayName)"
        let shouldReloadMappingViewer = (parent as? MainSplitViewController)?
            .viewerController
            .activeMappingViewportController != nil
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Preparing \(state.selectedCaller.displayName)...",
            operationType: .variantCalling,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand
        )

        final class ResultTracker: @unchecked Sendable {
            var completedTrackName: String?
            var failureMessage: String?
        }
        let tracker = ResultTracker()
        let runner = CLIVariantCallingRunner()

        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                try await runner.run(arguments: cliArguments) { event in
                    switch event {
                    case .runComplete(_, let trackName, _, _, _):
                        tracker.completedTrackName = trackName
                    case .runFailed(let message):
                        tracker.failureMessage = message
                    default:
                        break
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Self.applyVariantCallingEvent(event, operationID: opID)
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, let split = self.parent as? MainSplitViewController {
                            split.sidebarController.reloadFromFilesystem()
                            do {
                                if shouldReloadMappingViewer {
                                    try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                                } else {
                                    try split.viewerController.displayBundle(at: bundleURL)
                                }
                            } catch {
                                self.presentSimpleAlert(
                                    title: shouldReloadMappingViewer ? "Mapping Viewer Reload Failed" : "Variant Calling Reload Failed",
                                    message: "Variant calling completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }

                        let detail = tracker.completedTrackName.map { "Created variant track \($0)" }
                            ?? "Variant calling complete"
                        OperationCenter.shared.complete(id: opID, detail: detail)
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                }
            } catch {
                let message = tracker.failureMessage ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: message,
                            errorMessage: message
                        )
                        self?.presentSimpleAlert(
                            title: "Variant Calling Failed",
                            message: message
                        )
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            Task {
                await runner.cancel()
            }
        }
    }

    @MainActor
    private static func applyVariantCallingEvent(_ event: CLIVariantCallingEvent, operationID: UUID) {
        let (progress, detail, level): (Double, String, OperationLogLevel) = {
            switch event {
            case .runStart(let message):
                return (0.01, message, .info)
            case .preflightStart(let message):
                return (0.02, message, .info)
            case .preflightComplete(let message):
                return (0.08, message, .info)
            case .stageStart(let message):
                return (0.10, message, .info)
            case .stageProgress(let progress, let message):
                return (max(0.10, min(0.88, progress)), message, .info)
            case .stageComplete(let message):
                return (0.70, message, .info)
            case .importStart(let message):
                return (0.74, message, .info)
            case .importComplete(let message, _):
                return (0.88, message, .info)
            case .attachStart(let message):
                return (0.90, message, .info)
            case .attachComplete(_, let trackName, _, _, _):
                let detail = trackName.map { "Attached variant track \($0)" } ?? "Attached variant track"
                return (0.97, detail, .info)
            case .runComplete(_, let trackName, _, _, _):
                return (0.99, "Reloading bundle with \(trackName)...", .info)
            case .runFailed(let message):
                return (0.99, message, .error)
            }
        }()

        OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
        OperationCenter.shared.log(id: operationID, level: level, message: detail)
    }

    // MARK: - Primer Trim Workflow

    func presentPrimerTrimDialog(
        bundle explicitBundle: ReferenceBundle? = nil
    ) {
        let bundle = explicitBundle ?? viewModel.selectionSectionViewModel.referenceBundle
        guard let bundle else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before trimming primers.")
            return
        }

        let eligibleTracks = BAMVariantCallingEligibility.eligibleAlignmentTracks(in: bundle)
        guard !eligibleTracks.isEmpty else {
            presentSimpleAlert(
                title: "No Analysis-Ready BAM Tracks",
                message: "This bundle has no analysis-ready BAM alignment tracks to primer-trim."
            )
            return
        }

        guard OperationCenter.shared.canStartOperation(on: bundle.url) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundle.url) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            let builtIn = BuiltInPrimerSchemeService.listBuiltInSchemes()
            let projectLocal: [PrimerSchemeBundle]
            if let projectURL = (self.parent as? MainSplitViewController)?.sidebarController.currentProjectURL {
                projectLocal = PrimerSchemesFolder.listBundles(in: projectURL)
            } else {
                projectLocal = []
            }
            let availability = await BAMPrimerTrimCatalog().availability()

            guard let window = self.view.window ?? NSApp.keyWindow else { return }

            BAMPrimerTrimDialogPresenter.present(
                from: window,
                bundle: bundle,
                builtInSchemes: builtIn,
                projectSchemes: projectLocal,
                availability: availability,
                onRun: { [weak self] state in
                    self?.launchPrimerTrimOperation(state: state)
                },
                onBrowseScheme: { [weak self] state in
                    self?.presentPrimerSchemeBrowseSheet(for: state)
                }
            )
        }
    }

    private func runPrimerTrimWorkflow() {
        presentPrimerTrimDialog()
    }

    private func launchPrimerTrimOperation(state: BAMPrimerTrimDialogState) {
        let bundleURL = state.bundle.url

        guard OperationCenter.shared.canStartOperation(on: bundleURL) else {
            if let holder = OperationCenter.shared.activeLockHolder(for: bundleURL) {
                presentSimpleAlert(
                    title: "Operation in Progress",
                    message: "\"\(holder.title)\" is currently running on this bundle. Please wait for it to finish."
                )
            }
            return
        }

        // Validate through the dialog's readiness gate, then extract the
        // wire-level inputs the CLI runner needs.
        guard state.prepareForRun() != nil else {
            presentSimpleAlert(
                title: "Primer Trim Not Ready",
                message: state.readinessText
            )
            return
        }
        guard let scheme = state.selectedScheme,
              let alignmentTrackID = state.alignmentTrackID else {
            return
        }
        let outputTrackName = state.outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines)

        let cliArguments = CLIPrimerTrimRunner.buildCLIArguments(
            bundleURL: bundleURL,
            alignmentTrackID: alignmentTrackID,
            schemeURL: scheme.url,
            outputTrackName: outputTrackName
        )
        let cliCommand = OperationCenter.buildCLICommand(
            subcommand: "bam primer-trim",
            args: Array(cliArguments.dropFirst(2))
        )
        let operationTitle = "Primer-trimming with \(scheme.manifest.displayName)"
        let opID = OperationCenter.shared.start(
            title: operationTitle,
            detail: "Preparing primer trim...",
            operationType: .bamPrimerTrim,
            targetBundleURL: bundleURL,
            cliCommand: cliCommand
        )

        final class ResultTracker: @unchecked Sendable {
            var completedTrackName: String?
            var failureMessage: String?
        }
        let tracker = ResultTracker()
        let runner = CLIPrimerTrimRunner()

        let task = Task(priority: .userInitiated) { [weak self] in
            do {
                try await runner.run(arguments: cliArguments) { event in
                    switch event {
                    case .runComplete(_, let trackName, _, _, _):
                        tracker.completedTrackName = trackName
                    case .runFailed(let message):
                        tracker.failureMessage = message
                    default:
                        break
                    }

                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Self.applyPrimerTrimEvent(event, operationID: opID)
                        }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        if let self, let split = self.parent as? MainSplitViewController {
                            split.sidebarController.reloadFromFilesystem()
                            do {
                                try split.viewerController.displayBundle(at: bundleURL)
                            } catch {
                                self.presentSimpleAlert(
                                    title: "Bundle Reload Failed",
                                    message: "Primer trim completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                                )
                            }
                        }

                        let detail = tracker.completedTrackName.map { "Adopted alignment track \($0)" }
                            ?? "Primer trim complete"
                        OperationCenter.shared.complete(id: opID, detail: detail)
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(id: opID, detail: "Cancelled")
                    }
                }
            } catch {
                let message = tracker.failureMessage ?? error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: opID,
                            detail: message,
                            errorMessage: message
                        )
                        self?.presentSimpleAlert(
                            title: "Primer Trim Failed",
                            message: message
                        )
                    }
                }
            }
        }

        OperationCenter.shared.setCancelCallback(for: opID) {
            task.cancel()
            Task {
                await runner.cancel()
            }
        }
    }

    @MainActor
    private static func applyPrimerTrimEvent(_ event: CLIPrimerTrimEvent, operationID: UUID) {
        let (progress, detail, level): (Double, String, OperationLogLevel) = {
            switch event {
            case .runStart(let message):
                return (0.01, message, .info)
            case .preflightStart(let message):
                return (0.02, message, .info)
            case .preflightComplete(let message):
                return (0.08, message, .info)
            case .stageStart(let message):
                return (0.10, message, .info)
            case .stageProgress(let progress, let message):
                return (max(0.10, min(0.80, progress)), message, .info)
            case .stageComplete(let message):
                return (0.80, message, .info)
            case .attachStart(let message):
                return (0.90, message, .info)
            case .attachComplete(_, let trackName, _, _, _):
                let detail = trackName.map { "Adopted alignment track \($0)" } ?? "Adopted alignment track"
                return (0.97, detail, .info)
            case .runComplete(_, let trackName, _, _, _):
                return (0.99, "Reloading bundle with \(trackName)...", .info)
            case .runFailed(let message):
                return (0.99, message, .error)
            }
        }()

        OperationCenter.shared.update(id: operationID, progress: progress, detail: detail)
        OperationCenter.shared.log(id: operationID, level: level, message: detail)
    }

    private func presentPrimerSchemeBrowseSheet(for state: BAMPrimerTrimDialogState) {
        guard let window = view.window ?? NSApp.keyWindow else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose Primer Scheme"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.directoryURL = (parent as? MainSplitViewController)?
            .sidebarController
            .currentProjectURL
            .flatMap { PrimerSchemesFolder.folderURL(in: $0) }

        panel.beginSheetModal(for: window) { [weak self, weak state] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let scheme = try PrimerSchemeBundle.load(from: url)
                state?.addProjectSchemeAndSelect(scheme)
            } catch {
                self?.presentSimpleAlert(
                    title: "Could Not Load Primer Scheme",
                    message: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Duplicate Workflows

    private func runConvertMappedReadsToAnnotationsWorkflow(_ request: MappedReadsAnnotationInspectorLaunchRequest) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before converting mapped reads to annotations.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }

        let launchContext: FilteredAlignmentWorkflowLaunchContext
        switch Self.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: split.viewerController.activeMappingViewportController != nil
        ) {
        case .blocked(let alert):
            presentSimpleAlert(title: alert.title, message: alert.message)
            return
        case .launch(let context):
            launchContext = context
        }

        let operationID = Self.startMappedReadsAnnotationWorkflowOperation(
            bundleURL: bundleURL,
            outputTrackName: request.outputTrackName
        )
        let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
            .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
        viewModel.readStyleSectionViewModel.latestMappedReadsAnnotationMessage = nil
        viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = true
        split.activityIndicator.show(message: "Converting mapped reads to annotations...", style: .indeterminate)

        Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await MappedReadsAnnotationService().convertMappedReads(
                    request: request.workflowRequest(bundleURL: bundleURL),
                    progressHandler: { [weak self] progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.update(
                                    id: operationID,
                                    progress: max(0.01, min(0.99, progress)),
                                    detail: message
                                )
                                if let self,
                                   let split = self.parent as? MainSplitViewController {
                                    split.activityIndicator.updateMessage(message)
                                }
                            }
                        }
                    }
                )

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.complete(
                            id: operationID,
                            detail: "Created annotation track \"\(result.annotationTrackInfo.name)\"."
                        )
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }
                        self.viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = false
                        split.activityIndicator.hide()

                        let createdTrackName = result.annotationTrackInfo.name
                        self.viewModel.readStyleSectionViewModel.noteMappedReadsAnnotationCreation(
                            createdTrackName: createdTrackName,
                            sourceTrackName: sourceTrackName
                        )
                        do {
                            try launchContext.reload(
                                using: FilteredAlignmentWorkflowReloadActions(
                                    reloadMappingViewerBundle: {
                                        try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                                    },
                                    displayBundle: { url in
                                        try split.viewerController.displayBundle(at: url)
                                    }
                                )
                            )
                            self.viewModel.selectedTab = .analysis
                            self.presentSimpleAlert(
                                title: "Mapped Reads Converted",
                                message: "Created annotation track \"\(createdTrackName)\" from \"\(sourceTrackName)\". Open the annotation table to sort and filter mapped-read fields."
                            )
                        } catch {
                            self.presentSimpleAlert(
                                title: launchContext.reloadFailureAlertTitle,
                                message: "Annotation track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: operationID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }
                        self.viewModel.readStyleSectionViewModel.isMappedReadsAnnotationWorkflowRunning = false
                        split.activityIndicator.hide()
                        self.presentSimpleAlert(
                            title: "Mapped-Read Annotation Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private func runCreateFilteredAlignmentWorkflow(_ request: AlignmentFilterInspectorLaunchRequest) {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before creating a filtered alignment track.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }
        guard let split = parent as? MainSplitViewController else { return }

        let startOutcome = Self.makeFilteredAlignmentWorkflowStartOutcome(
            bundleURL: bundleURL,
            serviceTarget: split.viewerController.activeMappingViewportController?.filteredAlignmentServiceTarget ?? .bundle(bundleURL),
            isMappingViewerDisplayedAtLaunch: split.viewerController.activeMappingViewportController != nil
        )
        let launchContext: FilteredAlignmentWorkflowLaunchContext
        switch startOutcome {
        case .blocked(let alert):
            presentSimpleAlert(title: alert.title, message: alert.message)
            return
        case .launch(let context):
            launchContext = context
        }

        let operationID = Self.startFilteredAlignmentWorkflowOperation(
            bundleURL: bundleURL,
            outputTrackName: request.outputTrackName
        )
        let sourceTrackName = viewModel.readStyleSectionViewModel.alignmentFilterTrackOptions
            .first(where: { $0.id == request.sourceTrackID })?.name ?? request.sourceTrackID
        viewModel.readStyleSectionViewModel.latestDerivedAlignmentMessage = nil
        viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = true
        split.activityIndicator.show(message: "Creating filtered alignment track...", style: .indeterminate)

        Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await BundleAlignmentFilterService().deriveFilteredAlignment(
                    target: launchContext.serviceTarget,
                    sourceTrackID: request.sourceTrackID,
                    outputTrackName: request.outputTrackName,
                    filterRequest: request.filterRequest,
                    progressHandler: { [weak self] progress, message in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                OperationCenter.shared.update(
                                    id: operationID,
                                    progress: max(0.01, min(0.99, progress)),
                                    detail: message
                                )
                                if let self,
                                   let split = self.parent as? MainSplitViewController {
                                    split.activityIndicator.updateMessage(message)
                                }
                            }
                        }
                    }
                )

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.complete(
                            id: operationID,
                            detail: "Created filtered alignment track \"\(result.trackInfo.name)\"."
                        )
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }
                        self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                        split.activityIndicator.hide()

                        let createdTrackName = result.trackInfo.name
                        self.viewModel.readStyleSectionViewModel.noteDerivedAlignmentCreation(
                            createdTrackName: createdTrackName,
                            sourceTrackName: sourceTrackName
                        )
                        do {
                            try launchContext.reload(
                                using: FilteredAlignmentWorkflowReloadActions(
                                    reloadMappingViewerBundle: {
                                        try split.viewerController.reloadMappingViewerBundleIfDisplayed()
                                    },
                                    displayBundle: { url in
                                        try split.viewerController.displayBundle(at: url)
                                    }
                                )
                            )
                            self.applyFilteredAlignmentSuccess(createdTrackID: result.trackInfo.id)
                            self.viewModel.readStyleSectionViewModel.onSettingsChanged?()
                            self.presentSimpleAlert(
                                title: "Filtered Alignment Created",
                                message: "Created a new filtered alignment from \"\(sourceTrackName)\". The source alignment was not changed. Now viewing \"\(createdTrackName)\". Use Bundle > Alignment Tracks or View > Alignment to switch between them."
                            )
                        } catch {
                            self.presentSimpleAlert(
                                title: launchContext.reloadFailureAlertTitle,
                                message: "Filtered alignment track \"\(createdTrackName)\" was created, but the updated bundle could not be reloaded: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        OperationCenter.shared.fail(
                            id: operationID,
                            detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                        guard let self,
                              let split = self.parent as? MainSplitViewController else { return }
                        self.viewModel.readStyleSectionViewModel.isAlignmentFilterWorkflowRunning = false
                        split.activityIndicator.hide()
                        self.presentSimpleAlert(
                            title: "Filtered Alignment Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    func applyFilteredAlignmentSuccess(createdTrackID: String) {
        viewModel.readStyleSectionViewModel.selectedVisibleAlignmentTrackID = createdTrackID
        viewModel.documentSectionViewModel.markRecentlyCreatedAlignmentTrack(createdTrackID)
        viewModel.documentSectionViewModel.visibleAlignmentTrackID = createdTrackID
        viewModel.selectedTab = .analysis
    }

    static func makeFilteredAlignmentWorkflowStartOutcome(
        bundleURL: URL,
        serviceTarget: AlignmentFilterTarget,
        isMappingViewerDisplayedAtLaunch: Bool,
        canStartBundleMutation: (URL) -> Bool = { OperationCenter.shared.canStartOperation(on: $0) },
        activeBundleMutationTitle: (URL) -> String? = { OperationCenter.shared.activeLockHolder(for: $0)?.title }
    ) -> FilteredAlignmentWorkflowStartOutcome {
        guard canStartBundleMutation(bundleURL) else {
            let message: String
            if let title = activeBundleMutationTitle(bundleURL) {
                message = "\"\(title)\" is currently running on this bundle. Please wait for it to finish."
            } else {
                message = "Another operation is currently running on this bundle. Please wait for it to finish."
            }
            return .blocked(
                InspectorWorkflowAlert(
                    title: "Operation in Progress",
                    message: message
                )
            )
        }

        return .launch(
            FilteredAlignmentWorkflowLaunchContext(
                bundleURL: bundleURL,
                serviceTarget: serviceTarget,
                reloadTarget: isMappingViewerDisplayedAtLaunch ? .mappingViewer : .bundleViewer
            )
        )
    }

    static func startFilteredAlignmentWorkflowOperation(
        bundleURL: URL,
        outputTrackName: String
    ) -> UUID {
        OperationCenter.shared.start(
            title: "Create Filtered Alignment Track",
            detail: "Preparing \(outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
    }

    static func startMappedReadsAnnotationWorkflowOperation(
        bundleURL: URL,
        outputTrackName: String
    ) -> UUID {
        OperationCenter.shared.start(
            title: "Convert Mapped Reads to Annotations",
            detail: "Preparing \(outputTrackName)...",
            operationType: .bamImport,
            targetBundleURL: bundleURL
        )
    }

    /// Runs `samtools markdup` over all loaded alignment tracks and replaces those tracks in-place.
    private func runMarkDuplicatesWorkflow() {
        guard let bundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before running duplicate workflows.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Mark Duplicates in Alignment Tracks?"
        confirm.informativeText = "This will run samtools markdup for each alignment track in the current bundle and replace existing tracks with duplicate-marked versions."
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "Mark Duplicates")
        confirm.addButton(withTitle: "Cancel")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let window = self.view.window ?? NSApp.keyWindow else { return }
            let confirmResponse = await confirm.beginSheetModal(for: window)
            guard confirmResponse == .alertFirstButtonReturn else { return }
            guard let split = self.parent as? MainSplitViewController else { return }

            self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = true
            split.activityIndicator.show(message: "Marking duplicates...", style: .indeterminate)

            Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await AlignmentDuplicateService.markDuplicatesInBundle(bundleURL: bundleURL)

                DispatchQueue.main.async { [weak self] in
                    guard let self, let split = self.parent as? MainSplitViewController else { return }
                    MainActor.assumeIsolated {
                        self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                        split.activityIndicator.hide()

                        do {
                            try split.viewerController.displayBundle(at: result.bundleURL)
                            // Markdup sets SAM duplicate flag; keep duplicates hidden by default.
                            self.viewModel.readStyleSectionViewModel.showDuplicates = false
                            self.viewModel.readStyleSectionViewModel.onSettingsChanged?()
                            self.presentSimpleAlert(
                                title: "Duplicate Marking Complete",
                                message: "Processed \(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s"). Duplicate-marked tracks are now loaded."
                            )
                        } catch {
                            self.presentSimpleAlert(
                                title: "Reload Failed",
                                message: "Duplicate marking completed, but the bundle could not be reloaded: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let split = self.parent as? MainSplitViewController else { return }
                    MainActor.assumeIsolated {
                        self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                        split.activityIndicator.hide()
                        self.presentSimpleAlert(
                            title: "Duplicate Marking Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
        }
    }

    /// Creates a sibling deduplicated bundle by running `samtools markdup -r` on alignment tracks.
    private func runCreateDeduplicatedBundleWorkflow() {
        guard let sourceBundleURL = viewModel.documentSectionViewModel.bundleURL else {
            presentSimpleAlert(title: "No Bundle Loaded", message: "Load a .lungfishref bundle before creating a deduplicated copy.")
            return
        }
        guard viewModel.readStyleSectionViewModel.hasAlignmentTracks else {
            presentSimpleAlert(title: "No Alignment Tracks", message: "This bundle has no alignment tracks to process.")
            return
        }

        let confirm = NSAlert()
        confirm.messageText = "Create Deduplicated Bundle?"
        confirm.informativeText = "This creates a sibling .lungfishref bundle with duplicate reads removed from all alignment tracks. The current bundle will not be modified."
        confirm.alertStyle = .informational
        confirm.addButton(withTitle: "Create Bundle")
        confirm.addButton(withTitle: "Cancel")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let window = self.view.window ?? NSApp.keyWindow else { return }
            let confirmResponse = await confirm.beginSheetModal(for: window)
            guard confirmResponse == .alertFirstButtonReturn else { return }
            guard let split = self.parent as? MainSplitViewController else { return }

            self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = true
            split.activityIndicator.show(message: "Creating deduplicated bundle...", style: .indeterminate)

            Task(priority: .userInitiated) { [weak self] in
            do {
                let result = try await AlignmentDuplicateService.createDeduplicatedBundle(from: sourceBundleURL)

                DispatchQueue.main.async { [weak self] in
                    guard let self, let split = self.parent as? MainSplitViewController else { return }
                    MainActor.assumeIsolated {
                        self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                        split.activityIndicator.hide()
                        split.sidebarController.reloadFromFilesystem()

                        do {
                            try split.viewerController.displayBundle(at: result.bundleURL)
                            self.presentSimpleAlert(
                                title: "Deduplicated Bundle Created",
                                message: "Processed \(result.processedTracks) alignment track\(result.processedTracks == 1 ? "" : "s"). New bundle: \(result.bundleURL.lastPathComponent)"
                            )
                        } catch {
                            self.presentSimpleAlert(
                                title: "Open New Bundle Failed",
                                message: "Deduplicated bundle was created at \(result.bundleURL.path), but opening it failed: \(error.localizedDescription)"
                            )
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let split = self.parent as? MainSplitViewController else { return }
                    MainActor.assumeIsolated {
                        self.viewModel.readStyleSectionViewModel.isDuplicateWorkflowRunning = false
                        split.activityIndicator.hide()
                        self.presentSimpleAlert(
                            title: "Deduplicated Bundle Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        }
    }

    /// Updates the quality section with new quality data.
    ///
    /// Call this when loading a file to update quality statistics display.
    ///
    /// - Parameters:
    ///   - hasData: Whether the loaded file has quality data (true for FASTQ)
    ///   - statistics: Quality statistics if available
    public func updateQualityData(hasData: Bool, statistics: QualityStatistics?) {
        viewModel.hasQualityData = hasData
        viewModel.qualityStats = statistics
        viewModel.qualitySectionViewModel.update(hasData: hasData, statistics: statistics)
    }

    /// Called by the split view controller when inspector visibility changes.
    ///
    /// Ensures control callbacks and current annotation settings remain active
    /// after collapse/expand transitions.
    public func inspectorVisibilityDidChange(isVisible: Bool) {
        logger.info(
            "inspectorVisibilityDidChange: isVisible=\(isVisible), wasVisible=\(self.wasInspectorVisible)"
        )
        wasInspectorVisible = isVisible

        guard isVisible else { return }

        logger.info("inspectorVisibilityDidChange: refreshing hosting view for visible inspector")
        refreshHostingView()

        ensureInspectorWiring()
        syncAnnotationStateToViewer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - InspectorViewModel

/// View model for the inspector panel.
///
/// Aggregates state for all inspector sections and coordinates
/// between section view models. Supports a tabbed interface with
/// Document, Selection, and AI tabs.
@Observable
@MainActor
public final class InspectorViewModel {
    // MARK: - Content Mode

    var windowStateScope: WindowStateScope?

    /// The current viewport content mode, mirrored from ViewerViewController.
    var contentMode: ViewportContentMode = .empty

    /// Returns the set of inspector tabs available for the current content mode.
    var availableTabs: [InspectorTab] {
        switch contentMode {
        case .genomics:
            return [.bundle, .selectedItem, .view, .analysis, .ai]
        case .mapping:
            return [.bundle, .selectedItem, .view, .analysis]
        case .assembly:
            return [.bundle]
        case .fastq:
            return [.bundle]
        case .metagenomics:
            return [.resultSummary]
        case .empty:
            return [.bundle, .selectedItem]
        }
    }

    // MARK: - Tab State

    /// Currently selected inspector tab.
    var selectedTab: InspectorTab = .bundle

    /// Currently selected read-style subsection inside the View tab.
    var selectedReadStyleViewSubsection: ReadStyleViewSubsection = .alignment

    // MARK: - Sidebar Selection State

    /// Currently selected sidebar item name
    var selectedItem: String?

    /// Currently selected sidebar item type description
    var selectedType: String?

    /// Properties key-value pairs for display
    var properties: [(String, String)] = []

    /// Statistics key-value pairs for display
    var statistics: [(String, String)] = []

    // MARK: - Annotation Selection State

    /// The currently selected annotation, if any
    var selectedAnnotation: SequenceAnnotation?

    // MARK: - Appearance State

    /// Current appearance settings
    var appearance: SequenceAppearance = AppSettings.shared.sequenceAppearance

    // MARK: - Quality State

    /// Whether quality data is available for the current file
    var hasQualityData: Bool = false

    /// Quality statistics for the current file
    var qualityStats: QualityStatistics?

    // MARK: - Section View Models

    /// View model for the document section (bundle metadata)
    let documentSectionViewModel = DocumentSectionViewModel()

    /// View model for the selection section
    let selectionSectionViewModel = SelectionSectionViewModel()

    /// View model for the appearance section
    let appearanceSectionViewModel = AppearanceSectionViewModel()

    /// View model for the quality section
    let qualitySectionViewModel = QualitySectionViewModel()

    /// View model for the annotation section
    let annotationSectionViewModel = AnnotationSectionViewModel()

    /// View model for mapped read style section (BAM/CRAM styling placeholder)
    let readStyleSectionViewModel = ReadStyleSectionViewModel()

    /// View model for variant detail section
    let variantSectionViewModel = VariantSectionViewModel()

    /// View model for sample display controls section
    let sampleSectionViewModel = SampleSectionViewModel()

    /// View model for FASTQ sample metadata section (Document tab)
    let fastqMetadataSectionViewModel = FASTQMetadataSectionViewModel()

    /// Shared AI assistant service for the inspector's AI tab.
    var aiAssistantService: AIAssistantService?

    // MARK: - Initialization

    init() {
        // Initialize appearance section from saved settings
        syncAppearanceToSectionViewModel()
    }

    /// Syncs the main appearance settings to the appearance section view model.
    private func syncAppearanceToSectionViewModel() {
        appearanceSectionViewModel.trackHeight = Double(appearance.trackHeight)
        qualitySectionViewModel.isQualityOverlayEnabled = appearance.showQualityOverlay
    }

    func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }
}

// MARK: - InspectorView (SwiftUI)

/// SwiftUI view for the inspector panel content.
///
/// Displays a Keynote-style tabbed interface with three tabs:
/// - **Document**: Bundle metadata, source info, genome summary, extended metadata
/// - **Selection**: Annotation editing, appearance settings, annotation style, read style
/// - **AI**: Embedded AI assistant chat interface
///
/// Uses fixed-width text controls at the top of the panel for tab switching.
public struct InspectorView: View {
    @Bindable var viewModel: InspectorViewModel

    public var body: some View {
        VStack(spacing: 0) {
            // Tab picker at top — only shows tabs available for current content mode
            tabPicker

            Divider()

            tabContent
        }
        .onChange(of: viewModel.selectedTab) { _, tab in
            guard tab == .ai, viewModel.aiAssistantService == nil else { return }
            NotificationCenter.default.post(
                name: .showAIAssistantRequested,
                object: nil,
                userInfo: viewModel.windowScopedUserInfo()
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tab Picker

    @ViewBuilder
    private var tabPicker: some View {
        let tabs = viewModel.availableTabs
        if tabs.count > 1 {
            InspectorTabGrid(tabs: tabs, selectedTab: $viewModel.selectedTab)
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if let single = tabs.first {
            // Single-tab mode: show a label instead of a picker
            HStack {
                Text(single.displayLabel)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch viewModel.selectedTab {
        case .bundle, .selectedItem, .view, .analysis, .fastqMetadata, .resultSummary:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    tabScrollContent
                    Spacer()
                }
                .padding()
            }

        case .ai:
            if let service = viewModel.aiAssistantService {
                EmbeddedAIAssistantView(service: service)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Assistant")
                        .font(.headline)
                    Text("Enable AI services in Settings > AI Services to use the assistant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var tabScrollContent: some View {
        switch viewModel.selectedTab {
        case .bundle:
            DocumentSection(viewModel: viewModel.documentSectionViewModel)
            if viewModel.readStyleSectionViewModel.hasAlignmentTracks {
                Divider()
                AlignmentBundleSection(viewModel: viewModel.readStyleSectionViewModel)
            }
            // Show FASTQ metadata in Document tab when in FASTQ mode
            if viewModel.contentMode == .fastq {
                FASTQMetadataSection(viewModel: viewModel.fastqMetadataSectionViewModel)
            }

        case .selectedItem:
            SelectionSection(viewModel: viewModel.selectionSectionViewModel)

            // Variant detail (shown when a variant is selected)
            VariantSection(viewModel: viewModel.variantSectionViewModel)

            if viewModel.readStyleSectionViewModel.selectedRead != nil {
                Divider()
                ReadSelectionSection(viewModel: viewModel.readStyleSectionViewModel)
            }

        case .view:
            InspectorReadStyleSection(viewModel: viewModel)

        case .analysis:
            InspectorAnalysisWorkflowSection(viewModel: viewModel)

        case .fastqMetadata:
            FASTQMetadataSection(viewModel: viewModel.fastqMetadataSectionViewModel)

        case .resultSummary:
            MetagenomicsResultSummarySection(
                viewModel: viewModel.documentSectionViewModel,
                windowStateScope: viewModel.windowStateScope
            )

        case .ai:
            EmptyView()
        }
    }
}

// MARK: - InspectorTab Helpers

private struct InspectorTabGrid: View {
    let tabs: [InspectorTab]
    @Binding var selectedTab: InspectorTab

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: 6),
            count: tabs.count > 3 ? 2 : max(tabs.count, 1)
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(tabs, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.displayLabel)
                        .font(.caption.weight(selectedTab == tab ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .padding(.horizontal, 4)
                        .background(tabBackground(for: tab))
                        .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(tab.displayLabel)
            }
        }
        .accessibilityLabel("Inspector")
    }

    @ViewBuilder
    private func tabBackground(for tab: InspectorTab) -> some View {
        if selectedTab == tab {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
        }
    }
}

extension InspectorTab {
    /// SF Symbol name for this tab's picker icon.
    var iconName: String {
        switch self {
        case .bundle: return "shippingbox"
        case .selectedItem: return "scope"
        case .view: return "eye"
        case .analysis: return "arrow.triangle.branch"
        case .ai: return "sparkles"
        case .fastqMetadata: return "tag"
        case .resultSummary: return "chart.bar"
        }
    }

    /// Human-readable label for single-tab headers.
    var displayLabel: String {
        switch self {
        case .bundle: return "Bundle"
        case .selectedItem: return "Selected Item"
        case .view: return "View"
        case .analysis: return "Analysis"
        case .ai: return "Assistant"
        case .fastqMetadata: return "Sample Metadata"
        case .resultSummary: return "Summary"
        }
    }
}

private struct InspectorReadStyleSection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("View Settings")
                .font(.headline)

            if viewModel.contentMode == .mapping {
                MappingViewSettingsSection(viewModel: viewModel.documentSectionViewModel)
                Divider()
            }

            InspectorSubsectionGrid(selection: $viewModel.selectedReadStyleViewSubsection)

            subsectionContent
        }
    }

    @ViewBuilder
    private var subsectionContent: some View {
        switch viewModel.selectedReadStyleViewSubsection {
        case .alignment:
            AlignmentViewSection(viewModel: viewModel.readStyleSectionViewModel)
        case .annotations:
            InspectorAnnotationDisplaySection(viewModel: viewModel)
        case .reads:
            ReadStyleSection(viewModel: viewModel.readStyleSectionViewModel)
        }
    }
}

private struct InspectorSubsectionGrid: View {
    @Binding var selection: ReadStyleViewSubsection

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: 6),
        count: ReadStyleViewSubsection.allCases.count
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(ReadStyleViewSubsection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Text(section.displayTitle)
                        .font(.caption.weight(selection == section ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .padding(.horizontal, 3)
                        .background(sectionBackground(for: section))
                        .foregroundStyle(selection == section ? Color.white : Color.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(section.displayTitle)
            }
        }
        .accessibilityLabel("View Section")
    }

    @ViewBuilder
    private func sectionBackground(for section: ReadStyleViewSubsection) -> some View {
        if selection == section {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
        }
    }
}

private struct InspectorAnalysisWorkflowSection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        AnalysisSection(viewModel: viewModel.readStyleSectionViewModel)
    }
}

private struct InspectorAnnotationDisplaySection: View {
    @Bindable var viewModel: InspectorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sequence, annotation, and sample display controls are grouped here so the main View tab stays easier to scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AppearanceSection(viewModel: viewModel.appearanceSectionViewModel)

            Divider()

            AnnotationSection(viewModel: viewModel.annotationSectionViewModel)

            if viewModel.sampleSectionViewModel.hasVariantData {
                Divider()
                SampleSection(viewModel: viewModel.sampleSectionViewModel)
            }
        }
    }
}

private struct InspectorAlignmentVisibilitySection: View {
    @Bindable var readStyleViewModel: ReadStyleSectionViewModel
    @Bindable var documentViewModel: DocumentSectionViewModel
    let contentMode: ViewportContentMode

    private let allAlignmentsSelectionID = "__all_alignments__"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if contentMode == .mapping {
                MappingViewSettingsSection(viewModel: documentViewModel)
                Divider()
            }

            if readStyleViewModel.hasAlignmentTracks {
                Text("Choose whether the viewer shows every alignment track together or just one alignment track at a time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Visible Alignment", selection: visibleAlignmentSelection) {
                    Text("All Alignments").tag(allAlignmentsSelectionID)
                    ForEach(readStyleViewModel.visibleAlignmentTrackOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .disabled(readStyleViewModel.visibleAlignmentTrackOptions.isEmpty)

                Text(visibleAlignmentSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Toggle("Show reads", isOn: $readStyleViewModel.showReads)
                    .onChange(of: readStyleViewModel.showReads) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Minimum MAPQ")
                    Spacer()
                    Text("\(Int(readStyleViewModel.minMapQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $readStyleViewModel.minMapQ, in: 0...60, step: 1)
                    .onChange(of: readStyleViewModel.minMapQ) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Text("Read Inclusion")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Include duplicate-marked reads", isOn: $readStyleViewModel.showDuplicates)
                    .onChange(of: readStyleViewModel.showDuplicates) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Toggle("Include secondary alignments", isOn: $readStyleViewModel.showSecondary)
                    .onChange(of: readStyleViewModel.showSecondary) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                Toggle("Include supplementary alignments", isOn: $readStyleViewModel.showSupplementary)
                    .onChange(of: readStyleViewModel.showSupplementary) { _, _ in
                        readStyleViewModel.onSettingsChanged?()
                    }

                if readStyleViewModel.readGroups.count > 1 {
                    Divider()
                    readGroupControls
                }
            } else {
                Text("No alignment tracks loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Import a BAM or CRAM file via File > Import Center to enable alignment-specific view controls.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var visibleAlignmentSelection: Binding<String> {
        Binding(
            get: { readStyleViewModel.selectedVisibleAlignmentTrackID ?? allAlignmentsSelectionID },
            set: { newValue in
                readStyleViewModel.selectedVisibleAlignmentTrackID = newValue == allAlignmentsSelectionID ? nil : newValue
                documentViewModel.visibleAlignmentTrackID = readStyleViewModel.selectedVisibleAlignmentTrackID
                readStyleViewModel.onSettingsChanged?()
            }
        )
    }

    private var visibleAlignmentSummary: String {
        guard let selectedVisibleAlignmentTrackID = readStyleViewModel.selectedVisibleAlignmentTrackID else {
            return "Showing reads from every alignment track in this bundle."
        }

        let trackName = readStyleViewModel.visibleAlignmentTrackOptions
            .first(where: { $0.id == selectedVisibleAlignmentTrackID })?.name ?? selectedVisibleAlignmentTrackID
        return "Showing only \(trackName). Choose All Alignments to return to the aggregate view."
    }

    @ViewBuilder
    private var readGroupControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read Groups")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(readStyleViewModel.readGroups) { rg in
                Toggle(isOn: Binding(
                    get: {
                        readStyleViewModel.selectedReadGroups.isEmpty || readStyleViewModel.selectedReadGroups.contains(rg.rgId)
                    },
                    set: { isOn in
                        if readStyleViewModel.selectedReadGroups.isEmpty {
                            var all = Set(readStyleViewModel.readGroups.map(\.rgId))
                            if !isOn { all.remove(rg.rgId) }
                            readStyleViewModel.selectedReadGroups = all
                        } else if isOn {
                            readStyleViewModel.selectedReadGroups.insert(rg.rgId)
                            if readStyleViewModel.selectedReadGroups.count == readStyleViewModel.readGroups.count {
                                readStyleViewModel.selectedReadGroups = []
                            }
                        } else {
                            readStyleViewModel.selectedReadGroups.remove(rg.rgId)
                        }
                        readStyleViewModel.onSettingsChanged?()
                    }
                )) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(rg.rgId)
                            .font(.system(.caption, design: .monospaced))
                        if let sample = rg.sample {
                            Text(sample)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

private struct InspectorReadRenderingSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Maximum rows")
                    Spacer()
                    Text("\(Int(viewModel.maxReadRows))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .opacity(viewModel.limitReadRows ? 1.0 : 0.5)

                Slider(value: $viewModel.maxReadRows, in: 10...2000, step: 10)
                    .disabled(!viewModel.limitReadRows)
                    .onChange(of: viewModel.maxReadRows) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Limit visible rows", isOn: $viewModel.limitReadRows)
                    .onChange(of: viewModel.limitReadRows) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Off keeps all mapped reads in the active view and enables stable vertical scrolling.")

                Toggle("Use compact row height", isOn: $viewModel.verticallyCompressContig)
                    .onChange(of: viewModel.verticallyCompressContig) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("Compact mode uses smaller row heights to fit more reads on screen.")

                Divider()

                Toggle("Show matching bases as dots", isOn: $viewModel.showMismatches)
                    .onChange(of: viewModel.showMismatches) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, matching bases are shown as dots and mismatches as colored letters. When off, all bases are shown as letters. Mismatches remain highlighted.")

                Toggle("Show soft-clipped sequence", isOn: $viewModel.showSoftClips)
                    .onChange(of: viewModel.showSoftClips) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Show insertion and deletion markers", isOn: $viewModel.showIndels)
                    .onChange(of: viewModel.showIndels) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Divider()

                Toggle("Color reads by strand", isOn: $viewModel.showStrandColors)
                    .onChange(of: viewModel.showStrandColors) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When on, forward reads are blue-tinted and reverse reads are pink-tinted. When off, all reads have a neutral gray background.")

                Divider()

                HStack {
                    Text("Forward strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.forwardReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.forwardReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }

                HStack {
                    Text("Reverse strand color")
                    Spacer()
                    ColorPicker("", selection: $viewModel.reverseReadColor, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: viewModel.reverseReadColor) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InspectorFilteringWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel
    @State private var alignmentFilterValidationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creates a new alignment in this bundle. The original alignment stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let latestDerivedAlignmentMessage = viewModel.latestDerivedAlignmentMessage,
               !latestDerivedAlignmentMessage.isEmpty {
                Text(latestDerivedAlignmentMessage)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            if viewModel.hasAlignmentTracks {
                Text("Duplicate handling")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Mark Duplicates in Bundle Tracks") {
                    viewModel.onMarkDuplicatesRequested?()
                }
                .disabled(viewModel.isDuplicateWorkflowRunning)

                if viewModel.isDuplicateWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running duplicate workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Picker(
                    "Starting Alignment",
                    selection: Binding(
                        get: { viewModel.selectedAlignmentFilterSourceTrackID ?? "" },
                        set: { newValue in
                            alignmentFilterValidationMessage = nil
                            viewModel.selectedAlignmentFilterSourceTrackID = newValue.isEmpty ? nil : newValue
                        }
                    )
                ) {
                    if viewModel.alignmentFilterTrackOptions.isEmpty {
                        Text("No alignment tracks").tag("")
                    } else {
                        ForEach(viewModel.alignmentFilterTrackOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                .disabled(viewModel.alignmentFilterTrackOptions.isEmpty)

                Toggle("Keep mapped reads only", isOn: Binding(
                    get: { viewModel.alignmentFilterMappedOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterMappedOnly = newValue
                    }
                ))

                Toggle("Keep one primary alignment per read", isOn: Binding(
                    get: { viewModel.alignmentFilterPrimaryOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterPrimaryOnly = newValue
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Minimum alignment confidence")
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { viewModel.alignmentFilterMinimumMAPQ },
                                set: { newValue in
                                    alignmentFilterValidationMessage = nil
                                    viewModel.alignmentFilterMinimumMAPQ = newValue
                                }
                            ),
                            in: 0...255
                        ) {
                            Text("\(viewModel.alignmentFilterMinimumMAPQ)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .labelsHidden()
                    }
                    Text("Uses SAM MAPQ. Set to 0 to keep every alignment confidence level.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Picker("Duplicate handling", selection: Binding(
                    get: { viewModel.alignmentFilterDuplicateMode },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterDuplicateMode = newValue
                    }
                )) {
                    ForEach(AlignmentFilterInspectorDuplicateChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }

                Toggle("Keep reads with zero mismatches to reference", isOn: Binding(
                    get: { viewModel.alignmentFilterExactMatchOnly },
                    set: { newValue in
                        alignmentFilterValidationMessage = nil
                        viewModel.alignmentFilterExactMatchOnly = newValue
                    }
                ))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Minimum identity to reference (%)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        viewModel.alignmentFilterExactMatchOnly ? "Disabled while exact-match filtering is on" : "Leave blank to keep all",
                        text: Binding(
                            get: { viewModel.alignmentFilterMinimumPercentIdentityText },
                            set: { newValue in
                                alignmentFilterValidationMessage = nil
                                viewModel.alignmentFilterMinimumPercentIdentityText = newValue
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.alignmentFilterExactMatchOnly)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Name for New Alignment")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Filtered alignment name",
                        text: Binding(
                            get: { viewModel.alignmentFilterOutputTrackName },
                            set: { newValue in
                                alignmentFilterValidationMessage = nil
                                viewModel.alignmentFilterOutputTrackName = newValue
                            }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                Button("Create Filtered Alignment") {
                    do {
                        let request = try viewModel.makeAlignmentFilterLaunchRequest()
                        alignmentFilterValidationMessage = nil
                        viewModel.onCreateFilteredAlignmentRequested?(request)
                    } catch {
                        alignmentFilterValidationMessage = error.localizedDescription
                    }
                }
                .disabled(viewModel.isAlignmentFilterWorkflowRunning)

                if viewModel.isAlignmentFilterWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running BAM filter workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let alignmentFilterValidationMessage, !alignmentFilterValidationMessage.isEmpty {
                    Text(alignmentFilterValidationMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No alignment tracks loaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Import a BAM or CRAM file before creating a filtered alignment.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

private struct InspectorConsensusWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Consensus controls live under Analysis so the View tab stays focused on reversible display settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Show consensus track in viewer", isOn: $viewModel.showConsensusTrack)
                    .onChange(of: viewModel.showConsensusTrack) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Picker("Consensus Mode", selection: $viewModel.consensusMode) {
                    Text("Bayesian").tag(AlignmentConsensusMode.bayesian)
                    Text("Simple").tag(AlignmentConsensusMode.simple)
                }
                .pickerStyle(.segmented)
                .onChange(of: viewModel.consensusMode) { _, _ in
                    viewModel.onSettingsChanged?()
                }

                Toggle("Use IUPAC ambiguity codes", isOn: $viewModel.consensusUseAmbiguity)
                    .onChange(of: viewModel.consensusUseAmbiguity) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Toggle("Hide high-gap sites", isOn: $viewModel.consensusMaskingEnabled)
                    .onChange(of: viewModel.consensusMaskingEnabled) { _, _ in
                        viewModel.onSettingsChanged?()
                    }
                    .help("When enabled, columns where most spanning reads are gaps are masked in packed or base views.")

                HStack {
                    Text("Consensus minimum depth")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinDepth))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinDepth, in: 1...50, step: 1)
                    .onChange(of: viewModel.consensusMinDepth) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                if viewModel.consensusMaskingEnabled {
                    HStack {
                        Text("Gap threshold")
                        Spacer()
                        Text("\(Int(viewModel.consensusGapThresholdPercent))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.consensusGapThresholdPercent, in: 50...99, step: 1)
                        .onChange(of: viewModel.consensusGapThresholdPercent) { _, _ in
                            viewModel.onSettingsChanged?()
                        }

                    HStack {
                        Text("Masking minimum depth")
                        Spacer()
                        Text("\(Int(viewModel.consensusMaskingMinDepth))")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $viewModel.consensusMaskingMinDepth, in: 1...50, step: 1)
                        .onChange(of: viewModel.consensusMaskingMinDepth) { _, _ in
                            viewModel.onSettingsChanged?()
                        }
                }

                HStack {
                    Text("Consensus minimum MAPQ")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinMapQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinMapQ, in: 0...60, step: 1)
                    .onChange(of: viewModel.consensusMinMapQ) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                HStack {
                    Text("Consensus minimum base quality")
                    Spacer()
                    Text("\(Int(viewModel.consensusMinBaseQ))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $viewModel.consensusMinBaseQ, in: 0...60, step: 1)
                    .onChange(of: viewModel.consensusMinBaseQ) { _, _ in
                        viewModel.onSettingsChanged?()
                    }

                Divider()

                Button("Extract Consensus…") {
                    viewModel.onExtractConsensusRequested?()
                }
                .disabled(!viewModel.supportsConsensusExtraction)

                if !viewModel.supportsConsensusExtraction {
                    Text("Consensus extraction is available from the active mapping viewer.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InspectorVariantCallingWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run BAM-backed variant calling from the current bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if viewModel.hasVariantCallableAlignmentTracks {
                    Text("Use this when you want site-by-site sequence differences summarized as a reusable variant track.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Variant calling is unavailable until this bundle includes an indexed BAM alignment track.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Call Variants…") {
                    viewModel.onCallVariantsRequested?()
                }
                .disabled(!viewModel.hasVariantCallableAlignmentTracks)
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Import a BAM or CRAM file before running variant-calling workflows.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct InspectorExportWorkflowSection: View {
    @Bindable var viewModel: ReadStyleSectionViewModel

    var body: some View {
        if viewModel.hasAlignmentTracks {
            VStack(alignment: .leading, spacing: 8) {
                Text("Create a separate bundle-level output from the current alignment tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Text("Use export when you want a new bundle for downstream work without changing the original mapping bundle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Create Deduplicated Bundle") {
                    viewModel.onCreateDeduplicatedBundleRequested?()
                }
                .disabled(viewModel.isDuplicateWorkflowRunning)

                if viewModel.isDuplicateWorkflowRunning {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running duplicate workflow...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("No alignment tracks loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Import a BAM or CRAM file before exporting a deduplicated bundle.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct MappingViewSettingsSection: View {
    @Bindable var viewModel: DocumentSectionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mapping Layout")
                .font(.headline)

            Text("Choose how the contig list and genome detail panes share the mapping viewer.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Layout", selection: Binding(
                get: { viewModel.mappingPanelLayout },
                set: { newValue in
                    viewModel.mappingPanelLayout = newValue
                    newValue.persist()
                }
            )) {
                Text("Detail left, list right").tag(MappingPanelLayout.detailLeading)
                Text("List left, detail right").tag(MappingPanelLayout.listLeading)
                Text("List above detail").tag(MappingPanelLayout.stacked)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Divider()

            bundleScrollDirectionPicker
        }
    }

    private var bundleScrollDirectionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bundle Scroll Direction")
                .font(.headline)

            Picker("Horizontal Scroll", selection: Binding(
                get: { viewModel.bundleHorizontalScrollDirection },
                set: { newValue in
                    viewModel.bundleHorizontalScrollDirection = newValue
                    ReferenceBundleScrollDirectionPreference.persist(newValue)
                }
            )) {
                ForEach(ScrollDirectionPreference.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }
}

// MARK: - MetagenomicsResultSummarySection

/// A minimal inspector section for metagenomics result views.
///
/// Shows pipeline/run information when a TaxTriage, EsViritu, or Kraken2
/// result is displayed. Re-uses DocumentSectionViewModel data when available,
/// otherwise shows a "No result information" placeholder.
private struct MetagenomicsResultSummarySection: View {
    @Bindable var viewModel: DocumentSectionViewModel
    let windowStateScope: WindowStateScope?
    @State private var isSamplesExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let manifest = viewModel.manifest {
                metadataRow("Organism", value: manifest.source.organism)
                metadataRow("Assembly", value: manifest.source.assembly)
            }

            if let naoManifest = viewModel.naoMgsManifest {
                naoMgsSection(naoManifest)
            }

            if let nvdManifest = viewModel.nvdManifest {
                nvdSection(nvdManifest)
            }

            if viewModel.hasAnyContent {
                Text("See the viewer for detailed results. Use the bottom drawer for BLAST verification and sample navigation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Select a metagenomics result in the sidebar to view its summary here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Panel Layout")
                    .font(.caption.weight(.semibold))

                Picker("Layout", selection: Binding(
                    get: { viewModel.metagenomicsPanelLayout },
                    set: { newValue in
                        viewModel.metagenomicsPanelLayout = newValue
                        newValue.persist()
                    }
                )) {
                    Label("Detail | List", systemImage: "sidebar.left")
                        .tag(MetagenomicsPanelLayout.detailLeading)
                    Label("List | Detail", systemImage: "sidebar.right")
                        .tag(MetagenomicsPanelLayout.listLeading)
                    Label("List Over Detail", systemImage: "rectangle.split.1x2")
                        .tag(MetagenomicsPanelLayout.stacked)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            if let tool = viewModel.batchOperationTool {
                BatchOperationDetailsSection(
                    tool: tool,
                    parameters: viewModel.batchOperationParameters,
                    timestamp: viewModel.batchOperationTimestamp,
                    manifestStatus: viewModel.batchManifestStatus
                )
                Divider()
                    .padding(.vertical, 4)
            }

            Divider()
                .padding(.vertical, 4)

            DisclosureGroup("Samples & Metadata", isExpanded: $isSamplesExpanded) {
                if let pickerState = viewModel.classifierPickerState,
                   !viewModel.classifierSampleEntries.isEmpty {
                    Divider()
                        .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sample Filter")
                            .font(.caption.weight(.semibold))

                        ClassifierSamplePickerView(
                            samples: viewModel.classifierSampleEntries,
                            pickerState: pickerState,
                            strippedPrefix: viewModel.classifierStrippedPrefix,
                            isInline: true
                        )
                    }
                    .onChange(of: pickerState.selectedSamples) { _, _ in
                        NotificationCenter.default.post(
                            name: .metagenomicsSampleSelectionChanged,
                            object: nil,
                            userInfo: windowScopedUserInfo()
                        )
                    }
                }

                // Import Metadata button (when no metadata loaded yet)
                if viewModel.sampleMetadataStore == nil {
                    Divider().padding(.vertical, 4)
                    Button("Import Metadata\u{2026}") {
                        NotificationCenter.default.post(
                            name: .metagenomicsMetadataImportRequested,
                            object: nil,
                            userInfo: windowScopedUserInfo()
                        )
                    }
                    .controlSize(.small)
                }

                // Sample Metadata section
                if let metadataStore = viewModel.sampleMetadataStore {
                    Divider().padding(.vertical, 4)
                    SampleMetadataSection(store: metadataStore)
                }

                // Attachments section
                if let attachmentStore = viewModel.bundleAttachmentStore {
                    Divider().padding(.vertical, 4)
                    AttachmentsSection(store: attachmentStore)
                }
            }
            .font(.caption.weight(.semibold))

            if !viewModel.batchSourceSampleURLs.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                SourceSamplesSection(
                    samples: viewModel.batchSourceSampleURLs,
                    onNavigateToBundle: { url in
                        NotificationCenter.default.post(
                            name: .navigateToSidebarItem,
                            object: nil,
                            userInfo: windowScopedUserInfo(["url": url])
                        )
                    }
                )
            }
        }
    }

    private func windowScopedUserInfo(_ userInfo: [AnyHashable: Any]? = nil) -> [AnyHashable: Any]? {
        guard let windowStateScope else { return userInfo }
        var scopedUserInfo = userInfo ?? [:]
        scopedUserInfo[NotificationUserInfoKey.windowStateScope] = windowStateScope
        return scopedUserInfo
    }

    @ViewBuilder
    private func naoMgsSection(_ manifest: NaoMgsManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAO-MGS Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            metadataRow("Sample", value: manifest.sampleName)
            metadataRow("Virus Hits", value: "\(manifest.hitCount)")
            metadataRow("Unique Taxa", value: "\(manifest.taxonCount)")
            if let topTaxon = manifest.topTaxon {
                metadataRow("Top Taxon", value: topTaxon)
            }
            if let version = manifest.workflowVersion {
                metadataRow("Workflow", value: "NAO-MGS v\(version)")
            }
            metadataRow("Source", value: (manifest.sourceFilePath as NSString).lastPathComponent)
            metadataRow("Imported", value: {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: manifest.importDate)
            }())
            if !manifest.fetchedAccessions.isEmpty {
                metadataRow("References", value: "\(manifest.fetchedAccessions.count) fetched")
            }
        }
    }

    @ViewBuilder
    private func nvdSection(_ manifest: NvdManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NVD Result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            metadataRow("Experiment", value: manifest.experiment)
            metadataRow("Samples", value: "\(manifest.sampleCount)")
            metadataRow("Contigs", value: "\(manifest.contigCount)")
            metadataRow("BLAST Hits", value: "\(manifest.hitCount)")
            if let blastDbVersion = manifest.blastDbVersion {
                metadataRow("BLAST DB", value: blastDbVersion)
            }
            if let runId = manifest.snakemakeRunId {
                metadataRow("Run ID", value: runId)
            }
            metadataRow("Imported", value: {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                return formatter.string(from: manifest.importDate)
            }())
        }
    }

    @ViewBuilder
    private func metadataRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}

private struct EmbeddedAIAssistantView: NSViewControllerRepresentable {
    let service: AIAssistantService

    func makeNSViewController(context: Context) -> AIAssistantViewController {
        AIAssistantViewController(service: service)
    }

    func updateNSViewController(_ controller: AIAssistantViewController, context: Context) {
        _ = controller
    }
}

// MARK: - SidebarItemType Extension

extension SidebarItemType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .group: return "Group"
        case .folder: return "Folder"
        case .sequence: return "Sequence"
        case .annotation: return "Annotation"
        case .alignment: return "Alignment"
        case .coverage: return "Coverage"
        case .project: return "Project"
        case .document: return "Document"
        case .image: return "Image"
        case .unknown: return "File"
        case .referenceBundle: return "Reference Bundle"
        case .fastqBundle: return "FASTQ Bundle"
        case .primerSchemeBundle: return "Primer Scheme"
        case .batchGroup: return "Batch Operation"
        case .classificationResult: return "Classification Result"
        case .esvirituResult: return "Viral Detection Result"
        case .taxTriageResult: return "Comprehensive Triage Result"
        case .naoMgsResult: return "NAO-MGS Surveillance Result"
        case .nvdResult: return "NVD Classification Result"
        case .analysisResult: return "Analysis Result"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct InspectorView_Previews: PreviewProvider {
    static var previews: some View {
        let viewModel = InspectorViewModel()
        viewModel.selectedItem = "chr1.fa"
        viewModel.selectedType = "Sequence"

        // Set up sample annotation
        viewModel.selectionSectionViewModel.select(annotation: SequenceAnnotation(
            type: .gene,
            name: "BRCA1",
            start: 1000,
            end: 5000,
            strand: .forward,
            note: "Breast cancer susceptibility gene"
        ))

        // Set up sample quality data
        viewModel.qualitySectionViewModel.update(
            hasData: true,
            statistics: QualityStatistics(
                meanQuality: 32.5,
                q20Percentage: 95.2,
                q30Percentage: 87.8,
                totalBases: 1_234_567,
                minQuality: 2,
                maxQuality: 40
            )
        )

        // Set up sample document metadata
        viewModel.documentSectionViewModel.update(
            manifest: BundleManifest(
                name: "Human Reference Genome",
                identifier: "org.lungfish.hg38",
                source: SourceInfo(
                    organism: "Homo sapiens",
                    commonName: "Human",
                    taxonomyId: 9606,
                    assembly: "GRCh38",
                    assemblyAccession: "GCF_000001405.40",
                    database: "NCBI"
                ),
                genome: GenomeInfo(
                    path: "genome/sequence.fa.gz",
                    indexPath: "genome/sequence.fa.gz.fai",
                    totalLength: 3_088_286_401,
                    chromosomes: [
                        ChromosomeInfo(
                            name: "chr1",
                            length: 248_956_422,
                            offset: 0,
                            lineBases: 80,
                            lineWidth: 81
                        )
                    ]
                )
            ),
            bundleURL: URL(fileURLWithPath: "/tmp/test.lungfishref")
        )

        return InspectorView(viewModel: viewModel)
            .frame(width: 280, height: 800)
    }
}
#endif
