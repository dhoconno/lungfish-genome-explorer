// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

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
    /// Reproducibility provenance for selected scientific bundles/results.
    case provenance
}
