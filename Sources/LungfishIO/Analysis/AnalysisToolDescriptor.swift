// AnalysisToolDescriptor.swift - Plain data describing one analysis kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// How the tools behind an analysis kind are provisioned.
///
/// The managed tool and pipeline ids are entries of the managed tool lock. The registry
/// holds them as data only. Workflow checks them against the lock.
public enum AnalysisToolProvisioning: Sendable, Hashable {
    /// A lock `tools[].id` or `packTools[].id`, for example `bbtools` for the `bbmap` analysis.
    case managedTool(ManagedToolID)
    /// A lock `pipelines[].id`, for example `nf-core-viralrecon` for the `viralrecon` analysis.
    case lockedPipeline(String)
    /// Runs from a container image.
    case container
    /// Results are imported from outside and nothing is run.
    case importedResult
    /// Implemented inside the app.
    case builtIn
}

/// Everything the app knows about one analysis kind as plain data.
public struct AnalysisToolDescriptor: Sendable, Hashable {
    public let id: AnalysisToolID
    /// Human-readable name. It doubles as a CLI token and an output folder stem.
    public let displayName: String
    /// True when imported results use `{id}-{sampleName}` directory naming.
    public let acceptsImportedSampleNames: Bool
    /// The sidebar SF Symbol name, or nil when the sidebar falls back to its generic circle.
    public let sidebarSymbolName: String?
    /// The short sidebar badge of a classifier batch, or nil when the kind has none.
    public let classifierBatchBadge: String?
    public let provisioning: AnalysisToolProvisioning

    public init(
        id: AnalysisToolID,
        displayName: String,
        acceptsImportedSampleNames: Bool = false,
        sidebarSymbolName: String?,
        classifierBatchBadge: String? = nil,
        provisioning: AnalysisToolProvisioning
    ) {
        self.id = id
        self.displayName = displayName
        self.acceptsImportedSampleNames = acceptsImportedSampleNames
        self.sidebarSymbolName = sidebarSymbolName
        self.classifierBatchBadge = classifierBatchBadge
        self.provisioning = provisioning
    }
}
