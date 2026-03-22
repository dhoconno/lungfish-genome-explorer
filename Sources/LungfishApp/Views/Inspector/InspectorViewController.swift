// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Combine
import LungfishCore
import LungfishIO
import os.log
import UniformTypeIdentifiers

/// Logger for inspector operations
private let logger = Logger(subsystem: LogSubsystem.app, category: "InspectorViewController")

// MARK: - InspectorTab

/// Tab selection for the inspector panel's segmented control.
///
/// The inspector supports three tabs:
/// - `document`: Shows bundle-level metadata (organism, assembly, source info, NCBI metadata)
/// - `selection`: Shows editing controls (annotation selection, appearance, annotation style, read style)
/// - `ai`: Shows the embedded AI assistant chat interface
enum InspectorTab: String, CaseIterable {
    /// Bundle metadata and source information.
    case document
    /// Annotation selection editing and style controls.
    case selection
    /// Embedded AI assistant.
    case ai
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

    /// View model for the inspector
    private var viewModel = InspectorViewModel()

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

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Prevents duplicate NotificationCenter observer registration.
    private var hasRegisteredNotificationObservers = false

    /// Tracks last split-view visibility reported by MainSplitViewController.
    private var wasInspectorVisible = true

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
        viewModel.selectionSectionViewModel.onExtractSequence = { annotation in
            NotificationCenter.default.post(
                name: .extractSequenceRequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        viewModel.selectionSectionViewModel.onCopyAsFASTA = { annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationAsFASTARequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        viewModel.selectionSectionViewModel.onCopyTranslationAsFASTA = { annotation in
            NotificationCenter.default.post(
                name: .copyTranslationAsFASTARequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        viewModel.selectionSectionViewModel.onCopySequence = { annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationSequenceRequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        viewModel.selectionSectionViewModel.onCopyReverseComplement = { annotation in
            NotificationCenter.default.post(
                name: .copyAnnotationReverseComplementRequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
            )
        }
        viewModel.selectionSectionViewModel.onZoomToAnnotation = { annotation in
            NotificationCenter.default.post(
                name: .zoomToAnnotationRequested,
                object: nil,
                userInfo: [NotificationUserInfoKey.annotation: annotation]
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
        viewModel.variantSectionViewModel.onZoomToVariant = { variant in
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
                userInfo: [NotificationUserInfoKey.annotation: annotation]
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
            userInfo: [
                "showAnnotations": viewModel.annotationSectionViewModel.showAnnotations,
                "annotationHeight": viewModel.annotationSectionViewModel.annotationHeight,
                "annotationSpacing": viewModel.annotationSectionViewModel.annotationSpacing
            ]
        )
    }

    /// Handles annotation filter changes.
    private func handleAnnotationFilterChanged(visibleTypes: Set<AnnotationType>, filterText: String) {
        logger.info("handleAnnotationFilterChanged: Filter updated - types=\(visibleTypes.count) text='\(filterText, privacy: .public)'")

        // Notify viewers to update annotation filtering
        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: [
                "visibleTypes": visibleTypes,
                "filterText": filterText
            ]
        )
    }

    // MARK: - Notification Handlers

    /// Handles sidebar selection changes to update inspector UI state.
    ///
    /// Note: This method only updates the inspector's display state (selected item name/type).
    /// Document loading is handled exclusively by MainSplitViewController to avoid race conditions
    /// where both controllers attempt to load the same document concurrently.
    @objc private func selectionDidChange(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? SidebarItem else { return }

        // Update UI state only - document loading is handled by MainSplitViewController
        viewModel.selectedItem = item.title
        viewModel.selectedType = item.type.description

        if item.type == .sequence || item.type == .annotation || item.type == .alignment || item.type == .referenceBundle {
            syncAnnotationStateToViewer()
        }

        logger.debug("selectionDidChange: Updated inspector state for '\(item.title, privacy: .public)' type=\(item.type.description, privacy: .public)")
    }

    /// Handles annotation selection from the viewer.
    ///
    /// Updates the selection section with the newly selected annotation.
    /// Passing nil in userInfo clears the selection.
    @objc private func handleAnnotationSelected(_ notification: Notification) {
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
            // Auto-switch to Selection tab when an annotation is selected
            viewModel.selectedTab = .selection
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
        guard let result = notification.userInfo?[NotificationUserInfoKey.searchResult] as? AnnotationSearchIndex.SearchResult else {
            viewModel.variantSectionViewModel.clear()
            return
        }
        viewModel.variantSectionViewModel.select(variant: result)
        viewModel.selectedTab = .selection
    }

    /// Handles read selection from the viewer.
    @objc private func handleReadSelected(_ notification: Notification) {
        let read = notification.userInfo?[NotificationUserInfoKey.alignedRead] as? AlignedRead
        viewModel.readStyleSectionViewModel.selectedRead = read
        if read != nil {
            viewModel.selectedTab = .selection
        }
    }

    /// Handles bundle load notifications to update the Document tab.
    ///
    /// Extracts the manifest and bundle URL from the notification's userInfo
    /// and updates the document section view model.
    @objc private func handleBundleDidLoad(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }

        let bundleURL = userInfo[NotificationUserInfoKey.bundleURL] as? URL
        let manifest = userInfo[NotificationUserInfoKey.manifest] as? BundleManifest

        logger.info("handleBundleDidLoad: Updating document tab with manifest=\(manifest != nil), bundleURL=\(bundleURL?.lastPathComponent ?? "nil", privacy: .public)")

        updateBundleMetadata(manifest: manifest, bundleURL: bundleURL)

        // Wire reference bundle for on-the-fly CDS translation computation
        if let bundle = userInfo[NotificationUserInfoKey.referenceBundle] as? ReferenceBundle {
            viewModel.selectionSectionViewModel.referenceBundle = bundle

            // Populate sample section with variant database sample data
            updateSampleSection(from: bundle)

            // Populate alignment statistics from metadata databases
            updateAlignmentSection(from: bundle)
        }

        // Auto-select the first chromosome so the Chromosome section is visible immediately
        if let chromosomes = manifest?.genome?.chromosomes, !chromosomes.isEmpty {
            let sorted = naturalChromosomeSort(chromosomes)
            updateSelectedChromosome(sorted.first)
        }
    }

    /// Handles requests to show/focus inspector with a specific tab.
    @objc private func handleShowInspectorRequested(_ notification: Notification) {
        applyInspectorTabSelection(from: notification)
    }

    /// Handles chromosome inspector requests and updates chromosome details state.
    ///
    /// Always switches to the Document tab when a chromosome is selected so the
    /// chromosome metadata is immediately visible in the inspector.
    @objc private func handleChromosomeInspectorRequested(_ notification: Notification) {
        let chromosome = notification.userInfo?[NotificationUserInfoKey.chromosome] as? ChromosomeInfo
        updateSelectedChromosome(chromosome)
        if chromosome != nil {
            viewModel.selectedTab = .document
        }
    }

    @objc private func handleFASTQDatasetLoaded(_ notification: Notification) {
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

        viewModel.selectedTab = .document
    }

    /// Applies inspector tab selection from notification userInfo if provided.
    private func applyInspectorTabSelection(from notification: Notification) {
        guard let tabName = notification.userInfo?[NotificationUserInfoKey.inspectorTab] as? String,
              let tab = InspectorTab(rawValue: tabName) else {
            return
        }
        viewModel.selectedTab = tab
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
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                NotificationUserInfoKey.changeSource: "inspector"
            ]
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
                userInfo: [
                    NotificationUserInfoKey.annotation: annotation,
                    NotificationUserInfoKey.changeSource: "inspector"
                ]
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
            userInfo: [
                NotificationUserInfoKey.annotationType: annotationType,
                NotificationUserInfoKey.annotationColor: color,
                NotificationUserInfoKey.changeSource: "inspector"
            ]
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
            userInfo: [
                NotificationUserInfoKey.annotation: annotation,
                "visible": vm.isTranslationVisible,
            ]
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
            userInfo: [
                NotificationUserInfoKey.sampleDisplayState: state
            ]
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
            userInfo: [
                "showAnnotations": viewModel.annotationSectionViewModel.showAnnotations,
                "annotationHeight": viewModel.annotationSectionViewModel.annotationHeight,
                "annotationSpacing": viewModel.annotationSectionViewModel.annotationSpacing
            ]
        )

        // Post annotation filter changed notification
        NotificationCenter.default.post(
            name: .annotationFilterChanged,
            object: self,
            userInfo: [
                "visibleTypes": viewModel.annotationSectionViewModel.visibleTypes,
                "filterText": viewModel.annotationSectionViewModel.filterText
            ]
        )

        // 6. Reset bundle view state (type color overrides, navigation, etc.)
        NotificationCenter.default.post(
            name: .bundleViewStateResetRequested,
            object: self,
            userInfo: nil
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

    /// Updates the chromosome selection in the Document tab.
    ///
    /// - Parameter chromosome: The chromosome to display details for, or nil to clear
    public func updateSelectedChromosome(_ chromosome: ChromosomeInfo?) {
        viewModel.documentSectionViewModel.selectChromosome(chromosome)
    }

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

    /// Populates the read style section with alignment statistics from the bundle's metadata DBs.
    private func updateAlignmentSection(from bundle: ReferenceBundle) {
        viewModel.readStyleSectionViewModel.loadStatistics(from: bundle)

        // Wire the settings-changed callback to post notification
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let vm = self?.viewModel.readStyleSectionViewModel else { return }
            NotificationCenter.default.post(
                name: .readDisplaySettingsChanged,
                object: self,
                userInfo: [
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
                    NotificationUserInfoKey.consensusMinMapQ: Int(vm.consensusMinMapQ),
                    NotificationUserInfoKey.consensusMinBaseQ: Int(vm.consensusMinBaseQ),
                    NotificationUserInfoKey.showConsensusTrack: vm.showConsensusTrack,
                    NotificationUserInfoKey.consensusMode: vm.consensusMode.rawValue,
                    NotificationUserInfoKey.consensusUseAmbiguity: vm.consensusUseAmbiguity,
                    NotificationUserInfoKey.excludeFlags: vm.computedExcludeFlags,
                    NotificationUserInfoKey.selectedReadGroups: vm.selectedReadGroups,
                ]
            )
        }

        viewModel.readStyleSectionViewModel.onMarkDuplicatesRequested = { [weak self] in
            self?.runMarkDuplicatesWorkflow()
        }

        viewModel.readStyleSectionViewModel.onCreateDeduplicatedBundleRequested = { [weak self] in
            self?.runCreateDeduplicatedBundleWorkflow()
        }

        logger.info("updateAlignmentSection: \(bundle.alignmentTrackIds.count) alignment tracks loaded")
    }

    // MARK: - Duplicate Workflows

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
        guard let split = parent as? MainSplitViewController else { return }

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
        guard let split = parent as? MainSplitViewController else { return }

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
    // MARK: - Tab State

    /// Currently selected inspector tab.
    var selectedTab: InspectorTab = .selection

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

}

// MARK: - InspectorView (SwiftUI)

/// SwiftUI view for the inspector panel content.
///
/// Displays a Keynote-style tabbed interface with three tabs:
/// - **Document**: Bundle metadata, source info, genome summary, extended metadata
/// - **Selection**: Annotation editing, appearance settings, annotation style, read style
/// - **AI**: Embedded AI assistant chat interface
///
/// Uses a segmented `Picker` at the top of the panel for tab switching.
public struct InspectorView: View {
    @Bindable var viewModel: InspectorViewModel

    public var body: some View {
        VStack(spacing: 0) {
            // Tab picker at top
            Picker("Inspector", selection: $viewModel.selectedTab) {
                Image(systemName: "doc.text")
                    .tag(InspectorTab.document)
                Image(systemName: "cursorarrow.click")
                    .tag(InspectorTab.selection)
                Image(systemName: "sparkles")
                    .tag(InspectorTab.ai)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            switch viewModel.selectedTab {
            case .document, .selection:
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        switch viewModel.selectedTab {
                        case .document:
                            DocumentSection(viewModel: viewModel.documentSectionViewModel)

                        case .selection:
                            SelectionSection(viewModel: viewModel.selectionSectionViewModel)

                            // Variant detail (shown when a variant is selected)
                            VariantSection(viewModel: viewModel.variantSectionViewModel)

                            Divider()

                            // Sequence style
                            AppearanceSection(viewModel: viewModel.appearanceSectionViewModel)

                            Divider()

                            // Annotation style
                            AnnotationSection(viewModel: viewModel.annotationSectionViewModel)

                            Divider()

                            // Sample display controls (shown when variant data is available)
                            SampleSection(viewModel: viewModel.sampleSectionViewModel)

                            Divider()

                            // Read style (BAM/CRAM placeholder)
                            ReadStyleSection(viewModel: viewModel.readStyleSectionViewModel)

                        case .ai:
                            EmptyView()
                        }

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
        .onChange(of: viewModel.selectedTab) { _, tab in
            guard tab == .ai, viewModel.aiAssistantService == nil else { return }
            NotificationCenter.default.post(name: .showAIAssistantRequested, object: nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
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
        case .batchGroup: return "Batch Operation"
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
