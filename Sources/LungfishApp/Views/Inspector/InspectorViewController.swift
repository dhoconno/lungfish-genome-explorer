// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTwelveSUI
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import os.log
import LungfishKit

/// Logger for inspector operations
internal let inspectorLogger = Logger(subsystem: LogSubsystem.app, category: "InspectorViewController")
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

    var genotypeResultDisplaySectionViewModel: GenotypeResultDisplaySectionViewModel {
        viewModel.genotypeResultDisplaySectionViewModel
    }

    var twelveSResultDisplaySectionViewModel: TwelveSResultDisplaySectionViewModel {
        viewModel.twelveSResultDisplaySectionViewModel
    }

    /// Public access to the read style section view model for wiring alignment data.
    public var readStyleSectionViewModel: ReadStyleSectionViewModel {
        viewModel.readStyleSectionViewModel
    }

    var onGenotypeResultDisplayStateChanged: ((GenotypeResultDisplayState) -> Void)?
    var onTwelveSResultDisplayStateChanged: ((TwelveSResultDisplayState) -> Void)?
    var onGenotypeSampleMetadataImported: ((SampleMetadataStore) -> Void)?

    /// Public access to the FASTQ metadata section view model.
    public var fastqMetadataSectionViewModel: FASTQMetadataSectionViewModel {
        viewModel.fastqMetadataSectionViewModel
    }

    /// Access to the generic provenance section view model.
    var provenanceSectionViewModel: ProvenanceInspectorViewModel {
        viewModel.provenanceSectionViewModel
    }

    /// Prevents duplicate NotificationCenter observer registration.
    private var hasRegisteredNotificationObservers = false

    /// Tracks last split-view visibility reported by MainSplitViewController.
    var wasInspectorVisible = true

    var windowStateScope: WindowStateScope? {
        didSet {
            viewModel.windowStateScope = windowStateScope
        }
    }
    var activeContentSelectionIdentity: ContentSelectionIdentity?
    var selectedFASTQMetadataTargetBundleURLs: [URL] = []

    // MARK: - Lifecycle

    public override func loadView() {
        let inspectorView = InspectorView(viewModel: viewModel)
        hostingView = NSHostingView(rootView: inspectorView)
        // Give an initial frame so split view has something to work with
        hostingView.frame = NSRect(x: 0, y: 0, width: 340, height: 500)
        self.view = hostingView
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        ensureInspectorWiring()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetadataImportRequested(_:)),
            name: .metagenomicsMetadataImportRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGenotypeViewModeChanged(_:)),
            name: .genotypeResultViewModeChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGenotypeShowsAncillaryLociChanged(_:)),
            name: .genotypeResultShowsAncillaryLociChanged,
            object: nil
        )
    }

    @objc private func handleGenotypeViewModeChanged(_ notification: Notification) {
        guard let raw = notification.userInfo?["mode"] as? String,
              let mode = GenotypeSummaryViewMode(rawValue: raw) else { return }
        viewModel.genotypeResultDisplaySectionViewModel.setSummaryViewMode(mode)
        if let state = viewModel.documentSectionViewModel.genotypeResultDocument {
            viewModel.documentSectionViewModel.updateGenotypeResultDocument(
                state.replacing(summaryViewMode: mode)
            )
        }
    }

    @objc private func handleGenotypeShowsAncillaryLociChanged(_ notification: Notification) {
        guard let value = notification.userInfo?["showsAncillaryLoci"] as? Bool else { return }
        viewModel.genotypeResultDisplaySectionViewModel.setShowsAncillaryLoci(value)
        // Mirror into the Document section's state so the toggle in SwiftUI
        // reflects the new value on the next render pass.
        if let state = viewModel.documentSectionViewModel.genotypeResultDocument {
            viewModel.documentSectionViewModel.updateGenotypeResultDocument(
                state.replacing(showsAncillaryLoci: value)
            )
        }
    }

    public override func viewWillAppear() {
        super.viewWillAppear()
        inspectorLogger.info("viewWillAppear: Inspector view appearing")
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

    var testingSelectedTab: InspectorTab {
        viewModel.selectedTab
    }

    func testingHandleSidebarSelectionChanged(_ notification: Notification) {
        selectionDidChange(notification)
    }

    func testingHandleBatchManifestCached(_ notification: Notification) {
        handleBatchManifestCached(notification)
    }

    func testingHandleMetadataImportRequested(_ notification: Notification) -> Bool {
        handleMetadataImportRequested(notification, shouldPresentPanel: false)
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
        viewModel.selectionSectionViewModel.onApplyAlignmentAnnotationRequested = { [weak self] in
            self?.handleApplyAlignmentAnnotationRequested()
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

        viewModel.genotypeResultDisplaySectionViewModel.onDisplayStateChanged = { [weak self] state in
            self?.onGenotypeResultDisplayStateChanged?(state)
        }

        viewModel.twelveSResultDisplaySectionViewModel.onDisplayStateChanged = { [weak self] state in
            self?.onTwelveSResultDisplayStateChanged?(state)
        }

        // Annotation section callbacks
        viewModel.annotationSectionViewModel.onSettingsChanged = { [weak self] in
            self?.handleAnnotationSettingsChanged()
        }

        viewModel.annotationSectionViewModel.onFilterChanged = { [weak self] visibleTypes, filterText in
            self?.handleAnnotationFilterChanged(visibleTypes: visibleTypes, filterText: filterText)
        }

        viewModel.provenanceSectionViewModel.onExportRequested = { [weak self] format in
            self?.presentProvenanceExport(format: format)
        }
    }

    /// Ensures notification observers and section callbacks are bound.
    ///
    /// Rebinding callbacks on appearance keeps inspector controls active across
    /// inspector show/hide and view lifecycle transitions.
    func ensureInspectorWiring() {
        setupNotificationObservers()
        setupViewModelCallbacks()
        inspectorLogger.debug(
            "ensureInspectorWiring: callbacks settings=\(self.viewModel.annotationSectionViewModel.onSettingsChanged == nil ? "nil" : "set", privacy: .public) filter=\(self.viewModel.annotationSectionViewModel.onFilterChanged == nil ? "nil" : "set", privacy: .public)"
        )
    }

    /// Broadcasts current annotation inspector state to viewers.
    ///
    /// Keeps viewer rendering synchronized when switching content and when the
    /// inspector panel is re-shown.
    func syncAnnotationStateToViewer() {
        handleAnnotationSettingsChanged()
        handleAnnotationFilterChanged(
            visibleTypes: viewModel.annotationSectionViewModel.visibleTypes,
            filterText: viewModel.annotationSectionViewModel.filterText
        )
    }

    /// Handles annotation display settings changes.
    private func handleAnnotationSettingsChanged() {
        inspectorLogger.info("handleAnnotationSettingsChanged: Annotation settings changed")

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
        inspectorLogger.info("handleAnnotationFilterChanged: Filter updated - types=\(visibleTypes.count) text='\(filterText, privacy: .public)'")

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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
