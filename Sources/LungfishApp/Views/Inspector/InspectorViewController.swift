// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import Combine
import LungfishCore
import os.log

/// Logger for inspector operations
private let logger = Logger(subsystem: "com.lungfish.browser", category: "InspectorViewController")

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

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

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
        setupNotificationObservers()
        setupViewModelCallbacks()
    }

    // MARK: - Setup

    /// Sets up notification observers for annotation and appearance changes.
    private func setupNotificationObservers() {
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

        // Appearance section callbacks
        viewModel.appearanceSectionViewModel.onSettingsChanged = { [weak self] in
            self?.handleAppearanceChanged()
        }

        // Appearance section reset callback - coordinates resetting ALL appearance settings
        viewModel.appearanceSectionViewModel.onResetToDefaults = { [weak self] in
            self?.handleResetAllAppearanceSettings()
        }

        // Quality section callbacks
        viewModel.qualitySectionViewModel.onOverlayToggleChanged = { [weak self] enabled in
            self?.handleQualityOverlayToggled(enabled)
        }

        // Annotation section callbacks
        viewModel.annotationSectionViewModel.onSettingsChanged = { [weak self] in
            self?.handleAnnotationSettingsChanged()
        }

        viewModel.annotationSectionViewModel.onFilterChanged = { [weak self] visibleTypes, filterText in
            self?.handleAnnotationFilterChanged(visibleTypes: visibleTypes, filterText: filterText)
        }
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

        logger.debug("selectionDidChange: Updated inspector state for '\(item.title, privacy: .public)' type=\(item.type.description, privacy: .public)")
    }

    /// Handles annotation selection from the viewer.
    ///
    /// Updates the selection section with the newly selected annotation.
    /// Passing nil in userInfo clears the selection.
    @objc private func handleAnnotationSelected(_ notification: Notification) {
        if let annotation = notification.userInfo?[NotificationUserInfoKey.annotation] as? SequenceAnnotation {
            viewModel.selectedAnnotation = annotation
            viewModel.selectionSectionViewModel.select(annotation: annotation)
        } else {
            // Deselection - clear the annotation
            viewModel.selectedAnnotation = nil
            viewModel.selectionSectionViewModel.select(annotation: nil)
        }
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

    // MARK: - Appearance Handlers

    /// Handles appearance setting changes.
    ///
    /// Saves the appearance settings and posts an `appearanceChanged` notification
    /// so the viewer can update its rendering.
    private func handleAppearanceChanged() {
        logger.info("handleAppearanceChanged: Appearance change detected")

        // Build and save appearance settings
        var appearance = viewModel.appearance

        // Update base colors from view model
        let colorA = viewModel.appearanceSectionViewModel.colorA
        let colorT = viewModel.appearanceSectionViewModel.colorT
        let colorG = viewModel.appearanceSectionViewModel.colorG
        let colorC = viewModel.appearanceSectionViewModel.colorC
        let colorN = viewModel.appearanceSectionViewModel.colorN

        let hexA = hexString(from: colorA)
        let hexT = hexString(from: colorT)
        let hexG = hexString(from: colorG)
        let hexC = hexString(from: colorC)
        let hexN = hexString(from: colorN)

        logger.info("handleAppearanceChanged: A=\(hexA, privacy: .public) T=\(hexT, privacy: .public) G=\(hexG, privacy: .public) C=\(hexC, privacy: .public) N=\(hexN, privacy: .public)")

        appearance.baseColors = [
            "A": hexA,
            "T": hexT,
            "G": hexG,
            "C": hexC,
            "N": hexN,
            "U": hexT  // Uracil uses same color as Thymine
        ]

        appearance.trackHeight = CGFloat(viewModel.appearanceSectionViewModel.trackHeight)
        logger.info("handleAppearanceChanged: Track height = \(appearance.trackHeight, privacy: .public)")

        // Save and update view model
        appearance.save()
        viewModel.appearance = appearance
        logger.info("handleAppearanceChanged: Saved appearance settings")

        // Notify viewers to redraw
        NotificationCenter.default.post(
            name: .appearanceChanged,
            object: self,
            userInfo: nil
        )
        logger.info("handleAppearanceChanged: Posted appearanceChanged notification")
    }

    /// Handles quality overlay toggle changes.
    ///
    /// Updates appearance settings and posts notification.
    private func handleQualityOverlayToggled(_ enabled: Bool) {
        var appearance = viewModel.appearance
        appearance.showQualityOverlay = enabled
        appearance.save()
        viewModel.appearance = appearance

        NotificationCenter.default.post(
            name: .appearanceChanged,
            object: self,
            userInfo: nil
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
    private func handleResetAllAppearanceSettings() {
        logger.info("handleResetAllAppearanceSettings: Resetting ALL appearance settings to defaults")

        // 1. Reset the appearance section view model (base colors, track height)
        viewModel.appearanceSectionViewModel.resetToDefaults()

        // 2. Reset the quality section view model (quality overlay)
        viewModel.qualitySectionViewModel.resetToDefaults()

        // 3. Reset the annotation section view model (height, spacing, visibility, filters)
        viewModel.annotationSectionViewModel.resetToDefaults()

        // 4. Reset the core SequenceAppearance model and clear persisted settings
        let defaultAppearance = SequenceAppearance.resetToDefaults()
        viewModel.appearance = defaultAppearance
        logger.info("handleResetAllAppearanceSettings: Cleared persisted settings, using defaults")

        // 5. Post notifications so the viewer updates
        // Post appearance changed notification
        NotificationCenter.default.post(
            name: .appearanceChanged,
            object: self,
            userInfo: nil
        )

        // Post annotation settings changed notification
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

        logger.info("handleResetAllAppearanceSettings: Posted all notifications for viewer update")
    }

    // MARK: - Public API

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

    // MARK: - Helper Methods

    /// Converts a SwiftUI Color to a hex string.
    ///
    /// Uses NSColor conversion to properly resolve the color components,
    /// as SwiftUI Color's cgColor property can return nil for some colors.
    private func hexString(from color: Color) -> String {
        // Convert SwiftUI Color to NSColor for reliable component access
        let nsColor = NSColor(color)

        // Convert to sRGB color space for consistent color representation
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return "#808080"
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - InspectorViewModel

/// View model for the inspector panel.
///
/// Aggregates state for all inspector sections and coordinates
/// between section view models.
@MainActor
public class InspectorViewModel: ObservableObject {
    // MARK: - Sidebar Selection State

    /// Currently selected sidebar item name
    @Published var selectedItem: String?

    /// Currently selected sidebar item type description
    @Published var selectedType: String?

    /// Properties key-value pairs for display
    @Published var properties: [(String, String)] = []

    /// Statistics key-value pairs for display
    @Published var statistics: [(String, String)] = []

    // MARK: - Annotation Selection State

    /// The currently selected annotation, if any
    @Published var selectedAnnotation: SequenceAnnotation?

    // MARK: - Appearance State

    /// Current appearance settings
    @Published var appearance: SequenceAppearance = .load()

    // MARK: - Quality State

    /// Whether quality data is available for the current file
    @Published var hasQualityData: Bool = false

    /// Quality statistics for the current file
    @Published var qualityStats: QualityStatistics?

    // MARK: - Section View Models

    /// View model for the selection section
    let selectionSectionViewModel = SelectionSectionViewModel()

    /// View model for the appearance section
    let appearanceSectionViewModel = AppearanceSectionViewModel()

    /// View model for the quality section
    let qualitySectionViewModel = QualitySectionViewModel()

    /// View model for the annotation section
    let annotationSectionViewModel = AnnotationSectionViewModel()

    // MARK: - Initialization

    init() {
        // Initialize appearance section from saved settings
        syncAppearanceToSectionViewModel()
    }

    /// Syncs the main appearance settings to the appearance section view model.
    private func syncAppearanceToSectionViewModel() {
        // Convert hex colors to SwiftUI Colors
        if let hexA = appearance.baseColors["A"] {
            appearanceSectionViewModel.colorA = color(from: hexA)
        }
        if let hexT = appearance.baseColors["T"] {
            appearanceSectionViewModel.colorT = color(from: hexT)
        }
        if let hexG = appearance.baseColors["G"] {
            appearanceSectionViewModel.colorG = color(from: hexG)
        }
        if let hexC = appearance.baseColors["C"] {
            appearanceSectionViewModel.colorC = color(from: hexC)
        }
        if let hexN = appearance.baseColors["N"] {
            appearanceSectionViewModel.colorN = color(from: hexN)
        }
        appearanceSectionViewModel.trackHeight = Double(appearance.trackHeight)

        // Sync quality overlay setting
        qualitySectionViewModel.isQualityOverlayEnabled = appearance.showQualityOverlay
    }

    /// Converts a hex string to a SwiftUI Color.
    private func color(from hexString: String) -> Color {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }

        guard hex.count == 6,
              let hexValue = UInt32(hex, radix: 16) else {
            return .gray
        }

        let red = Double((hexValue >> 16) & 0xFF) / 255.0
        let green = Double((hexValue >> 8) & 0xFF) / 255.0
        let blue = Double(hexValue & 0xFF) / 255.0

        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - InspectorView (SwiftUI)

/// SwiftUI view for the inspector panel content.
///
/// Displays four main sections:
/// - Selection: Shows and edits the currently selected annotation
/// - Annotations: Configures annotation display and filtering
/// - Appearance: Configures base colors and track height
/// - Quality: Shows quality statistics and overlay toggle
public struct InspectorView: View {
    @ObservedObject var viewModel: InspectorViewModel

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Selection Section - shows selected annotation details
                SelectionSection(viewModel: viewModel.selectionSectionViewModel)

                Divider()

                // Annotation Section - annotation display and filtering
                AnnotationSection(viewModel: viewModel.annotationSectionViewModel)

                Divider()

                // Appearance Section - base colors, track height
                AppearanceSection(viewModel: viewModel.appearanceSectionViewModel)

                Divider()

                // Quality Section - quality stats and toggle
                QualitySection(viewModel: viewModel.qualitySectionViewModel)

                Spacer()
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
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

        return InspectorView(viewModel: viewModel)
            .frame(width: 280, height: 800)
    }
}
#endif
