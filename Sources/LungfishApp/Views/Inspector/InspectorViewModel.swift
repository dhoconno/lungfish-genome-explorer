// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishWorkflow
import os.log
import LungfishKit


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
            var tabs: [InspectorTab] = [.bundle, .selectedItem, .view]
            // An alignment bundle has no BAM, and the Analysis tab's empty
            // state asks the user to import one.
            if documentSectionViewModel.multipleSequenceAlignmentDocument == nil {
                tabs.append(.analysis)
            }
            tabs.append(.provenance)
            // Selecting the assistant tab with AI off raises a modal alert and
            // leaves an empty pane, so hide it until a provider is configured.
            if AppSettings.shared.aiSearchEnabled {
                tabs.append(.ai)
            }
            return tabs
        case .mapping:
            return [.bundle, .selectedItem, .view, .analysis, .provenance]
        case .assembly:
            return [.bundle, .provenance]
        case .fastq:
            return [.bundle, .provenance]
        case .metagenomics:
            if readStyleSectionViewModel.classifierEvidenceCapabilities != nil {
                var tabs: [InspectorTab] = [.resultSummary, .view, .analysis]
                if provenanceSectionViewModel.currentItem != nil || provenanceSectionViewModel.isLoading {
                    tabs.append(.provenance)
                }
                return tabs
            }
            // The 12S Detail tab is only meaningful for the 12S amplicon
            // viewport; other metagenomics tools (Kraken2, NAO-MGS, NVD) leave
            // it out so they don't show an empty Detail tab.
            if twelveSDetailSectionViewModel.isAvailable {
                return [.resultSummary, .twelveSDetail, .provenance]
            }
            return [.resultSummary, .provenance]
        case .genotype:
            return [.bundle, .selectedItem, .annotations, .view, .provenance]
        case .empty:
            return [.bundle, .selectedItem]
        }
    }

    // MARK: - Tab State

    /// Currently selected inspector tab.
    var selectedTab: InspectorTab = .bundle

    /// Moves ``selectedTab`` back onto a listed tab when the current one stops
    /// being available.
    ///
    /// ``availableTabs`` is derived from ``contentMode``, the AI setting, and
    /// whether an alignment document is loaded, so any of those changing can
    /// strand the selection on a tab the picker no longer lists. The content
    /// switch would then render a pane with no corresponding segment. Call this
    /// wherever those inputs change.
    func reconcileSelectedTab() {
        guard !availableTabs.contains(selectedTab) else { return }
        selectedTab = availableTabs.first ?? .bundle
    }

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

    /// View model for genotype result viewport controls section
    let genotypeResultDisplaySectionViewModel = GenotypeResultDisplaySectionViewModel()

    /// View model for 12S amplicon result viewport controls section.
    let twelveSResultDisplaySectionViewModel = TwelveSResultDisplaySectionViewModel()

    /// View model for the 12S per-selection detail tab.
    let twelveSDetailSectionViewModel = TwelveSDetailSectionViewModel()

    /// View model for FASTQ sample metadata section (Document tab)
    let fastqMetadataSectionViewModel = FASTQMetadataSectionViewModel()

    /// View model for saved FASTQ pbAA cluster artifacts.
    let fastqPBAAArtifactsSectionViewModel = FASTQPBAAArtifactsSectionViewModel()

    /// View model for generic reproducibility provenance in the Inspector.
    let provenanceSectionViewModel = ProvenanceInspectorViewModel()

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
