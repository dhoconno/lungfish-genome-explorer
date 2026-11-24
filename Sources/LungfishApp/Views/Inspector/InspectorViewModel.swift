// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishOperations
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
        if primerAnalysisDocument != nil {
            return [.bundle] + (primerAnalysisDisplaySession?.isAvailable == true ? [.view] : []) + [.files, .provenance]
        }
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
            return [.bundle, .view, .provenance]
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
        case .empty, .preview:
            return [.bundle, .selectedItem]
        }
    }

    // MARK: - Tab State

    /// Currently selected inspector tab. A set from the tab control is a person's pick, which the item keeps (VS U7).
    /// The app's own paths set it with ``setContentTab(_:)`` or ``setAppTab(_:)``, so a tab the app sets is never kept
    /// as a choice (VS S3).
    var selectedTab: InspectorTab {
        get { shownTab }
        set {
            let old = shownTab
            shownTab = newValue
            guard !appSetsTab, newValue != old else { return }
            personTab = newValue
            keepViewMemory()
        }
    }

    /// The tab on show. Only ``selectedTab``'s setter and the app's two setters write it.
    var shownTab: InspectorTab = .bundle

    /// The tab a person picked for the item on show, or the tab kept for it, nil while the content's own tab shows.
    @ObservationIgnored var personTab: InspectorTab?
    @ObservationIgnored var appSetsTab = false
    /// The window's tab from `window-state.json`, the starting tab of the next item shown when that item has no entry.
    @ObservationIgnored var windowStateTab: InspectorTab?
    /// The item on show and its read of the store (`InspectorViewController+ViewMemory.swift`).
    @ObservationIgnored var viewMemoryVisit: InspectorViewMemoryVisit?
    @ObservationIgnored var applyingViewMemory = false

    /// Sets a tab the app chose, such as the Selected Item tab after a pick in the viewer. It is not a person's pick.
    func setAppTab(_ tab: InspectorTab) {
        appSetsTab = true
        selectedTab = tab
        appSetsTab = false
    }

    /// Sets the tab the content opens on, then shows the tab the person picked or kept for the item when the content
    /// offers it, so the kept tab applies after the content's notification (VS U7).
    func setContentTab(_ tab: InspectorTab) {
        setAppTab(tab)
        applyPersonTab()
    }

    /// Moves ``selectedTab`` back onto a listed tab when the current one stops
    /// being available, then onto the item's kept tab once the content offers it.
    ///
    /// ``availableTabs`` is derived from ``contentMode``, the AI setting, and
    /// whether an alignment document is loaded, so any of those changing can
    /// strand the selection on a tab the picker no longer lists. Call this
    /// wherever those inputs change.
    func reconcileSelectedTab() {
        if !availableTabs.contains(selectedTab) { setAppTab(availableTabs.first ?? .bundle) }
        applyPersonTab()
    }

    /// Takes every 12S part out of the Inspector (the Detail tab, the result display
    /// and its export action) and moves the selection off the Detail tab.
    func clearTwelveSDetail() {
        twelveSResultDisplaySectionViewModel.clear()
        twelveSResultDisplaySectionViewModel.onExportRequested = nil
        twelveSDetailSectionViewModel.reset()
        reconcileSelectedTab()
    }

    /// Currently selected read-style subsection inside the View tab, kept for the item (VS-INSP item 2). The
    /// subsection grid writes it, so each set is a person's pick.
    var selectedReadStyleViewSubsection: ReadStyleViewSubsection {
        get { shownReadStyleSubsection }
        set {
            shownReadStyleSubsection = newValue
            keepViewMemory()
        }
    }
    var shownReadStyleSubsection: ReadStyleViewSubsection = .alignment

    /// Whether the classifier summary's "Samples & Metadata" disclosure is open, kept for the item (VS-INSP item 2).
    var samplesExpanded: Bool {
        get { shownSamplesExpanded }
        set {
            shownSamplesExpanded = newValue
            keepViewMemory()
        }
    }
    var shownSamplesExpanded = true

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

    /// Verified primer-analysis data, scoped to the currently installed result viewport.
    var primerAnalysisDocument: PrimerAnalysisInspectorDocument?

    /// Shared presentation state for the currently installed verified scheme viewer.
    var primerAnalysisDisplaySession: PrimerAnalysisDisplaySession?

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
